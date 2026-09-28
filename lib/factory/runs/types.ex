defmodule Factory.Runs.Types do
  @moduledoc """
  The kinds of job a factory run does, and what each needs: the questions asked
  when starting one, the workflow recommended for it (a chain of agent roles), and
  how the answers become the spec's overview.

  A workflow step is `%{"kind" => agent kind, "name" => name, "does" => what it does}`;
  the kinds are `Factory.Agents.Agent.kinds/0`.
  """

  @types [
    %{
      id: "feature",
      label: "Build a feature",
      short: "Feature",
      blurb: "Plan it as a spec, then build, test and review it.",
      fields: [
        {"what", "What do you want to build?", :textarea,
         "Who it's for, what they must be able to do, and what should happen."},
        {"notes", "Anything to respect?", :textarea,
         "Optional: constraints, files or modules it touches, links."}
      ],
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
      fields: [
        {"happens", "What happens?", :textarea, "The wrong behaviour, error message or crash."},
        {"expected", "What should happen instead?", :textarea, "The right behaviour."},
        {"steps", "How to reproduce it", :textarea,
         "Optional: steps, logs, stack traces, where you saw it."}
      ],
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
      fields: [
        {"issue", "The issue", :textarea, "Paste the issue text, or a link and a summary."},
        {"notes", "Anything to add?", :textarea, "Optional: what done looks like, priorities."}
      ],
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
      fields: [
        {"which", "Which packages?", :text, "All, or a list like phoenix, ecto"},
        {"scope", "How far?", {:select, ["Minor and patch only", "Majors too"]}, nil},
        {"notes", "Anything to watch out for?", :textarea,
         "Optional: pinned versions, known breakages."}
      ],
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
      fields: [{"what", "What should be done?", :textarea, "Describe the job."}],
      workflow: [
        {"planner", "Planner", "Breaks the job into tasks"},
        {"coder", "Coder", "Does the work"},
        {"reviewer", "Reviewer", "Checks the result"}
      ]
    }
  ]

  @roles [
    {"planner", "Planner", "Plans the work as small tasks"},
    {"researcher", "Investigator", "Reads the code and finds out what's going on"},
    {"coder", "Coder", "Writes the code"},
    {"tester", "Tester", "Writes and runs tests"},
    {"reviewer", "Reviewer", "Reviews the change"},
    {"writer", "Writer", "Writes docs and changelogs"},
    {"orchestrator", "Orchestrator", "Coordinates the other agents"},
    {"general", "Helper", "Does whatever is needed"}
  ]

  def all, do: @types
  def ids, do: Enum.map(@types, & &1.id)
  def get(id), do: Enum.find(@types, &(&1.id == id))
  def short(id), do: (get(id) || %{short: "Chat"}).short

  @doc "Agent roles a workflow can be built from, as steps."
  def roles, do: Enum.map(@roles, &step/1)

  def role(kind), do: @roles |> Enum.find(&(elem(&1, 0) == kind)) |> step()

  @doc """
  A type's default workflow, as it comes. The standard workflows are built from it
  (and restored to it); what a run recommends is the standard workflow as the person
  has it now, see `Factory.Workflows.recommended_steps/1`.
  """
  def workflow(id), do: Enum.map(get(id).workflow, &step/1)

  defp step(nil), do: nil
  defp step({kind, name, does}), do: %{"kind" => kind, "name" => name, "does" => does}

  @doc "Settings a new run of this type starts with: everything recommended."
  def default_settings(id) do
    workflow = Factory.Workflows.standard(id)

    %{
      "workflow_mode" => "recommended",
      "workflow_id" => workflow && workflow.id,
      "workflow" => Factory.Workflows.recommended_steps(id),
      "setup_mode" => "recommended",
      "model" => "auto",
      "approve_plan" => true,
      "project_dir" => ""
    }
  end

  @doc "A short title from the answers: the first line of the first one given."
  def title(id, answers) do
    get(id).fields
    |> Enum.map(fn {key, _, _, _} -> answers[key] || "" end)
    |> Enum.find("", &(String.trim(&1) != ""))
    |> String.split(~r/\R/u, trim: true)
    |> List.first("")
    |> String.trim()
    |> then(&if(String.length(&1) > 70, do: String.slice(&1, 0, 67) <> "…", else: &1))
  end

  @doc "Whether the answers are enough to start: the first question is answered."
  def ready?(id, answers) do
    [{key, _, _, _} | _] = get(id).fields
    String.trim(answers[key] || "") != ""
  end

  @doc "The answers as the spec's overview, in markdown."
  def overview(id, title, answers) do
    type = get(id)

    sections =
      for {key, label, _, _} <- type.fields,
          text = String.trim(answers[key] || ""),
          text != "",
          do: "## #{label}\n\n#{text}"

    Enum.join(["# #{type.label}: #{title}" | sections], "\n\n") <> "\n"
  end
end
