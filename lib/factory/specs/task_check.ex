defmodule Factory.Specs.TaskCheck do
  @moduledoc """
  Whether a task says enough for an agent to build it without guessing, checked by
  fixed rules (instant, and no Kiro call): it has steps, names the code it changes,
  and says how to check it's done, under a title that says what it is. A thin task
  (`thin?/1`) gets a warning beside it in the chat's plan, with the way to refine it.
  """

  # A file (lib/app/csv.ex, mix.exs), a module (Hello, MyApp.Invoices) or a function
  # (greet/1, Repo.insert): enough for an agent to know where to work.
  @code ~r/`[^`]+`|\b[\w\/.-]+\.(exs?|heex|js|ts|tsx|jsx|svelte|css|py|rb|go|rs|java|kt|cs|php|sql|json|ya?ml|toml|md)\b|\b[A-Z][a-z0-9]+(\.[A-Z][A-Za-z0-9]+)+\b|\b[a-z_][a-z0-9_]*[!?]?\/\d\b/

  # Proof it works: a test, a command to run, something to see.
  @check ~r/\b(tests?|testing|spec|assert\w*|verify|verif\w+|check|checks|confirm\w*|run\b|mix test|npm test|pytest|passes|should (show|return|see)|expect\w*)\b/i

  @doc """
  What a task is missing, as short phrases, or `[]` when it's good enough. `task` has
  `:title`, `:details` (lines) and `:requirements`.
  """
  def issues(%{title: title} = task) do
    details = Map.get(task, :details, [])
    text = Enum.join([title | details], "\n")

    [
      details == [] && "no steps",
      not Regex.match?(@code, text) && "no code named",
      not Regex.match?(@check, text) && "no way to check it",
      length(String.split(title)) < 3 && "vague title"
    ]
    |> Enum.filter(& &1)
  end

  @doc """
  Whether a task is too thin to build without guessing: no steps at all, or two things
  missing. One gap alone (say, no check in a task whose tests are the next task) isn't.
  """
  def thin?(task) do
    issues = issues(task)
    "no steps" in issues or length(issues) >= 2
  end
end
