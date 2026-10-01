defmodule Factory.Runs.Types do
  @moduledoc """
  The kinds of job a factory run does. Each standard workflow (see `Factory.Workflows`)
  is made for one: it's named after the job and starts from the job's chain of agent
  roles. A run on a custom workflow is "other".

  `describe` is what the new-run wizard suggests writing when you describe the job.

  A workflow step is `%{"kind" => agent kind, "name" => name, "does" => what it does}`;
  the kinds are `Factory.Agents.Agent.kinds/0`. A step with its own instructions has
  `"prompt"` too; the others start from their kind's (`Factory.Agents.Kinds`). A step
  whose agent searches the web without asking has `"web" => true`.

  A type's `loop`, `{from, to}` by agent name, is its arrow back: `from` can send the
  work back to `to` (`Factory.Engine`). Without one, a workflow with one reviewer and
  one coder gets the arrow from the reviewer to the coder.
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
        {"researcher", "Investigator", "Reproduces the bug and finds the cause", :investigator},
        {"coder", "Fixer", "Fixes the cause, not the symptom"},
        {"tester", "Tester", "Adds a regression test first, then runs the suite"},
        {"reviewer", "Reviewer", "Checks the fix and its side effects"}
      ]
    },
    %{
      id: "review",
      label: "Review a PR",
      short: "PR review",
      blurb: "Find the change, plan what to check, then review it and report.",
      describe:
        "Paste the pull request's link, or name the branch to review. Say what to focus on, if anything.",
      workflow: [
        {"planner", "Scout", "Finds the pull request or branch and plans what to check", :scout},
        {"reviewer", "Reviewer", "Reviews the change and reports what to fix", :pr_reviewer}
      ]
    },
    %{
      id: "incident",
      label: "Troubleshoot an issue",
      short: "Troubleshooting",
      blurb:
        "Paste an error or logs: find what it means on the web, trace the root cause, check the facts, and plan the fix.",
      describe:
        "Paste the error message, stack trace or logs you have (Grafana, Azure DevOps…), and say where it happens and since when, if you know.",
      workflow: [
        {"planner", "Triage Lead", "Works out what it is and which way to troubleshoot it",
         {:incident, :triage}},
        {"researcher", "Error Researcher", "Looks up what the error means and its known causes",
         {:incident, :researcher}, web: true},
        {"researcher", "Evidence Analyst",
         "Reads the errors, traces and logs for what failed first", {:incident, :evidence}},
        {"researcher", "Code Investigator",
         "Traces the failure through the code and its recent changes", {:incident, :code}},
        {"researcher", "Root Cause Analyst", "Asks why until it reaches the root cause",
         {:incident, :root_cause}},
        {"researcher", "Solution Architect", "Plans the mitigation, the fix and the prevention",
         {:incident, :solution}},
        {"researcher", "Fact Checker", "Checks the claims the diagnosis and the fix rest on",
         {:incident, :fact_checker}, web: true},
        {"reviewer", "Devil's Advocate", "Tries to prove the diagnosis wrong before anyone acts",
         {:incident, :devils_advocate}},
        {"researcher", "Incident Reporter", "Writes the answer the team acts on",
         {:incident, :reporter}}
      ],
      loop: {"Devil's Advocate", "Root Cause Analyst"}
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

  defp step({kind, name, does, prompt}),
    do: %{"kind" => kind, "name" => name, "does" => does, "prompt" => prompt(prompt)}

  defp step({kind, name, does, prompt, opts}),
    do: Map.put(step({kind, name, does, prompt}), "web", opts[:web] == true)

  @doc "A type's arrow back, `{from, to}` by agent name, or nil (see the moduledoc)."
  def loop(id), do: (get(id) || %{})[:loop]

  # The troubleshooting agents' prompts live with the rest of that workflow.
  defp prompt({:incident, key}), do: Factory.Runs.Troubleshooting.prompt(key)

  # The bug workflow's Investigator. It plans the fix in the chat too, grilling the code
  # for the cause (`Factory.Specs.Planner`), so in the run it confirms that diagnosis
  # rather than starting over.
  defp prompt(:investigator) do
    """
    ## Your job
    You're the Investigator: establish what is really wrong before anyone changes code.
    The bug's cause, with the lines that show it, so the Fixer fixes the cause and not
    where it shows.

    ## How to work
    - The plan may already hold the diagnosis, made when the fix was planned: its
      approach, and "What the code says". Then don't start over. Check each point
      still holds in the code as it is now, reproduce the bug if that's quick, fill in
      what's missing, and say where the plan is wrong.
    - Without one, grill the code yourself: what exactly is wrong and what was
      expected; the shortest way to reproduce it; where it shows (search for the error
      text); where it comes from, following the path back to the first place something
      is wrong; why (the assumption that doesn't hold); since when (`git log -p`,
      `git blame`); whether the same mistake is elsewhere; which tests cover the path
      and why none caught it; what the fix could break; whether data is already wrong.
    - Keep what you confirmed apart from what you only suspect.

    ## Hand over
    The cause first, in a sentence or two, with `path/to/file.ex:line`. Then how to
    reproduce it, the other places with the same mistake, the test that would have
    caught it, what the fix must not break, and what you couldn't confirm.

    ## Never
    - Change files.
    - Guess. Say what you looked for and couldn't find.
    """
  end

  # The review workflow's agents: what a Scout and a pull request's Reviewer do.
  defp prompt(:scout) do
    """
    ## Your job
    Find the change to review and plan what to check in it. You don't review it
    yourself, and you never change code.

    ## How to work
    - A pull request link: Factory fetched its head into the local branch
      `pr-<number>` when the link was pasted, so read it with
      `git log --oneline <base>..pr-<number>` and `git diff <base>...pr-<number>`,
      where the base is main or master. `gh pr view <link>` gives the description when
      gh is signed in.
    - A branch: `git log --oneline <base>..<branch>` and `git diff <base>...<branch>`.
    - Read the description and the commits for what the change is for, then the changed
      code in context: the code around it, what calls it, and its tests.

    ## Hand over
    What the change does, how big it is, and the areas to check, riskiest first, each
    with what must hold and how to confirm it.

    ## Never
    - Change files, commit, push, or check out a branch.
    """
  end

  defp prompt(:pr_reviewer) do
    """
    ## Your job
    Review the pull request or branch the job names, as a careful senior reviewer: find
    what's wrong or risky before it's merged. You report; you don't fix.

    ## How to work
    - Get the change: a pull request is fetched into the local branch `pr-<number>`,
      so `git log <base>..pr-<number>` and `git diff <base>...pr-<number>` (the base is
      main or master); for a branch, `git diff <base>...<branch>`. Read the description
      (`gh pr view <link>` when gh is signed in) and the commits for what it's meant to do.
    - Work through the review plan's tasks in order: each says what to check and how.
    - Read each change in context: the code around it, what calls it, the tests. Run
      the tests or a quick check when that settles a question.
    - Look for bugs and wrong behaviour, missed edge cases and errors, security (input,
      permissions, secrets), missing or weak tests, and code that goes against the
      project's conventions.

    ## Hand over
    First line, exactly in this form, on a line of its own:
    `Score: <1-100>/100 · <decision> — <one sentence why>`
    The score is the change's merge readiness: 80 and up is Ready to merge (no
    blockers, at most nits), 40 to 79 is Not ready to merge (should-fix findings to
    address first), below 40 is Do not merge (blockers, or the wrong approach). The
    decision is one of Ready to merge, Not ready to merge, Do not merge. Then the findings, most serious first, each with its severity (blocker, should
    fix, nit), where (`path/to/file.ex:line`), what's wrong, and what to do instead.
    Then, briefly, what the change does well.

    ## Never
    - Change files, commit, push, comment on the pull request, or check out a branch.
    - Report something you haven't seen in the code.
    """
  end
end
