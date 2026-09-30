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
    link = clean(link)

    cond do
      link == "" ->
        {:error, "Paste the repository's link."}

      m =
          Regex.run(
            ~r{^(?:ssh://)?[\w.-]+@([\w.-]+)[:/](?:\d+/)?((?:[\w.-]+/)+)([\w.-]+?)(?:\.git)?$},
            link
          ) ->
        [_, _host, owner, repo] = m
        found(link, String.trim_trailing(owner, "/"), repo, nil)

      m = Regex.run(~r{^https?://([\w.-]+)/(.+)$}, link) ->
        [_, host, path] = m
        web(String.replace_prefix(host, "www.", ""), path)

      # A repository on this computer.
      String.starts_with?(link, ["file://", "/", "~"]) ->
        path = link |> String.replace_prefix("file://", "") |> Path.expand()

        if File.dir?(path),
          do: found(path, "local", path |> Path.basename() |> String.trim_trailing(".git"), nil),
          else: {:error, "There's no folder at #{path}."}

      # "github.com/owner/repo", without the https://.
      Regex.match?(~r{^(www\.)?[\w-]+(\.[\w-]+)+/}, link) ->
        parse("https://" <> link)

      # "owner/repo": on GitHub.
      Regex.match?(~r{^[\w.-]+/[\w.-]+$}, link) ->
        parse("https://github.com/" <> link)

      true ->
        {:error,
         "That isn't a repository's link. Paste one like git@github.com:owner/repo.git, https://github.com/owner/repo or owner/repo."}
    end
  end

  # A link as pasted: without quotes, angle brackets, a query or an anchor.
  defp clean(link) do
    link
    |> to_string()
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.split(~r/[?#]/, parts: 2)
    |> hd()
    |> String.trim_trailing("/")
  end

  # A web link: GitHub's and Bitbucket's name the repository in their first two parts
  # (`/owner/repo/pull/12`); GitLab's may have groups in groups, up to its "/-/".
  defp web(host, path) do
    parts = path |> String.split("/-/", parts: 2) |> hd() |> String.split("/", trim: true)

    {owner, repo, rest} =
      case {host, parts} do
        {"gitlab" <> _, [_, _ | _]} ->
          {Enum.join(Enum.drop(parts, -1), "/"), List.last(parts), []}

        {_, [owner, repo | rest]} ->
          {owner, repo, rest}

        _ ->
          {nil, nil, []}
      end

    if owner do
      repo = String.trim_trailing(repo, ".git")

      pr =
        case rest do
          ["pull", n | _] -> with {n, ""} <- Integer.parse(n), do: n, else: (_ -> nil)
          _ -> nil
        end

      found("git@#{host}:#{owner}/#{repo}.git", owner, repo, pr)
    else
      {:error,
       "That link doesn't name a repository: it needs its owner and name, like https://#{host}/owner/repo."}
    end
  end

  @doc "The repository a review clone holds (\"owner/repo\"), or nil for any other folder."
  def label(dir) do
    root = root()
    dir = Path.expand(dir || "")

    if String.starts_with?(dir, root <> "/") do
      dir |> Path.relative_to(root)
    end
  end

  defp found(url, owner, repo, pr),
    do: {:ok, %{url: url, owner: owner, repo: repo, pr: pr, label: "#{owner}/#{repo}"}}

  @doc """
  Clones the repository a link points to into `root/0`, or fetches it again when it's
  there already: `{:ok, %{dir:, label:, fresh:, pr_branch:}}`, `fresh` when it was just
  cloned and `pr_branch` the pull request's branch (`pr-12`) when the link was to one.
  A folder there that holds another repository is left alone. The git commands share
  one deadline; git still going at it is stopped.
  """
  def clone(link) do
    with {:ok, repo} <- parse(link) do
      dir = Path.join([root(), safe(repo.owner), safe(repo.repo)])

      case clone_or_fetch(repo, dir, System.monotonic_time(:millisecond) + @timeout) do
        {:error, :timeout} ->
          {:error, "git took more than #{div(@timeout, 60_000)} minutes, so Factory stopped it."}

        result ->
          result
      end
    end
  end

  defp clone_or_fetch(repo, dir, deadline) do
    cond do
      File.dir?(Path.join(dir, ".git")) ->
        case git(dir, ~w(remote get-url origin), deadline) do
          {:ok, url} when is_binary(url) ->
            cond do
              not same?(url, repo.url) ->
                {:error, "#{dir} already holds another repository, so Factory left it alone."}

              # A clone stopped partway, before clones were made beside it and moved
              # into place (`fresh_clone/3`): nothing checked out, so it starts again.
              not checked_out?(dir, deadline) ->
                File.rm_rf!(dir)
                clone_or_fetch(repo, dir, deadline)

              true ->
                refetch(repo, dir, deadline)
            end

          _ ->
            {:error, "#{dir} already holds another repository, so Factory left it alone."}
        end

      # A file where the folder would go, or a folder with something else in it.
      File.exists?(dir) and (not File.dir?(dir) or File.ls!(dir) != []) ->
        {:error, "#{dir} already exists and isn't this repository, so Factory left it alone."}

      true ->
        with :ok <- fresh_clone(repo, dir, deadline),
             {:ok, pr_branch} <- fetch_pr(repo, dir, deadline) do
          {:ok, %{dir: dir, label: repo.label, fresh: true, pr_branch: pr_branch}}
        end
    end
  end

  # Cloned into a folder beside it and moved into place once complete, so a clone that
  # was stopped partway (the deadline, Factory quitting) never passes for the repository;
  # the next try starts it again.
  defp fresh_clone(repo, dir, deadline) do
    partial = Path.join(Path.dirname(dir), ".#{Path.basename(dir)}.cloning")
    File.mkdir_p!(Path.dirname(dir))
    File.rm_rf!(partial)

    with {:ok, _} <- git(nil, ["clone", "--quiet", repo.url, partial], deadline),
         :ok <- move(partial, dir) do
      :ok
    else
      error ->
        File.rm_rf(partial)
        error
    end
  end

  defp move(from, to) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "The clone couldn't be moved to #{to}: #{:file.format_error(reason)}"}
    end
  end

  # The same repository, whichever way its address was written.
  defp same?(a, b), do: normal(a) == normal(b)

  defp normal(url) do
    url = url |> String.trim() |> String.trim_trailing("/") |> String.trim_trailing(".git")

    # ssh://git@host/owner/repo is git@host:owner/repo.
    case Regex.run(~r{^ssh://([^/]+@[^/:]+)(?::\d+)?/(.+)$}, url) do
      [_, who, path] -> "#{who}:#{path}"
      _ -> url
    end
  end

  # Whether the clone has a commit checked out. When git can't say (it took too long,
  # or isn't there), it's taken as yes, so a good clone is never removed for that.
  defp checked_out?(dir, deadline) do
    case git(dir, ~w(rev-parse --verify --quiet HEAD), deadline) do
      {:ok, _} -> true
      {:error, :timeout} -> true
      {:error, "git isn't installed."} -> true
      {:error, _} -> false
    end
  end

  defp refetch(repo, dir, deadline) do
    with {:ok, _} <- git(dir, ~w(fetch --all --prune --quiet), deadline),
         {:ok, pr_branch} <- fetch_pr(repo, dir, deadline) do
      {:ok, %{dir: dir, label: repo.label, fresh: false, pr_branch: pr_branch}}
    end
  end

  # A GitHub pull request, as a local branch: `pr-12`.
  defp fetch_pr(%{pr: nil}, _dir, _deadline), do: {:ok, nil}

  defp fetch_pr(%{pr: n}, dir, deadline) do
    branch = "pr-#{n}"

    case git(
           dir,
           ["fetch", "--quiet", "origin", "+pull/#{n}/head:refs/heads/#{branch}"],
           deadline
         ) do
      {:ok, _} ->
        {:ok, branch}

      {:error, :timeout} = timeout ->
        timeout

      {:error, _} ->
        {:error,
         "The repository is in #{dir}, but pull request ##{n} couldn't be fetched: is the number right?"}
    end
  end

  # A folder name from an owner or repository name.
  defp safe(name), do: String.replace(name, ~r/[^\w.-]/, "-")

  # git with what's left of the deadline: one still going then is stopped, with ssh.
  defp git(dir, args, deadline) do
    args = if dir, do: ["-C", dir | args], else: args

    env = [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"SSH_ASKPASS_REQUIRE", "never"},
      {"GIT_SSH_COMMAND",
       "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"}
    ]

    timeout = deadline - System.monotonic_time(:millisecond)

    case Factory.OsProcess.run("git", args, env: env, timeout: timeout) do
      {:ok, out, 0} ->
        {:ok, String.trim(out)}

      {:ok, out, _} ->
        {:error, explain(out)}

      {:error, :timeout} = timeout ->
        timeout

      {:error, _} ->
        {:error, "git isn't installed."}
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
