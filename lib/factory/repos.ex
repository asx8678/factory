defmodule Factory.Repos do
  @moduledoc """
  Repositories cloned to review (the "Review a PR" workflow). Factory itself clones
  them with git over SSH into a folder of their own, `~/repo-reviews/<owner>/<repo>`
  (`config :factory, :review_dir` to move it), and fetches again when the same one is
  asked for later. A pull request's link clones its repository and fetches the pull
  request as the branch `pr-<number>`, so it can be reviewed without GitHub's `gh`.

  The link can be an SSH address (`git@github.com:owner/repo.git`,
  `ssh://git@host/owner/repo`), a web link to the repository or to one of its pull
  requests (made into the SSH address), or a local repository's path or `file://` URL.
  git runs without a terminal: a key it can't use, or a host that asks for a password,
  makes it fail rather than wait. An SSH host it hasn't seen before is trusted on first
  contact (`StrictHostKeyChecking=accept-new`): its key is remembered, and a later
  change to it makes git refuse the connection.
  """

  @timeout 5 * 60_000

  @doc "Where review clones go."
  def root, do: Application.get_env(:factory, :review_dir) || Path.expand("~/repo-reviews")

  @doc """
  What a link points to: `{:ok, %{url:, owner:, repo:, pr:, label:}}`, where `url` is
  what git clones (SSH for a web link), `pr` a GitHub pull request's number or nil,
  and `label` "owner/repo". `{:error, reason}` when it isn't a repository's link.
  """
  def parse(link) do
    link = link |> to_string() |> String.trim() |> String.trim_trailing("/")

    cond do
      link == "" ->
        {:error, "Paste the repository's link."}

      m =
          Regex.run(
            ~r{^(?:ssh://)?[\w.-]+@([\w.-]+)[:/](?:\d+/)?([\w.-]+)/([\w.-]+?)(?:\.git)?$},
            link
          ) ->
        [_, _host, owner, repo] = m
        found(link, owner, repo, nil)

      m = Regex.run(~r{^https?://([\w.-]+)/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/(.*))?$}, link) ->
        [_, host, owner, repo | rest] = m
        path = List.first(rest) || ""
        pr = with [_, n] <- Regex.run(~r{^pull/(\d+)}, path), do: String.to_integer(n)
        found("git@#{host}:#{owner}/#{repo}.git", owner, repo, if(is_integer(pr), do: pr))

      # A repository on this computer.
      String.starts_with?(link, ["file://", "/", "~"]) ->
        path = link |> String.replace_prefix("file://", "") |> Path.expand()

        if File.dir?(path),
          do: found(path, "local", path |> Path.basename() |> String.trim_trailing(".git"), nil),
          else: {:error, "There's no folder at #{path}."}

      true ->
        {:error,
         "That isn't a repository's link. Paste one like git@github.com:owner/repo.git or https://github.com/owner/repo."}
    end
  end

  defp found(url, owner, repo, pr),
    do: {:ok, %{url: url, owner: owner, repo: repo, pr: pr, label: "#{owner}/#{repo}"}}

  @doc """
  Clones the repository a link points to into `root/0`, or fetches it again when it's
  there already: `{:ok, %{dir:, label:, fresh:, pr_branch:}}`, `fresh` when it was just
  cloned and `pr_branch` the pull request's branch (`pr-12`) when the link was to one.
  A folder there that holds another repository is left alone.
  """
  def clone(link) do
    with {:ok, repo} <- parse(link) do
      dir = Path.join([root(), safe(repo.owner), safe(repo.repo)])

      task = Task.async(fn -> clone_or_fetch(repo, dir) end)

      # Past the timeout the task is killed, but the git process it started (a child
      # of the VM, not of the task) keeps running until it finishes or fails on its
      # own; there's no port to close from here. A later clone of the same link finds
      # whatever it left in `dir` and either fetches it again or refuses to touch it.
      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        _ ->
          {:error,
           "git took more than #{div(@timeout, 60_000)} minutes, so Factory stopped waiting."}
      end
    end
  end

  defp clone_or_fetch(repo, dir) do
    cond do
      File.dir?(Path.join(dir, ".git")) ->
        case git(dir, ~w(remote get-url origin)) do
          {:ok, url} when is_binary(url) ->
            if same?(url, repo.url),
              do: refetch(repo, dir),
              else: {:error, "#{dir} already holds another repository, so Factory left it alone."}

          _ ->
            {:error, "#{dir} already holds another repository, so Factory left it alone."}
        end

      # A file where the folder would go, or a folder with something else in it.
      File.exists?(dir) and (not File.dir?(dir) or File.ls!(dir) != []) ->
        {:error, "#{dir} already exists and isn't this repository, so Factory left it alone."}

      true ->
        File.mkdir_p!(Path.dirname(dir))

        with {:ok, _} <- git(nil, ["clone", "--quiet", repo.url, dir]),
             {:ok, pr_branch} <- fetch_pr(repo, dir) do
          {:ok, %{dir: dir, label: repo.label, fresh: true, pr_branch: pr_branch}}
        end
    end
  end

  # The same repository, whichever way its address was written.
  defp same?(a, b), do: normal(a) == normal(b)

  defp normal(url),
    do: url |> String.trim() |> String.trim_trailing("/") |> String.trim_trailing(".git")

  defp refetch(repo, dir) do
    with {:ok, _} <- git(dir, ~w(fetch --all --prune --quiet)),
         {:ok, pr_branch} <- fetch_pr(repo, dir) do
      {:ok, %{dir: dir, label: repo.label, fresh: false, pr_branch: pr_branch}}
    end
  end

  # A GitHub pull request, as a local branch: `pr-12`.
  defp fetch_pr(%{pr: nil}, _dir), do: {:ok, nil}

  defp fetch_pr(%{pr: n}, dir) do
    branch = "pr-#{n}"

    case git(dir, ["fetch", "--quiet", "origin", "+pull/#{n}/head:refs/heads/#{branch}"]) do
      {:ok, _} ->
        {:ok, branch}

      {:error, _} ->
        {:error,
         "The repository is in #{dir}, but pull request ##{n} couldn't be fetched: is the number right?"}
    end
  end

  # A folder name from an owner or repository name.
  defp safe(name), do: String.replace(name, ~r/[^\w.-]/, "-")

  # git without a terminal, over SSH that won't ask anything (see the moduledoc).
  @git_env [
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_SSH_COMMAND",
     "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"}
  ]

  defp git(dir, args) do
    case Factory.GitCmd.run(dir, args, env: @git_env) do
      {:ok, out} -> {:ok, out}
      {:error, :not_installed} -> {:error, "git isn't installed."}
      {:error, out} -> {:error, explain(out)}
    end
  end

  # git's errors, in plain words.
  defp explain(out) do
    cond do
      out =~ ~r/Permission denied \(publickey/ ->
        "The server refused this computer's SSH key. Add the key to your account (`ssh -T git@github.com` tells you whether it works)."

      out =~ ~r/Repository not found|does not appear to be a git repository|not found/i ->
        "There's no repository at that link, or your SSH key can't read it."

      out =~
          ~r/Could not resolve hostname|Network is unreachable|Connection timed out|Operation timed out/i ->
        "Couldn't reach the server. Check the link and your connection."

      out =~ ~r/Host key verification failed/ ->
        "The server's SSH host key changed since last time, so git refused it."

      true ->
        "git failed: " <>
          (out |> String.trim() |> String.split("\n") |> List.last() |> to_string())
    end
  end
end
