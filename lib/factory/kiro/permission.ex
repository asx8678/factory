defmodule Factory.Kiro.Permission do
  @moduledoc """
  Answers Kiro's `session/request_permission`: which kind of tool it asks for, and the
  option that says yes or no.

  Kiro 2.24 put the tool's kind (read, edit, execute…) on the request. Kiro 2.26
  leaves it out: the kind came earlier, on the `tool_call` update with the same
  `toolCallId`, and the request names Kiro's own tool (`_meta.kiro.toolId`, e.g.
  `fs_write`). `kind/2` looks in that order, so a request is judged by what the tool
  does whichever Kiro sent it.
  """

  # Kiro's own tools, by what they do, for requests that carry neither kind nor call id.
  @tool_kinds %{
    "fs_read" => "read",
    "fs_write" => "edit",
    "fs_append" => "edit",
    "str_replace" => "edit",
    "execute_bash" => "execute",
    "execute_cmd" => "execute",
    "shell" => "execute",
    "grep" => "search",
    "glob" => "search",
    "code" => "search",
    "web_fetch" => "fetch",
    "web_search" => "fetch"
  }

  @doc """
  The kind of tool a permission request is for, or nil when it can't be told.
  `known` maps tool call ids to the kinds their `tool_call` updates gave.
  """
  def kind(params, known \\ %{}) do
    call = params["toolCall"] || %{}

    call["kind"] || Map.get(known, call["toolCallId"]) ||
      Map.get(@tool_kinds, get_in(params, ["_meta", "kiro", "toolId"]))
  end

  @doc """
  The shell command a permission request is for, when Kiro says: on the request, or on
  the tool call it announced before (`known` maps tool call ids to commands).
  """
  def command(params, known \\ %{}) do
    call = params["toolCall"] || %{}
    command_of(call) || Map.get(known, call["toolCallId"])
  end

  @doc "The command in a tool call's input, if it has one."
  def command_of(call) do
    case call["rawInput"] do
      %{"command" => c} when is_binary(c) -> c
      %{"cmd" => c} when is_binary(c) -> c
      _ -> nil
    end
  end

  # Commands that only look, by their first word. git by what it's asked to do.
  @looking ~w(ls cat head tail wc grep egrep fgrep rg ag tree pwd file stat du which echo
              sort uniq cut diff basename dirname realpath readlink date)
  @git ~w(status log diff show ls-files ls-tree grep blame rev-parse describe shortlog)
  @gh %{
    "pr" => ~w(view diff list checks status),
    "issue" => ~w(view list status),
    "repo" => ~w(view),
    "run" => ~w(view list)
  }
  @tests [
    ~w(mix test),
    ~w(npm test),
    ~w(npm run test),
    ~w(pnpm test),
    ~w(yarn test),
    ~w(pytest),
    ~w(python -m pytest),
    ~w(python3 -m pytest),
    ~w(go test),
    ~w(cargo test),
    # Checks: they build or lint, and change no source.
    ~w(mix compile),
    ~w(mix format --check-formatted),
    ~w(mix credo),
    ~w(cargo check),
    ~w(go vet),
    ~w(npx tsc --noEmit),
    ~w(npm run lint),
    ~w(npm run typecheck)
  ]

  # Options that make a command above write a file or run another program, by command:
  # {options, alone or as `--option=value`; letters that do it among short flags (`-uo`)}.
  @unsafe %{
    "find" => {~w(-delete -exec -execdir -ok -okdir -fprint -fprint0 -fprintf -fls), ""},
    "sort" => {~w(--compress-program), "o"},
    # -R writes a page into each folder.
    "tree" => {[], "oR"},
    "rg" => {~w(--pre --hostname-bin), ""},
    "ag" => {~w(--pager), ""},
    # Compiles a magic file, written beside it.
    "file" => {~w(--compile), "C"},
    "date" => {~w(--set), "s"},
    # An external diff program, or `git grep -O` opening what it found in one.
    "git" => {~w(--ext-diff --open-files-in-pager), "O"}
  }

  # Tools that answer `<tool> version` with their own; elsewhere it may run the
  # project's code (`make version`).
  @versions ~w(go cargo docker kubectl helm terraform)

  # What `sed -n` may print: a line, the last, a /pattern/, or a range of them, then `p`.
  @sed_print ~r{^(['"]?)(\d+|\$|/[^/]*/)(,(\d+|\$|/[^/]*/))?p\1$}

  @doc """
  Whether a shell command only looks: it reads files or the project's history, lists or
  searches, prints a version, runs the tests or a check that builds or lints without
  changing source (`mix compile`, `cargo check`), or reads a pull request with `gh`. A
  planner may run these while it plans, and so may an agent that only reads and checks.
  Anything that could install, write, move, delete, commit or run other code isn't one,
  and nor is an unknown command (nil).

  Commands may be chained, piped or put in the background (`&`) when every part only
  looks. Never looking: redirecting into a file, substitution (`$(…)`, backticks),
  settings before a command (`GIT_PAGER=… git log`, which can make it run a program), a
  program named by its path (`./cat`), and the options that write a file or run a
  program (`sort -o`, `find -fprint`, `rg --pre`, `git grep -O`, `--ext-diff`). `uniq`
  looks only with at most one file name (a second is written), and `sed` only when it
  prints lines (`sed -n '5,9p' file`).
  """
  def looking?(nil), do: false

  def looking?(command) when is_binary(command) do
    text = String.replace(command, ~r/\s*\d?>\s*&\d|\s*\d?>\s*\/dev\/null/, "")
    parts = parts(text)

    not String.contains?(text, [">", "`", "$(", "<("]) and
      parts != [] and Enum.all?(parts, &looking_part?/1)
  end

  # The commands in a chain or pipeline.
  defp parts(text) do
    text
    |> String.split(~r/&&|\|\||;|\||&|\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Whether a command runs the project's own code: its tests or a check that builds it
  (`mix test`, `npm run lint`). In a pull request cloned for review, that code is the
  author's, so the person is asked first.
  """
  def runs_project_code?(nil), do: false

  def runs_project_code?(command) when is_binary(command) do
    command
    |> parts()
    |> Enum.any?(fn part ->
      words = String.split(part)
      Enum.any?(@tests, &List.starts_with?(words, &1))
    end)
  end

  @doc """
  Whether a command reads outside `folder`: a path in it (or a folder it moves to)
  that is absolute, starts at the home folder or climbs out with `..`, and leads
  somewhere that exists outside the folder. A pattern that only looks like a path
  (`grep /api/ lib`) exists nowhere, so it doesn't count; a variable (`$HOME`) always
  does, as it can't be told where it leads.
  """
  def reads_outside?(nil, _folder), do: false

  def reads_outside?(command, folder) when is_binary(command) do
    folder = Path.expand(folder)

    command
    |> String.split(~r/[\s=:,]+/)
    |> Enum.map(&String.trim(&1, "\"'"))
    |> Enum.any?(&outside?(&1, folder))
  end

  @doc """
  The files and folders a tool call names (Kiro's reads and searches), from its
  `locations` and its input.
  """
  def paths_of(call) when is_map(call) do
    input = if is_map(call["rawInput"]), do: call["rawInput"], else: %{}
    operations = if is_list(input["operations"]), do: input["operations"], else: []

    located =
      for %{"path" => p} <- List.wrap(call["locations"]), is_binary(p), do: p

    given =
      for map <- [input | operations],
          is_map(map),
          key <- ~w(path file_path filePath dir directory cwd),
          p = map[key],
          is_binary(p),
          do: p

    listed =
      for map <- [input | operations],
          is_map(map),
          p <- List.wrap(map["paths"]),
          is_binary(p),
          do: p

    Enum.uniq(located ++ given ++ listed)
  end

  def paths_of(_call), do: []

  # The paths that lead outside `folder` (relative ones are inside it).
  defp outside_paths(paths, folder) do
    folder = Path.expand(folder)
    Enum.reject(paths, &inside?(Path.expand(&1, folder), folder))
  end

  @doc """
  Why the person should say yes first to a request an agent that only reads and checks
  would otherwise be allowed, or nil. What such an agent reads may be a stranger's pull
  request, and an injected prompt could steer it, so it asks before it:

    * fetches a web page ("fetch"), which could send what it read anywhere;
    * runs the project's own code (`mix test`, a build) in a pull request cloned for
      review (`Factory.Repos.label/1`): that code is the pull request author's;
    * reads outside `folder`, with a command or with Kiro's own tools (`paths`).

  The reason reads after the agent's name: "Reviewer wants to …".
  """
  def ask_first(kind, command, paths, folder)

  def ask_first("fetch", _command, _paths, _folder),
    do: "wants to fetch a web page. What it has read could go along with the request."

  def ask_first("execute", command, _paths, folder) do
    cond do
      Factory.Repos.label(folder) != nil and runs_project_code?(command) ->
        "wants to run `#{command}` in a pull request cloned for review. " <>
          "That runs the pull request's own code."

      reads_outside?(command, folder) ->
        "wants to run `#{command}`, which reads outside the project folder."

      true ->
        nil
    end
  end

  def ask_first(kind, _command, paths, folder) when kind in ["read", "search"] do
    case outside_paths(paths, folder) do
      [] -> nil
      outside -> "wants to read outside the project folder: #{Enum.join(outside, ", ")}."
    end
  end

  def ask_first(_kind, _command, _paths, _folder), do: nil

  defp outside?(word, folder) do
    cond do
      # `$HOME`, `${HOME}`; not a pattern's `foo$`.
      Regex.match?(~r/\$[A-Za-z_{]/, word) ->
        true

      String.starts_with?(word, ["/", "~"]) or String.contains?(word, "..") ->
        # A glob reads what its folder holds.
        path = word |> String.replace(~r/[*?\[{].*$/, "") |> Path.expand(folder)
        path != "" and not inside?(path, folder) and File.exists?(path)

      true ->
        false
    end
  end

  defp inside?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

  defp looking_part?(part) do
    words = String.split(part)

    # Settings before the command (GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND…) can make it run
    # another program.
    sets? = Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, List.first(words, ""))

    not sets? and not unsafe?(words) and looking_words?(words)
  end

  # Writing what it shows into a file (`git diff --output=x`, `sort -o x`), or an option
  # that runs another program.
  defp unsafe?([command | args]) do
    {options, letters} = Map.get(@unsafe, command, {[], ""})

    Enum.any?(args, fn arg ->
      String.starts_with?(arg, "--output") or
        Enum.any?(options, &(arg == &1 or String.starts_with?(arg, &1 <> "="))) or
        (letters != "" and Regex.match?(~r/^-[^-]/, arg) and
           String.contains?(arg, String.graphemes(letters)))
    end)
  end

  defp unsafe?([]), do: false

  defp looking_words?([]), do: false
  defp looking_words?(["cd" | _]), do: true
  defp looking_words?(["git", sub | _] = words), do: sub in @git or git_branch_list?(words)

  # GitHub's CLI, reading only: never merge, close, comment, review or edit.
  defp looking_words?(["gh", area, action | _]), do: action in Map.get(@gh, area, [])

  defp looking_words?(["find" | _]), do: true

  # sed only prints: `-n` (with -E or -r), one address or range and `p`, then files. Its
  # other commands may write (-i, `w`, `s///w`) or run a program (`e`, `s///e`), and
  # GNU sed reads options after the files too (`sed -n 1p file -i`).
  defp looking_words?(["sed" | rest]) do
    {flags, rest} = Enum.split_while(rest, &String.starts_with?(&1, "-"))

    case rest do
      [script | files] ->
        flags != [] and Enum.all?(flags, &Regex.match?(~r/^-[nEr]+$/, &1)) and
          Enum.any?(flags, &String.contains?(&1, "n")) and Regex.match?(@sed_print, script) and
          not Enum.any?(files, &String.starts_with?(&1, "-"))

      [] ->
        false
    end
  end

  # `uniq in out` writes out.
  defp looking_words?(["uniq" | rest]),
    do: Enum.count(rest, &(not String.starts_with?(&1, "-"))) < 2

  defp looking_words?([tool, flag]) when flag in ~w(--version -v -V),
    do: not String.contains?(tool, "/")

  defp looking_words?([tool, "version"]) when tool in @versions, do: true

  defp looking_words?([first | _] = words),
    do: first in @looking or Enum.any?(@tests, &List.starts_with?(words, &1))

  # `git branch` only when it lists branches: options only, none that creates, renames,
  # copies, deletes or moves one (a bare name would create it).
  defp git_branch_list?(["git", "branch" | args]) do
    changes =
      ~w(-d -D -m -M -c -C -f -t -u --delete --move --copy --force --track --set-upstream-to --unset-upstream --edit-description)

    Enum.all?(args, fn arg ->
      String.starts_with?(arg, "-") and
        not Enum.any?(changes, &(arg == &1 or String.starts_with?(arg, &1 <> "=")))
    end)
  end

  defp git_branch_list?(_words), do: false

  # ACP permits cancellation when none of the offered options matches the decision. The
  # one-time answer comes first: `allow_always` would trust the tool for the rest of the
  # session, so it's taken only when nothing else says yes.
  def outcome(options, decision) do
    option =
      Enum.find(options, &(&1["kind"] == decision <> "_once")) ||
        Enum.find(options, &String.starts_with?(&1["kind"] || "", decision))

    case option do
      %{"optionId" => id} when is_binary(id) -> %{outcome: "selected", optionId: id}
      _ -> %{outcome: "cancelled"}
    end
  end
end
