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

  # Build output and dependencies aren't work anyone left unfinished.
  @generated ~w(_build/ deps/ node_modules/ dist/ build/ target/ .elixir_ls/ .next/ tmp/ coverage/)

  @doc """
  What there is to pick up in a project, read from git for a new chat to suggest
  (`%{label:, text:}`, the words for its chip and what it puts in the message box), at
  most `limit`: unfinished work first (uncommitted changes, a branch ahead of the
  base), then TODO and FIXME notes in the code. Empty for a folder that isn't a git
  repository, or has nothing to pick up.
  """
  def ideas(dir, limit \\ 4) do
    dir = Path.expand(dir || "")

    with true <- File.dir?(dir),
         {:ok, _} <- repo(dir) do
      (changes_idea(dir) ++ branch_idea(dir) ++ notes_ideas(dir)) |> Enum.take(limit)
    else
      _ -> []
    end
  end

  defp changes_idea(dir) do
    files =
      case git(dir, ~w(status --porcelain)) do
        {:ok, out} ->
          for line <- String.split(out, "\n", trim: true),
              file = changed_file(line),
              not String.starts_with?(file, @generated),
              do: file

        _ ->
          []
      end

    case files do
      [] ->
        []

      [file] ->
        [
          %{
            label: "Finish the changes in #{file}",
            text: "Finish the uncommitted changes in `#{file}`."
          }
        ]

      [file | rest] ->
        [
          %{
            label: "Finish the changes in #{file} and #{length(rest)} more",
            text:
              "Finish the uncommitted changes in `#{file}` and #{length(rest)} more " <>
                "#{if length(rest) == 1, do: "file", else: "files"}."
          }
        ]
    end
  end

  defp branch_idea(dir) do
    with current when is_binary(current) <- current(dir),
         base when is_binary(base) and base != current <- base(dir),
         {ahead, _} when is_integer(ahead) and ahead > 0 <- ahead_behind(dir, base, current),
         {:ok, subject} <- git(dir, ["log", "-1", "--format=%s"]) do
      [
        %{
          label: "Carry on with #{current}",
          text:
            "Carry on with the `#{current}` branch (#{ahead} " <>
              "#{if ahead == 1, do: "commit", else: "commits"} ahead of `#{base}`, the latest " <>
              "“#{subject}”): see what's left to do and finish it."
        }
      ]
    else
      _ -> []
    end
  end

  # The file a `git status --porcelain` line is about: "M lib/a.ex", "R old -> new".
  defp changed_file(line) do
    path =
      case Regex.run(~r/^\s*\S{1,2}\s+(.+)$/, line) do
        [_, path] -> path
        _ -> line
      end

    path |> String.split(" -> ") |> List.last() |> String.trim() |> String.trim("\"")
  end

  # TODO, FIXME and HACK notes in files git tracks, one per file.
  defp notes_ideas(dir) do
    case git(dir, ["grep", "-n", "-I", "-E", "-m", "1", "(TODO|FIXME|HACK)[:( ]"]) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true),
            [file, number, text] <- [String.split(line, ":", parts: 3)],
            not String.starts_with?(file, @generated),
            note = clean_note(text),
            note != "" do
          place = "#{file}:#{number}"

          %{
            label: "#{String.slice(note, 0, 60)}#{if String.length(note) > 60, do: "…"}",
            text: "Resolve the note in `#{place}`: “#{note}”."
          }
        end
        |> Enum.take(3)

      _ ->
        []
    end
  end

  # The note itself: "# TODO: handle the empty list" is "TODO: handle the empty list".
  defp clean_note(text) do
    case Regex.run(~r/\b((TODO|FIXME|HACK)\b.*)$/, text) do
      [_, note | _] -> note |> String.trim() |> String.trim_trailing("*/") |> String.trim()
      _ -> ""
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
