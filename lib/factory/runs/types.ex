defmodule Factory.Runs.Types do
  @moduledoc """
  The kinds of job a factory run does. Each standard workflow (see `Factory.Workflows`)
  is made for one: it's named after the job and starts from the job's chain of agent
  roles. A run on a custom workflow is "other".

  `describe` is what the new-run wizard suggests writing when you describe the job.

  A workflow step is `%{"kind" => agent kind, "name" => name, "does" => what it does}`;
  the kinds are `Factory.Agents.Agent.kinds/0`.
  """

  @types [
    %{
      id: "feature",
      label: "Build a feature",
      short: "Feature",
      blurb: "Plan it as a spec, then build, test and review it.",
      describe:
        "Who it's for, what they must be able to do, and what should happen. Add anything it must respect: constraints, files it touches, links.",
      workflow: [
        {"planner", "Planner", "Turns the spec into small, ordered tasks"},
        {"coder", "Coder", "Builds each task"},
        {"tester", "Tester", "Writes and runs the tests"},
        {"reviewer", "Reviewer", "Checks the change against the spec"}
      ]
    },
    %{
      id: "bug",
      label: "Fix a bug",
      short: "Bug fix",
      blurb: "Reproduce it, find the cause, fix it with a regression test.",
      describe:
        "What happens, what should happen instead, and how to reproduce it. Paste error messages, logs or stack traces too.",
      workflow: [
        {"researcher", "Investigator", "Reproduces the bug and finds the cause"},
        {"coder", "Fixer", "Fixes the cause, not the symptom"},
        {"tester", "Tester", "Adds a regression test first, then runs the suite"},
        {"reviewer", "Reviewer", "Checks the fix and its side effects"}
      ]
    },
    %{
      id: "issue",
      label: "Resolve an issue",
      short: "Issue",
      blurb: "Work from an issue or ticket: triage it, then fix or build it.",
      describe: "Paste the issue, or a link and a summary. Say what done looks like.",
      workflow: [
        {"planner", "Triage", "Reads the issue and the code, decides fix or feature"},
        {"coder", "Coder", "Makes the change"},
        {"tester", "Tester", "Covers it with tests"},
        {"reviewer", "Reviewer", "Checks it resolves the issue"}
      ]
    },
    %{
      id: "deps",
      label: "Update dependencies",
      short: "Dependencies",
      blurb: "Find what's outdated, upgrade in small batches, keep tests green.",
      describe:
        "Which packages (or all of them), how far to go (minor and patch, or majors too), and anything to watch out for.",
      workflow: [
        {"researcher", "Auditor", "Lists outdated packages and reads their changelogs"},
        {"coder", "Upgrader", "Upgrades in small batches and fixes breakages"},
        {"tester", "Tester", "Runs the suite after each batch"},
        {"reviewer", "Reviewer", "Checks for risky changes"}
      ]
    },
    %{
      id: "other",
      label: "Something else",
      short: "Other",
      blurb: "Describe the job; Kiro suggests how to do it.",
      describe: "What should be done, and how you'll know it's done.",
      workflow: [
        {"planner", "Planner", "Breaks the job into tasks"},
        {"coder", "Coder", "Does the work"},
        {"reviewer", "Reviewer", "Checks the result"}
      ]
    }
  ]

  def all, do: @types
  def ids, do: Enum.map(@types, & &1.id)
  def get(id), do: Enum.find(@types, &(&1.id == id))
  def short(id), do: (get(id) || %{short: "Chat"}).short

  @doc """
  A type's default workflow, as it comes. The standard workflows are built from it
  and restored to it (`Factory.Workflows.restore/1`).
  """
  def workflow(id), do: Enum.map(get(id).workflow, &step/1)

  defp step({kind, name, does}), do: %{"kind" => kind, "name" => name, "does" => does}
end
