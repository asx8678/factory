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
              sort uniq cut diff basename dirname realpath readlink date printenv)
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

  @doc """
  Whether a shell command only looks: it reads files or the project's history, lists or
  searches, prints a version, runs the tests or a check that builds or lints without
  changing source (`mix compile`, `cargo check`), or reads a pull request with `gh`. A
  planner may run these while it plans, and so may an agent that only reads and checks.
  Anything that could install, write, move, delete, commit or run other code isn't one,
  and nor is an unknown command (nil). Commands may be chained (`&&`, `||`, `;`, `&`) or
  piped when every part only looks; redirecting into a file and substitution (`$(…)`,
  backticks) never do. Every part must start with a bare command name: a path
  (`/tmp/x/cat`) is refused.

  `workdir` is the folder the command runs in. In a repository cloned for review
  (under `Factory.Repos.root/0`) the tests and checks are somebody else's code, so they
  aren't looking there; the rest still is.
  """
  def looking?(command, workdir \\ nil)

  def looking?(nil, _workdir), do: false

  def looking?(command, workdir) when is_binary(command) do
    text = String.replace(command, ~r/\s*\d?>\s*&\d|\s*\d?>\s*\/dev\/null/, "")
    tests? = not in_review_clone?(workdir)

    not String.contains?(text, [">", "`", "$(", "<("]) and
      text
      |> String.split(~r/&&|\|\||;|\||&|\R/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> then(&(&1 != [] and Enum.all?(&1, fn part -> looking_part?(part, tests?) end)))
  end

  # Whether `workdir` is inside the folder review clones go to.
  defp in_review_clone?(nil), do: false

  defp in_review_clone?(workdir) when is_binary(workdir) do
    root = Path.expand(Factory.Repos.root())
    dir = Path.expand(workdir)
    dir == root or String.starts_with?(dir, root <> "/")
  end

  defp looking_part?(part, tests?) do
    # Leading VAR=value settings don't change what the command is.
    words = part |> String.split() |> Enum.drop_while(&Regex.match?(~r/^[A-Z_][A-Z0-9_]*=/, &1))

    # Writing what it shows into a file (`git diff --output=x`, `sort -o x`) isn't looking.
    writes? =
      Enum.any?(words, &String.starts_with?(&1, "--output")) or
        (List.first(words) in ~w(sort tree) and "-o" in words)

    # The command must be a bare name: a path could be anything, whatever it's called.
    path? = String.contains?(List.first(words) || "", "/")

    not writes? and not path? and looking_words?(words, tests?)
  end

  defp looking_words?([], _tests?), do: false
  defp looking_words?(["cd" | _], _tests?), do: true

  defp looking_words?(["git", sub | _] = words, _tests?),
    do: sub in @git or git_branch_list?(words)

  # GitHub's CLI, reading only: never merge, close, comment, review or edit.
  defp looking_words?(["gh", area, action | _], _tests?), do: action in Map.get(@gh, area, [])

  defp looking_words?(["find" | rest], _tests?),
    do: not Enum.any?(rest, &(&1 in ~w(-delete -exec -execdir -ok -fprint)))

  defp looking_words?(["sed" | rest], _tests?),
    do: not Enum.any?(rest, &String.starts_with?(&1, ["-i", "--in-place"]))

  defp looking_words?([_tool, flag], _tests?) when flag in ~w(--version -v -V version), do: true

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

  # ACP permits cancellation when none of the offered options matches the decision.
  def outcome(options, decision) do
    case Enum.find(options, &String.starts_with?(&1["kind"] || "", decision)) do
      %{"optionId" => id} when is_binary(id) -> %{outcome: "selected", optionId: id}
      _ -> %{outcome: "cancelled"}
    end
  end
end
