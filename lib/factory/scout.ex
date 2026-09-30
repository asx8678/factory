defmodule Factory.Scout do
  @moduledoc """
  What there is to review in a project folder, read straight from git (no Kiro, so
  it's instant and free): the branch it's on, the base branch, the branches with the
  latest work and how far each is ahead of the base, whether there are uncommitted
  changes, and, when GitHub's `gh` is installed and signed in, the open pull requests.

  The chat shows it when the "Review a PR" workflow is picked, so a review starts from
  a click: a branch, a pull request, or a link pasted in.
  """

  @branches 8
  @gh_timeout 6_000

  @doc """
  The folder's review candidates:

      {:ok, %{current:, base:, dirty:, recent: [%{sha:, subject:, at:}],
             branches: [%{name:, current:, ahead:, behind:,
             subject:, author:, at:}], prs: [%{number:, title:, branch:, url:, at:}] | nil,
             prs_note: nil | text}}

  or `{:error, reason}` when it isn't a git repository. `prs` is nil when gh can't
  list them, and `prs_note` says why.
  """
  def scout(dir) do
    dir = Path.expand(dir || "")

    with true <- File.dir?(dir) || {:error, "That folder doesn't exist."},
         {:ok, _} <- repo(dir) do
      prs = Task.async(fn -> prs(dir) end)
      current = current(dir)
      base = base(dir)

      branches =
        for b <- branches(dir) do
          {ahead, behind} = if base, do: ahead_behind(dir, base, b.name), else: {nil, nil}
          Map.merge(b, %{current: b.name == current, ahead: ahead, behind: behind})
        end

      {prs, note} =
        case Task.yield(prs, @gh_timeout) || Task.shutdown(prs) do
          {:ok, result} -> result
          nil -> {nil, "GitHub didn't answer in time."}
        end

      {:ok,
       %{
         current: current,
         base: base,
         dirty: dirty(dir),
         recent: recent(dir),
         branches: branches,
         prs: prs,
         prs_note: note
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo(dir) do
    case git(dir, ~w(rev-parse --is-inside-work-tree)) do
      {:ok, _} = ok -> ok
      {:error, "git isn't installed."} = error -> error
      {:error, _} -> {:error, "This folder isn't a git repository."}
    end
  end

  defp current(dir) do
    case git(dir, ~w(branch --show-current)) do
      {:ok, ""} -> nil
      {:ok, name} -> name
      _ -> nil
    end
  end

  # The branch changes are compared with: the remote's default, else main or master.
  defp base(dir) do
    remote =
      case git(dir, ~w(symbolic-ref --quiet --short refs/remotes/origin/HEAD)) do
        {:ok, "origin/" <> name} -> name
        _ -> nil
      end

    remote ||
      Enum.find(~w(main master develop trunk), fn name ->
        match?({:ok, _}, git(dir, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> name]))
      end)
  end

  defp branches(dir) do
    format = "%(refname:short)%09%(committerdate:iso-strict)%09%(authorname)%09%(subject)"

    case git(dir, [
           "for-each-ref",
           "--sort=-committerdate",
           "--count=#{@branches}",
           "--format=" <> format,
           "refs/heads"
         ]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [name, at, author, subject] <- [String.split(line, "\t", parts: 4)] do
          %{name: name, at: time(at), author: author, subject: subject}
        end

      _ ->
        []
    end
  end

  defp ahead_behind(dir, base, branch) do
    case git(dir, ["rev-list", "--left-right", "--count", "#{base}...#{branch}"]) do
      {:ok, out} ->
        case String.split(out) do
          [behind, ahead] -> {String.to_integer(ahead), String.to_integer(behind)}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  # The latest commits on the branch that's checked out, newest first.
  defp recent(dir) do
    case git(dir, ["log", "-5", "--format=%h%x09%cI%x09%s"]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [sha, at, subject] <- [String.split(line, "\t", parts: 3)],
            do: %{sha: sha, at: time(at), subject: subject}

      _ ->
        []
    end
  end

  defp dirty(dir) do
    case git(dir, ~w(status --porcelain)) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> length()
      _ -> 0
    end
  end

  # Open pull requests, with gh: `{prs, nil}`, or `{nil, why not}`.
  defp prs(dir) do
    case System.find_executable("gh") do
      nil ->
        {nil, "Install GitHub's gh to list pull requests here."}

      gh ->
        args = ~w(pr list --state open --limit 8 --json number,title,headRefName,url,updatedAt)

        case System.cmd(gh, args, cd: dir, stderr_to_stdout: true) do
          {out, 0} ->
            case JSON.decode(out) do
              {:ok, list} when is_list(list) ->
                {for p <- list do
                   %{
                     number: p["number"],
                     title: p["title"],
                     branch: p["headRefName"],
                     url: p["url"],
                     at: time(p["updatedAt"])
                   }
                 end, nil}

              _ ->
                {nil, "gh's answer wasn't readable."}
            end

          {out, _} ->
            cond do
              out =~ ~r/auth login|not logged/i ->
                {nil, "Sign gh in (gh auth login) to list pull requests here."}

              out =~ ~r/no git remote|not a git repository|none of the git remotes/i ->
                {nil, "This repository has no GitHub remote."}

              true ->
                {nil, "gh couldn't list pull requests."}
            end
        end
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    _ -> {:error, "git isn't installed."}
  end

  defp time(nil), do: nil

  defp time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end
end
