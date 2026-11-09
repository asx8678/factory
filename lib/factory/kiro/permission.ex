defmodule Factory.Kiro.Permission do
  @moduledoc """
  Answers Kiro's `session/request_permission`: which kind of tool it asks for, and the
  option that says yes or no.

  Kiro 2.24 put the tool's kind (read, edit, execute…) on the request. Kiro 2.26
  leaves it out: the kind came earlier, on the `tool_call` update with the same
  `toolCallId`, and the request names Kiro's own tool (`_meta.kiro.toolId`, e.g.
  `fs_write`). `kind/2` looks in that order, so a request is judged by what the tool
  does whichever Kiro sent it.

  Commands are read with `Factory.Kiro.Shell`, the way the shell reads them, never as
  plain text. These rules decide what Factory allows; what keeps a stranger's repository
  away from your files is `Factory.Sandbox`, for the agents that only read.
  """
  alias Factory.Kiro.Shell

  # Kiro's own tools, by what they do, for requests that carry neither kind nor call id.
  # Kiro 2.26 names them read_file, run_command, web_fetch, and remote_web_search (its
  # search runs on a server of its own, "remote").
  @tool_kinds %{
    "fs_read" => "read",
    "read_file" => "read",
    "grep_search" => "search",
    "list_directory" => "search",
    "run_command" => "execute",
    "remote_web_search" => "fetch",
    "remote_web_fetch" => "fetch",
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
    kiro = get_in(params, ["_meta", "kiro"]) || %{}
    tool = Map.get(@tool_kinds, kiro["toolId"])

    # Kiro may ask again for one call, for what the call needs next (a command told to run
    # in another folder asks to list it): that round is judged by the tool it names.
    later_round? = is_integer(kiro["consentRound"]) and kiro["consentRound"] > 1

    call["kind"] || (later_round? && tool) || Map.get(known, call["toolCallId"]) || tool
  end

  @doc """
  The shell command a permission request is for, when Kiro says: on the request, or on
  the tool call it announced before (`known` maps tool call ids to commands).
  """
  def command(params, known \\ %{}) do
    call = params["toolCall"] || %{}
    command_of(call) || Map.get(known, call["toolCallId"])
  end

  @doc "The command in a tool call's input, or the address a fetch names, if it has one."
  def command_of(call) do
    case call["rawInput"] do
      %{"command" => c} when is_binary(c) -> c
      %{"cmd" => c} when is_binary(c) -> c
      %{"url" => u} when is_binary(u) -> u
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

  # Commands where a file named like an option does harm when a bare `*` expands to it.
  @option_sensitive Map.keys(@unsafe) ++ ~w(sed uniq diff)

  # A command that can do real damage, in plain text: a building agent still asks first.
  @dangerous ~r/(?:^|[\s;&|(])(?:rm\s+(?:-\S+\s+)*-\S*[rR]\S*|sudo|curl|wget|ssh|scp|nc|git\s+(?:push|clean|reset\s+--hard))(?:\s|$)/

  # Tools that answer `<tool> version` with their own; elsewhere it may run the
  # project's code (`make version`).
  @versions ~w(go cargo docker kubectl helm terraform)

  # The tools whose `-v` or `-V` prints their version. Elsewhere it may mean verbose and
  # run the project's build (`rake -v`, `ninja -v`, `ant -v`).
  @short_versions %{
    "-v" => ~w(node npm npx pnpm yarn bun elixir mix ruby perl php gcc clang git),
    "-V" => ~w(python python3 psql deno cargo rustc)
  }

  # What `sed -n` may print: a line, the last, a /pattern/, or a range of them, then `p`.
  @sed_print ~r{^(['"]?)(\d+|\$|/[^/]*/)(,(\d+|\$|/[^/]*/))?p\1$}
  # What sed may change in what it prints: one `s/…/…/`, with flags that neither write
  # (`w`) nor run the result (`e`).
  @sed_substitute ~r{^(['"]?)s([/,#:@%])(?:\\.|(?!\2).)*\2(?:\\.|(?!\2).)*\2[gIip0-9]*\1$}

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
  program, spelled in full, shortened or quoted (`sort -o`, `sort --outp=x`, `find
  "-delete"`, `rg --pre`, `git grep -O`, `--ext-diff`). `uniq` looks only with at most one
  file name (a second is written), and `sed` only when it prints lines (`sed -n '5,9p'
  file`) or changes what it prints (`sed 's/a/b/g'`). Comments (`# why`) don't count.
  Anything `Factory.Kiro.Shell` can't read for certain isn't looking.

  `workdir` is the folder the command runs in. In a repository cloned for review
  (under `Factory.Repos.root/0`) the tests and checks are somebody else's code, so they
  aren't looking there; the rest still is.
  """
  def looking?(command, workdir \\ nil)

  def looking?(nil, _workdir), do: false

  def looking?(command, workdir) when is_binary(command) do
    tests? = not in_review_clone?(workdir)

    case Shell.parse(command) do
      {:ok, [_ | _] = commands} -> Enum.all?(commands, &looking_command?(&1, tests?))
      _ -> false
    end
  end

  defp looking_command?(%{words: []}, _tests?), do: false

  defp looking_command?(%{words: [first | _] = words, redirects: redirects}, tests?) do
    plain? = not (first.variable or first.glob or first.brace or first.substitution)

    # A word that spells options through a glob or a brace is judged as what it expands to.
    texts = Enum.flat_map(words, &spellings/1)
    command = first.text

    plain? and texts != [nil] and not Enum.member?(texts, nil) and
      Enum.all?(redirects, &harmless_redirect?/1) and
      not Enum.any?(words, & &1.substitution) and
      not Enum.any?(tl(words), &risky_glob?(&1, command)) and
      looking_part?(texts, tests?)
  end

  # Only away from everything: `2>/dev/null`, `2>&1`. Reading from a file is judged by
  # where the file is (`reads_outside?/3`).
  defp harmless_redirect?(%{op: "<"}), do: true
  defp harmless_redirect?(%{op: ">&", target: target}) when target in ~w(1 2), do: true

  defp harmless_redirect?(%{op: op, target: "/dev/null"})
       when op in [">", ">>", "&>", "&>>", ">&"],
       do: true

  defp harmless_redirect?(_redirect), do: false

  # `-*` may expand to a file named `-delete`, and so may a bare `*` for a command whose
  # options write or run things. `lib/*` can't: every name starts with `lib/`.
  defp risky_glob?(%{glob: true, text: text}, command),
    do:
      String.starts_with?(text, "-") or
        (command in @option_sensitive and String.first(text) in ["*", "?", "["])

  defp risky_glob?(_word, _command), do: false

  defp spellings(%{brace: true, text: text}), do: Shell.expand_braces(text) || [nil]
  defp spellings(%{text: text}), do: [text]

  # Whether `workdir` is inside the folder review clones go to.
  defp in_review_clone?(nil), do: false

  defp in_review_clone?(workdir) when is_binary(workdir),
    do: inside?(Path.expand(workdir), Path.expand(Factory.Repos.root()))

  @doc """
  Whether a command runs the project's own code: its tests or a check that builds it
  (`mix test`, `npm run lint`). In a pull request cloned for review, that code is the
  author's, so the person is asked first.
  """
  def runs_project_code?(nil), do: false

  def runs_project_code?(command) when is_binary(command) do
    case Shell.parse(command) do
      {:ok, commands} ->
        Enum.any?(commands, fn %{words: words} ->
          texts = Enum.map(words, & &1.text)
          Enum.any?(@tests, &List.starts_with?(texts, &1))
        end)

      :error ->
        false
    end
  end

  @doc """
  Whether a command reads outside `folder`: a word in it (or a folder it moves to, or what
  a glob or brace expands to) that leads somewhere that exists outside the folder, through
  `..`, the home folder or a symbolic link. Each command is judged from where the `cd`s
  before it put it. `from` is the folder it starts in, the project's unless Kiro's `cwd`
  says otherwise. A pattern that only looks like a path (`grep /api/ lib`) exists nowhere,
  so it doesn't count; a variable (`$HOME`) always does, as it can't be told where it
  leads, and so does a command `Factory.Kiro.Shell` can't read.
  """
  def reads_outside?(command, folder, roots \\ [], from \\ nil)
  def reads_outside?(nil, _folder, _roots, _from), do: false

  def reads_outside?(command, folder, roots, from) when is_binary(command) do
    folder = Path.expand(folder)

    case Shell.parse(command) do
      {:ok, commands} ->
        commands
        |> Enum.reduce_while(from || folder, fn parsed, at ->
          case judged_at(parsed, at, folder, roots) do
            :outside -> {:halt, :outside}
            at -> {:cont, at}
          end
        end)
        |> Kernel.==(:outside)

      :error ->
        true
    end
  end

  # Where the next command runs, or `:outside`.
  defp judged_at(%{words: [%{text: "cd"} | args]}, at, folder, roots) do
    case args do
      [%{variable: false, glob: false, brace: false, text: target}] when target != "-" ->
        moved = absolute(target, at)

        if allowed_path?(moved, folder, roots), do: moved, else: :outside

      _ ->
        :outside
    end
  end

  defp judged_at(%{words: words, redirects: redirects}, at, folder, roots) do
    read_from = for %{op: "<", target: target} <- redirects, do: plain_word(target)

    if Enum.any?(Enum.drop(words, 1) ++ read_from, &word_outside?(&1, at, folder, roots)),
      do: :outside,
      else: at
  end

  defp plain_word(text),
    do: %{text: text, variable: String.contains?(text, "$"), glob: false, brace: false}

  defp word_outside?(%{variable: true}, _at, _folder, _roots), do: true

  defp word_outside?(word, at, folder, roots) do
    case spellings(word) do
      [nil] ->
        true

      spelled ->
        Enum.any?(spelled, fn text ->
          # `--file=/etc/passwd`, `HEAD:lib/a.ex`, `a,b`: each piece may be a path.
          text
          |> String.split(~r/[=:,]/)
          |> Enum.any?(&spelled_outside?(&1, word, at, folder, roots))
        end)
    end
  end

  @doc """
  The files a permission request is about: those its tool call names (`paths_of/1`),
  plus those its earlier `tool_call` update announced (`known` maps tool call ids to
  lists of paths). Empty when it names none.
  """
  def paths(params, known \\ %{}) do
    call = params["toolCall"] || %{}

    (paths_of(call) ++ List.wrap(Map.get(known, call["toolCallId"])) ++ consented(params))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # Kiro says what it asks to touch, on the request itself, for its file tools.
  defp consented(params) do
    case get_in(params, ["_meta", "kiro", "consent"]) do
      %{"capability" => capability, "resource" => resource}
      when capability in ["fs_read", "fs_write"] ->
        [resource]

      _ ->
        []
    end
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
  defp outside_paths(paths, folder, roots),
    do: Enum.reject(paths, &allowed_path?(&1, folder, roots))

  @doc """
  Whether `path`, relative to `workdir`, lies in `workdir` or one of `roots` (each a
  folder: a troubleshooting run's attached files, an agent's sources). Paths are followed to where they really lead first, symbolic links
  and `..` alike, so neither can step outside (a link in a pull request to `/etc`
  is judged as `/etc`), and a path that only shares a prefix with a root
  (`/home/me/project-2` for `/home/me/project`) isn't in it.
  """
  def allowed_path?(path, workdir, roots) when is_binary(path) and is_binary(workdir) do
    full = real(path, workdir)

    Enum.any?([workdir | roots], fn root ->
      is_binary(root) and root != "" and inside?(full, real(root, workdir))
    end)
  end

  def allowed_path?(_path, _workdir, _roots), do: false

  @doc """
  Where Kiro keeps what a tool gave this session that was too big to hand over at once, to
  read back in pieces: its own working files. Only this session's: another session's holds
  what other projects' tools returned.
  """
  def kiro_session_dirs(nil), do: []

  def kiro_session_dirs(session_id) when is_binary(session_id),
    do: Path.wildcard(Path.join([System.user_home!(), ".kiro/sessions/*", session_id]))

  # Where `path` (from `dir`) really leads: each symbolic link on the way followed, and
  # `..` taken after it, as the system does (`link/..` is the folder above the link's
  # target, not the folder the link is in). What doesn't exist stays as written. After
  # 40 links (a loop), the rest isn't followed.
  defp real(path, dir), do: path |> absolute(dir) |> Path.split() |> follow("/", 40)

  # `path` from `dir`, with the home folder for `~`, but `..` kept: not `Path.expand/2`,
  # as `link/..` is the folder above the link's target, which only `follow/3` knows.
  defp absolute("~", _dir), do: System.user_home!()
  defp absolute("~/" <> rest, _dir), do: Path.join(System.user_home!(), rest)
  defp absolute(path, dir), do: Path.absname(path, Path.expand(dir))

  defp follow([], at, _links), do: at
  defp follow(["/" | rest], _at, links), do: follow(rest, "/", links)
  defp follow(["." | rest], at, links), do: follow(rest, at, links)
  defp follow([".." | rest], at, links), do: follow(rest, Path.dirname(at), links)

  defp follow([name | rest], at, links) do
    path = Path.join(at, name)

    case links > 0 && :file.read_link_all(path) do
      {:ok, target} -> follow(Path.split(IO.chardata_to_string(target)) ++ rest, at, links - 1)
      _ -> follow(rest, path, links)
    end
  end

  @doc """
  Why the person should say yes first to a request an agent that only reads and checks
  would otherwise be allowed, or nil. What such an agent reads may be a stranger's pull
  request, and an injected prompt could steer it, so it asks before it:

    * fetches a web page ("fetch"), which could send what it read anywhere;
    * runs the project's own code (`mix test`, a build) in a pull request cloned for
      review (`Factory.Repos.label/1`): that code is the pull request author's;
    * reads outside `folder`, with a command or with Kiro's own tools (`paths`).

  `roots` are folders that count as inside too: a troubleshooting run's attached files
  (`Factory.Evidence`), for the agents allowed to read them. The reason reads after the
  agent's name: "Reviewer wants to …".
  """
  def ask_first(kind, command, paths, folder, roots \\ [])

  def ask_first("fetch", command, _paths, _folder, _roots),
    do:
      "wants to fetch #{command || "a web page"}. What it has read could go along with " <>
        "the request."

  def ask_first("execute", command, paths, folder, roots) do
    elsewhere = outside_paths(paths, folder, roots)
    from = List.first(paths)

    cond do
      elsewhere != [] ->
        "wants to run `#{command}` in #{Enum.join(elsewhere, ", ")}, outside the project folder."

      Factory.Repos.label(folder) != nil and runs_project_code?(command) ->
        "wants to run `#{command}` in a pull request cloned for review. " <>
          "That runs the pull request's own code."

      reads_outside?(command, folder, roots, from && Path.expand(from, folder)) ->
        "wants to run `#{command}`, which reads outside the project folder."

      foreign_repo?(command, folder) ->
        "wants to run `#{command}`, which reads another repository."

      true ->
        nil
    end
  end

  def ask_first(kind, _command, paths, folder, roots) when kind in ["read", "search"] do
    case outside_paths(paths, folder, roots) do
      [] -> nil
      outside -> "wants to read outside the project folder: #{Enum.join(outside, ", ")}."
    end
  end

  def ask_first(_kind, _command, _paths, _folder, _roots), do: nil

  # Files that are outside any folder, and read nothing of anyone's.
  @harmless ~w(/dev/null /dev/stdin /dev/stdout /dev/stderr)

  defp spelled_outside?(text, word, at, folder, roots) do
    # An option may carry its path glued on: `-f/etc/passwd`.
    plain = String.replace(text, ~r/^-+[A-Za-z0-9]*(?=[\/~])/, "")

    cond do
      # `~root`: somebody else's home folder.
      Regex.match?(~r/^~[^\/]/, plain) ->
        true

      plain == "" or String.starts_with?(plain, "-") or plain in @harmless ->
        false

      word[:glob] == true ->
        glob_outside?(plain, at, folder, roots)

      true ->
        path = absolute(plain, at)
        File.exists?(path) and not allowed_path?(path, folder, roots)
    end
  end

  # A glob reads what it expands to: `~/.ssh/id_*` reads `~/.ssh`, and `*/../../x` steps out
  # whatever `*` is. What it finds is judged too: one name may be a link out.
  defp glob_outside?(plain, at, folder, roots) do
    base = plain |> glob_folder() |> absolute(at)

    ".." in Path.split(plain) or (File.exists?(base) and not allowed_path?(base, folder, roots)) or
      plain
      |> absolute(at)
      |> Path.wildcard(match_dot: true)
      |> Enum.take(500)
      |> Enum.any?(&(not allowed_path?(&1, folder, roots)))
  end

  # `gh pr view <link>` for a repository other than the one being reviewed.
  defp foreign_repo?(command, folder) do
    label = Factory.Repos.label(folder)

    with true <- is_binary(command) and String.contains?(command, "gh "),
         {:ok, commands} <- Shell.parse(command) do
      Enum.any?(commands, fn %{words: words} ->
        match?([%{text: "gh"} | _], words) and
          Enum.any?(words, fn %{text: text} ->
            Regex.match?(~r{^https?://}, text) and
              not (label != nil and String.contains?(text, "/#{label}/"))
          end)
      end)
    else
      _ -> false
    end
  end

  defp glob_folder(word) do
    case String.split(word, ~r/[*?\[{]/, parts: 2) do
      [^word] -> word
      [before, _] -> if String.contains?(before, "/"), do: Path.dirname(before), else: "."
    end
  end

  defp inside?(path, folder), do: path == folder or String.starts_with?(path, folder <> "/")

  defp looking_part?(words, tests?) do
    # Settings before the command (GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND…) can make it run
    # another program.
    sets? = Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, List.first(words, ""))

    # The command must be a bare name: a path could be anything, whatever it's called.
    path? = String.contains?(List.first(words, ""), "/")

    not sets? and not path? and not unsafe?(words) and looking_words?(words, tests?)
  end

  # Writing what it shows into a file (`git diff --output=x`, `sort -o x`), or an option
  # that runs another program.
  defp unsafe?([command | args]) do
    {options, letters} = Map.get(@unsafe, command, {[], ""})
    long = Enum.filter(options, &String.starts_with?(&1, "--"))

    Enum.any?(args, fn arg ->
      name = arg |> String.split("=", parts: 2) |> hd()

      String.starts_with?(arg, "--output") or shortened?(name, "--output") or name in options or
        Enum.any?(long, &shortened?(name, &1)) or
        (letters != "" and Regex.match?(~r/^-[^-]/, arg) and
           String.contains?(arg, String.graphemes(letters)))
    end)
  end

  defp unsafe?([]), do: false

  # GNU tools and git take a long option cut short, as long as it's unambiguous.
  defp shortened?(name, option),
    do:
      byte_size(name) > 2 and String.starts_with?(name, "--") and
        String.starts_with?(option, name)

  defp looking_words?([], _tests?), do: false
  defp looking_words?(["cd" | _], _tests?), do: true

  defp looking_words?(["git", sub | _] = words, _tests?),
    do: sub in @git or git_branch_list?(words)

  # GitHub's CLI, reading only: never merge, close, comment, review or edit.
  defp looking_words?(["gh", area, action | args], _tests?) do
    action in Map.get(@gh, area, []) and
      not Enum.any?(args, fn arg ->
        name = arg |> String.split("=", parts: 2) |> hd()
        name in ~w(-R --repo -w --web) or String.starts_with?(arg, "-R")
      end)
  end

  defp looking_words?(["find" | _], _tests?), do: true

  # sed only prints: `-n` (with -E or -r), one address or range and `p`, then files; or
  # one substitution, printed. Its other commands may write (-i, `w`, `s///w`) or run a
  # program (`e`, `s///e`), and GNU sed reads options after the files too
  # (`sed -n 1p file -i`).
  defp looking_words?(["sed" | rest], _tests?) do
    {flags, rest} = Enum.split_while(rest, &String.starts_with?(&1, "-"))

    case rest do
      [script | files] ->
        prints? =
          Enum.any?(flags, &String.contains?(&1, "n")) and Regex.match?(@sed_print, script)

        Enum.all?(flags, &Regex.match?(~r/^-[nEr]+$/, &1)) and
          (prints? or Regex.match?(@sed_substitute, script)) and
          not Enum.any?(files, &String.starts_with?(&1, "-"))

      [] ->
        false
    end
  end

  # `uniq in out` writes out.
  defp looking_words?(["uniq" | rest], _tests?),
    do: Enum.count(rest, &(&1 == "-" or not String.starts_with?(&1, "-"))) < 2

  defp looking_words?([tool, "--version"], _tests?), do: not String.contains?(tool, "/")

  defp looking_words?([tool, flag], _tests?) when flag in ~w(-v -V),
    do: tool in Map.fetch!(@short_versions, flag)

  defp looking_words?([tool, "version"], _tests?) when tool in @versions, do: true

  defp looking_words?([first | _] = words, tests?),
    do: first in @looking or (tests? and Enum.any?(@tests, &List.starts_with?(words, &1)))

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

  @doc """
  What to answer a permission request for a tool of `kind` (with its `command` or the
  `paths` it names): `:allow`, `:reject`, or `{:ask, reason}` when the person should say
  yes first (`ask_first/5`). A session asks them in the chat; a one-off question, with
  nobody to ask, takes it as no. `who` is the agent asking:

    * `:allowed` - the tool kinds it may use (`Factory.Agents.Agent.tools/1`)
    * `:looks` - whether it may run commands that only look (`looking?/2`): a planner
      while it plans, an agent that only reads and checks
    * `:reads_only` - whether it only reads, so a web page, a pull request's own code or
      a file outside the project goes to the person first
    * `:web` - whether it searches the web without asking
    * `:mcp` - whether the request is for an MCP server of its own (Factory's tools),
      which checks for itself what the agent may do
    * `:folder` and `:roots` - the project folder, and folders that count as inside too
    * `:own` - Kiro's working files for this session (`kiro_session_dirs/1`): reading them
      isn't reading the project

  An agent that builds may run commands, but one that can do real damage (`rm -r`, `git
  push`, `curl`…) or that runs a pull request's own code goes to the person first.
  """
  def decide(kind, command, paths, who) do
    # Judged as anywhere else, not as in a review clone (`looking?/2`): the tests of a
    # pull request cloned for review go to the person first (`ask_first/5`).
    looking? =
      kind == "execute" and kind not in who.allowed and who.looks and looking?(command)

    allow? = kind in who.allowed or looking? or who.mcp

    ask =
      cond do
        # One that searches the web freely works from what it's handed, not the project:
        # anything it reads here could go out with its next web request.
        who.web and who.reads_only and allow? and not who.mcp and
            reads_project?(kind, paths, who) ->
          web_ask(kind, command)

        looking? ->
          ask_first(kind, command, paths, who.folder, who.roots)

        kind == "execute" and "execute" in who.allowed and not who.mcp ->
          risky_build(command, who.folder)

        who.reads_only and
            ((kind == "fetch" and not who.web) or (allow? and kind in ["read", "search"])) ->
          ask_first(kind, command, paths, who.folder, who.roots)

        true ->
          nil
      end

    cond do
      # An agent that fetches freely still can't reach this machine or a private network.
      kind == "fetch" and who.web and is_binary(command) and
          not Factory.Actions.safe_url?(command) ->
        :reject

      ask ->
        {:ask, ask}

      allow? ->
        :allow

      true ->
        :reject
    end
  end

  # By what each command really is: `grep -r curl lib` is only a search. A command that
  # runs another one, or a script the shell reader gives up on, by its plain text.
  @runs_others ~w(sh bash zsh dash xargs env timeout nohup time exec eval find parallel)

  defp dangerous?(command) do
    case Shell.parse(command) do
      {:ok, commands} ->
        Enum.any?(commands, fn %{words: words} ->
          dangerous_words?(Enum.map(words, & &1.text), command)
        end)

      :error ->
        Regex.match?(@dangerous, command)
    end
  end

  defp dangerous_words?(["rm" | args], _command),
    do: Enum.any?(args, &Regex.match?(~r/^(-[a-zA-Z]*[rR]|--recursive)/, &1))

  # Trying the project's own server is ordinary work, as long as nothing is sent from a file.
  defp dangerous_words?([name | args], _command) when name in ~w(curl wget),
    do: not Enum.any?(args, &local_url?/1) or Enum.any?(args, &String.contains?(&1, "@"))

  defp dangerous_words?([name | _], _command) when name in ~w(sudo ssh scp nc), do: true
  defp dangerous_words?(["git", sub | _], _command) when sub in ~w(push clean), do: true
  defp dangerous_words?(["git", "reset" | args], _command), do: "--hard" in args

  defp dangerous_words?([name | _], command) when name in @runs_others,
    do: Regex.match?(@dangerous, command)

  defp dangerous_words?(_words, _command), do: false

  defp local_url?(arg),
    do: Regex.match?(~r{^(https?://)?(localhost|127\.0\.0\.1)(:\d+)?(/|$)}, arg)

  defp risky_build(command, folder) do
    cond do
      not is_binary(command) ->
        nil

      Factory.Repos.label(folder) != nil and runs_project_code?(command) ->
        "wants to run `#{command}` in a repository cloned for review. That runs its own code."

      dangerous?(command) ->
        "wants to run `#{command}`, which can delete, publish or send things."

      true ->
        nil
    end
  end

  # A command, or a read or search anywhere but Kiro's own working files (a search
  # without a path looks in the project).
  defp reads_project?("execute", _paths, _who), do: true

  defp reads_project?(kind, paths, who) when kind in ["read", "search"] do
    own = Enum.map(who[:own] || [], &real(&1, who.folder))

    paths == [] or
      not Enum.all?(paths, fn path ->
        full = real(path, who.folder)
        Enum.any?(own, &inside?(full, &1))
      end)
  end

  defp reads_project?(_kind, _paths, _who), do: false

  defp web_ask("execute", command),
    do:
      "searches the web freely, and wants to run `#{command || "a command"}`. " <>
        "What it reads could go out with its next web request."

  defp web_ask(_kind, _command),
    do:
      "searches the web freely, and wants to read the project. " <>
        "What it reads could go out with its next web request."

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
