defmodule Factory.Specs.TaskCheck do
  @moduledoc """
  Whether a task says enough for an agent to build it without guessing, checked by
  fixed rules (instant, and no Kiro call): it says what's true when it's done (its
  objective), has steps, names the code it changes, and says how to check it's done
  (its `Verify:` checks, or for older tasks a check among its steps), under a title
  that says what it is. A thin task (`thin?/1`) gets a warning beside it in the chat's
  plan, with the way to refine it.
  """

  # A file (lib/app/csv.ex, mix.exs), a module (Hello, MyApp.Invoices) or a function
  # (greet/1, Repo.insert): enough for an agent to know where to work.
  @code ~r/`[^`]+`|\b[\w\/.-]+\.(exs?|heex|js|ts|tsx|jsx|svelte|css|py|rb|go|rs|java|kt|cs|php|sql|json|ya?ml|toml|md)\b|\b[A-Z][a-z0-9]+(\.[A-Z][A-Za-z0-9]+)+\b|\b[a-z_][a-z0-9_]*[!?]?\/\d\b/

  # Proof it works: a test, a command to run, something to see.
  @check ~r/\b(tests?|testing|spec|assert\w*|verify|verif\w+|check|checks|confirm\w*|run\b|mix test|npm test|pytest|passes|should (show|return|see)|expect\w*)\b/i

  @doc """
  What a task is missing, as short phrases, or `[]` when it's good enough. `task` has
  `:title`, `:details` (lines), and maybe `:objective` and `:verify` (lines).
  """
  def issues(%{title: title} = task) do
    details = Map.get(task, :details, [])
    verify = Map.get(task, :verify) || []
    text = Enum.join([title | details], "\n")

    [
      blank?(Map.get(task, :objective)) && "no objective",
      details == [] && "no steps",
      not Regex.match?(@code, text <> "\n" <> Enum.join(verify, "\n")) && "no code named",
      (verify == [] and not Regex.match?(@check, text)) && "no way to check it",
      length(String.split(title)) < 3 && "vague title"
    ]
    |> Enum.filter(& &1)
  end

  defp blank?(text), do: String.trim(text || "") == ""

  @doc """
  Whether a task is too thin to build without guessing: no steps at all, or two things
  missing. One gap alone (say, no check in a task whose tests are the next task) isn't.
  """
  def thin?(task) do
    # A missing objective alone doesn't count: plans written before tasks had one
    # would all be marked.
    issues = issues(task) -- ["no objective"]
    "no steps" in issues or length(issues) >= 2
  end
end
