defmodule Factory.Specs.Planner do
  @moduledoc """
  Kiro suggests tasks for a spec in two turns, each in a fresh read-only session
  in the project folder:

    1. Kiro reads the project and asks the questions whose answers would change
       how it builds the feature, each with options a, b, c…
    2. With the answers, it suggests about 20 tasks in build order.

  The first turn's summary of the project is passed to the second, so Kiro doesn't
  start from nothing. Replies are JSON; the parsers keep only what they understand.
  """
  alias Factory.Text

  # The one shape a task has wherever Kiro writes one: suggestions, a run's plan, a chat
  # plan without tools, an improved or drafted task, and `Factory.PlanTools.add_tasks`.
  @task_json ~s|{"title": "<imperative, under 80 characters>", "objective": "<one or two sentences: what is true when it's done>", "details": ["<a step of the approach, in order, naming the files and functions it changes; 1 to 8 items; code and paths in backticks>"], "verify": ["<a check that proves it's done: a command and what it must show, a test that must pass, or what to look at; 1 to 4 items>"], "agent": "<who builds it, from the list>", "model": "<the model to build it with, from the list>", "requirements": ["<requirement number, e.g. 1.2>"]}|

  @doc """
  What Kiro may do in the project while it plans: read anything, and run commands that
  only look (`Factory.Kiro.Permission.looking?/2`), never change anything.
  """
  def looking_rule do
    "Don't change any files. You may run commands that only look: `git status` and " <>
      "`git log`, listing and searching files, a tool's version, or the project's tests " <>
      "when they run quickly. Factory refuses anything that installs, writes, moves, " <>
      "deletes or commits."
  end

  @doc "The task shape Kiro is asked for, as JSON with placeholders."
  def task_json, do: @task_json

  @doc """
  A task Kiro wrote, in the one shape: `%{"title", "objective", "details" => [step],
  "verify" => [check], "model", "requirements" => [ref]}`, or nil without a title.
  Lists may come as lists or as text (one per line). A model this Kiro doesn't offer
  is dropped (nil), so a made-up name never reaches a run.
  """
  def task(%{"title" => title} = t) when is_binary(title) do
    case title |> String.replace(~r/\s*\R\s*/u, " ") |> String.trim() do
      "" ->
        nil

      title ->
        %{
          "title" => String.slice(title, 0, 200),
          "objective" =>
            t["objective"] |> Text.text() |> String.replace(~r/\s*\R\s*/u, " ") |> String.slice(0, 500),
          # Only text: a number among the details is noise, unlike a requirement's "1.2".
          "details" =>
            t["details"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Text.lines() |> Enum.take(12),
          "verify" =>
            t["verify"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Text.lines() |> Enum.take(6),
          "agent" =>
            if(is_binary(t["agent"]) and String.trim(t["agent"]) != "",
              do: String.trim(t["agent"])
            ),
          "model" => if(t["model"] in Factory.Kiro.task_models(), do: t["model"]),
          "requirements" =>
            t["requirements"] |> List.wrap() |> Enum.map(&to_string/1) |> Text.lines() |> Enum.take(8)
        }
    end
  end

  def task(_), do: nil

  @doc """
  What every task says, wherever Kiro writes one (the chat's plan, the Spec page, a
  run's plan, an improved or a new task): what to do, a suggested way to do it, and
  how to check it was done right, with the model to build it on.
  """
  def task_standard(agents \\ []) do
    """
    Every task says what to do, a suggested way to do it, and how to check it was done \
    right, so the agent that builds it doesn't guess and a different model can verify it:
    - title: what changes, imperative, under 80 characters.
    - objective: one or two sentences on what is true when it's done, in terms the \
    person would recognise: behaviour and outcomes, not code.
    - details, the approach: the steps in order, each naming the exact files and \
    functions it changes and what changes in them, done the way the code works today. \
    Name files by their path in the project (`lib/app/csv.ex`), not on this computer.
    - verify: 1 to 4 checks that prove it's done correctly, each one something a \
    reviewer who didn't build it can run or see: a command and what it must show \
    (`mix test test/app/export_test.exs` passes), a test that must exist and pass, or \
    what to look at and where. "It works" isn't a check.
    #{agent_guide(agents)}- model: the model to build it with: #{model_guide()}
    - requirements: the requirement numbers it covers, when the spec numbers them.
    Keep each task one change that can be built and verified on its own, and put the \
    tests a change needs in its own task's steps and checks.
    """
  end

  # Who a task may be given to: the workflow's agents that build (`Factory.Workflows.
  # builders/1`), each with what it does. Nothing when there's nobody to choose from.
  defp agent_guide([]), do: ""

  defp agent_guide(agents) do
    who =
      Enum.map_join(agents, "; ", fn a ->
        if a.does in [nil, ""], do: a.name, else: "#{a.name} (#{String.downcase(a.does)})"
      end)

    "- agent: which agent builds it, by name: #{who}. Give each task to the one whose " <>
      "work it is, a task that's only tests to the one that tests.\n"
  end

  # The models a task may name, from what this Kiro offers (Sonnet never), with when to
  # pick each. A coding agent builds on its own model, Auto unless set on its card.
  defp model_guide do
    models = Factory.Kiro.task_models()
    strong = Factory.Kiro.strongest()

    light =
      models |> Enum.filter(&String.contains?(&1, "haiku")) |> Enum.sort(:desc) |> List.first()

    [
      "auto" in models && "auto for most tasks, and always for the ones the coding agent builds",
      strong != "auto" && "#{strong} for tricky, cross-cutting or risky ones",
      light && "#{light} for small, mechanical edits"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
    |> Kernel.<>(".")
  end

  @doc "The tasks in `list` that have a title, in the one shape (`task/1`)."
  def tasks(list), do: list |> List.wrap() |> Enum.map(&task/1) |> Enum.reject(&is_nil/1)

  @doc """
  The tasks (`task/1`'s shape) with no two titles the same, nor one in `taken` (the
  titles of tasks they're added to): a repeat gets a count, "Add the form (2)". A run
  finds its tasks by title, so titles must be unique.
  """
  def unique_titles(tasks, taken \\ []),
    do: Factory.Spec.rename_duplicates(tasks, taken, & &1["title"], &Map.put(&1, "title", &2))

  @doc "Prompt for turn 1: read the project, then ask questions."
  def questions_prompt(files) do
    """
    <task-planning step="questions">
    You are planning how to build the spec below in the project in the current folder.

    First look at the project: read the files you need to understand its structure, stack, \
    conventions and the code this feature touches. #{looking_rule()}

    Then ask the 3 to 6 questions whose answers would most change how you build it: \
    choices about behaviour, scope, data or approach that the spec leaves open. \
    Give each 2 to 4 short options; put the one you recommend first.

    Reply with only this JSON object and nothing else:
    {"project": "<4 to 8 sentences: stack, structure, conventions, and the files and modules this feature touches>", "questions": [{"question": "<the question>", "why": "<one sentence: what it changes>", "options": ["<recommended option>", "<option>"]}]}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc "Prompt for turn 2: suggest tasks, using the project summary and the answers."
  def tasks_prompt(files, project, answers, agents \\ []) do
    qa =
      case answers do
        [] ->
          "The person skipped the questions: use your recommended options."

        answers ->
          Enum.map_join(answers, "\n", fn a -> "- #{a["question"]}\n  Answer: #{a["answer"]}" end)
      end

    """
    <task-planning step="tasks">
    You are planning how to build the spec below in the project in the current folder. \
    #{looking_rule()}

    What you found about the project on a first look:
    #{project}

    Questions and answers:
    #{qa}

    Work through it in this order, and don't skip reading the code:
    1. From the spec and the answers, list for yourself each thing that must be true \
    when this is done.
    2. Read the code this touches: the files and functions that change, what depends \
    on them (callers, templates, routes, migrations, config), and the tests that cover \
    them and how they're written. The summary above is a start, not enough to plan from.
    3. Plan the tasks in build order, as many as the work needs and no more: usually 3 \
    to 10, more for a big feature. Every expectation from step 1 is covered by a task, \
    and nothing goes further than the spec asks. Don't repeat tasks the spec's tasks \
    file already has.

    #{String.trim(task_standard(agents))}

    Add them with the factory tool suggest_tasks, 2 to 5 at a time, in build order, then \
    end your turn with one short sentence. The person picks which to keep.

    Only if the factory tools aren't available, reply instead with only this JSON object, \
    each task as shown plus its size ("S", "M" or "L"):
    {"tasks": [#{String.trim_trailing(@task_json, "}")}, "size": "S"}]}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc """
  Prompt for improving one task: Kiro reads the code the task touches, checks it against
  the tasks around it, then rewrites it following the person's instruction (or, with
  none, so it can be built without guessing). `asked` is what the person asked for in
  the chat that made the plan, when there is one.
  """
  def improve_prompt(files, task, instruction, asked \\ "", agents \\ []) do
    ask =
      case String.trim(instruction) do
        "" -> "Make it ready to build without guessing."
        text -> text
      end

    current =
      Enum.join(
        ["Title: #{task.title}"] ++
          List.wrap(task[:objective] && "Objective: #{task.objective}") ++
          Enum.map(task.details, &"- #{&1}") ++
          Enum.map(Map.get(task, :verify, []), &"Verify: #{&1}") ++
          List.wrap(task[:model] && "Model: #{task.model}") ++
          if(task.requirements == [],
            do: [],
            else: ["Requirements: #{Enum.join(task.requirements, ", ")}"]
          ),
        "\n"
      )

    asked =
      case String.trim(asked || "") do
        "" -> ""
        text -> "\nWhat the person asked for, which the whole plan serves:\n#{text}\n"
      end

    """
    <task-planning step="improve">
    You are improving one implementation task of the spec below, for the project in the \
    current folder. #{looking_rule()}

    The task now:
    #{current}

    What the person wants done better:
    #{ask}
    #{asked}
    Before you rewrite it:
    1. Read the code it touches. Open every file and function it names, check they exist \
    and are spelled right, and find the real ones where they're wrong or missing.
    2. Find the tests that cover that code and how they're written, and what else \
    depends on it (callers, templates, routes, migrations, config).
    3. Read the tasks before and after it in tasks.md: it shouldn't redo their work or \
    use anything built after it.

    Then rewrite it to the task standard below. Keep what the person wrote unless it's \
    wrong, and don't add work beyond what the task is for. Keep requirement numbers that \
    still apply. Wrap code, paths and commands in `backticks`.

    #{String.trim(task_standard(agents))}

    #{json_shape()}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc """
  Prompt for writing one new task from the person's rough idea. Kiro takes a quick
  look at the project (only the few files the task touches), then writes the task
  so it fits the spec and the tasks already there.
  """
  def draft_prompt(files, title, notes, agents \\ []) do
    idea =
      [String.trim(title), String.trim(notes)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
    <task-planning step="draft">
    You are turning the person's rough idea into one new implementation task for the \
    spec below, for the project in the current folder. #{looking_rule()}

    The person's rough idea for the task:
    #{idea}

    Before you write it, take a quick, focused look (about 5 to 8 files):
    1. Find where the idea lands in the code: the files and functions it changes. Check \
    the ones the person named exist and are spelled right, and find the real ones where \
    they're wrong.
    2. Find the tests that cover that code and how they're written.
    3. Read the spec's tasks: don't repeat what one already does, and note which task \
    this one should come after.

    Then write it to the task standard below. Keep to what the person meant: fill in \
    what's missing, and don't add work they didn't ask for. Use the spec's requirement \
    numbers it covers. Wrap code, paths and commands in `backticks`.

    #{String.trim(task_standard(agents))}

    #{json_shape()}
    </task-planning>

    #{spec_text(files)}
    """
  end

  # What each part of the spec is, when Kiro writes it for a run, and its JSON.
  @run_parts [
    {"requirements",
     ~s|- "requirements": markdown. What must be true when the job is done, as numbered \
requirements with WHEN/THEN acceptance criteria (for a bug: the expected behaviour).|,
     ~s|"requirements": "<markdown>"|},
    {"design",
     ~s|- "design": markdown. How it will be done: the parts of the code that change, the \
approach, risks and how it will be tested (for a bug: the likely cause and the fix).|,
     ~s|"design": "<markdown>"|},
    {"tasks",
     ~s|- "tasks": implementation tasks in build order, each written to the task standard below.|,
     ~s|"tasks": [#{@task_json}]|}
  ]

  @doc """
  Prompt for planning a factory run in one turn: Kiro reads the project and writes the
  parts of the spec that are missing (`write:`, some of "requirements", "design" and
  "tasks"), keeping to the parts the person gave. `agents:` names the agents that will
  do the work, in order.
  """
  def run_prompt(type, files, opts) do
    write = Keyword.fetch!(opts, :write)
    builders = Keyword.get(opts, :builders, [])
    given = for {part, _, _} <- @run_parts, part not in write, do: part

    keep =
      if given != [],
        do:
          "The spec already has its #{Enum.join(given, " and ")}: keep to them and don't rewrite them.",
        else: ""

    size =
      if "tasks" in write,
        do:
          "As many tasks as the work needs and no more: usually 3 to 10, more for a big feature.\n\n" <>
            String.trim(task_standard(builders)),
        else: ""

    asked = for {part, what, _} <- @run_parts, part in write, do: what
    json = for {part, _, shape} <- @run_parts, part in write, do: shape

    """
    <task-planning step="run">
    You are planning a job for a software factory: "#{type.label}". The spec files below \
    say what the person wants; the project is in the current folder. Look at the project \
    first: read the files you need to understand its stack, structure, conventions and the \
    code this job touches. #{looking_rule()}

    Then write the parts of the spec that are missing. #{keep}
    #{Enum.join(asked, "\n")}
    #{size}

    The agents that will do the work: #{Keyword.get(opts, :agents, "")}.

    Reply with only this JSON object and nothing else:
    {#{Enum.join(json, ", ")}, "why": "<one or two sentences: what you found in the project and how you approached the plan>"}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc """
  Reads a run plan written for the parts in `write` (see `run_prompt/3`):
  `{:ok, %{requirements:, design:, tasks: [task], why:}}`, with tasks in `to_markdown/2`'s
  shape. Every part asked for must be there; the others are left empty.
  """
  def parse_run_plan(reply, write \\ ~w(requirements design tasks)) do
    with {:ok, data} <- decode(reply) do
      tasks = tasks(data["tasks"])

      plan = %{
        requirements: Text.text(data["requirements"]),
        design: Text.text(data["design"]),
        tasks: Enum.take(tasks, 30),
        why: Text.text(data["why"])
      }

      cond do
        "tasks" in write and tasks == [] ->
          {:error, "Kiro's plan had no tasks."}

        "requirements" in write and plan.requirements == "" ->
          {:error, "Kiro's plan had no requirements."}

        "design" in write and plan.design == "" ->
          {:error, "Kiro's plan had no design."}

        true ->
          {:ok, plan}
      end
    end
  end

  @doc """
  `chat_prompt/5` in two parts for a planner's own Kiro session: `{brief, ask}`, the
  spec files and the rest. The session sends the brief only when it hasn't yet.
  """
  def chat_prompt_parts(name, requests, files, current, action \\ nil, job \\ nil, agents \\ []),
    do:
      {spec_text(files),
       name |> chat_prompt(requests, [], current, action, job, agents) |> String.trim_trailing()}

  @doc """
  Prompt for planning in a chat: the planner reads the project, rethinks how the
  person's requests (oldest first) are best done, and writes the plan with Factory's
  tools (`Factory.PlanTools`): a summary and approach first, then its tasks a few at a
  time. `current` is the plan so far (`Factory.PlanTools.describe/1`), which it refines
  rather than starting over. Without the tools it replies with JSON (`parse_chat_plan/1`).

  `action` is a button in the chat's plan instead of a message:
  `%{mode: :scope, thin: [line]}` checks the scope of work and reports, changing
  nothing; `%{mode: :refine, thin: [line], findings: text | nil}` reworks the plan,
  acting on a scope check's `findings`. `thin` is what Factory's own rules found
  missing in tasks (`Factory.Specs.TaskCheck`), one line per task.

  `job` is the kind of workflow the chat plans for (`Factory.Workflows.kind/1`): for
  "review", the planner (the Scout) finds a pull request or branch and plans what to
  check in it, not changes to make.
  """
  def chat_prompt(name, requests, files, current, action \\ nil, job \\ nil, agents \\ []) do
    asked = requests |> Enum.with_index(1) |> Enum.map_join("\n\n", fn {r, i} -> "#{i}. #{r}" end)

    current =
      if String.trim(current || "") == "",
        do: "None yet.",
        else: current

    mode = action && action.mode

    """
    <task-planning step="#{step(mode)}">
    You are #{name}, the planner in a software factory. #{about(job)} #{looking_rule()}

    #{String.trim(instructions(mode, job, agents))}

    The plan so far:
    #{current}
    #{thin_text(action)}
    </task-planning>

    <requests>
    The person's messages, oldest first. Later ones refine or override earlier ones; \
    answers to your questions are among them.

    #{asked}
    </requests>
    #{findings_text(action)}
    #{spec_text(files)}
    """
  end

  defp about("review"),
    do:
      "The person wants a change to the project in the current folder reviewed: a pull " <>
        "request, or a branch."

  defp about(_job),
    do: "The person is chatting with you about a change to the project in the current folder."

  defp step(nil), do: "chat"
  defp step(:scope), do: "scope-check"
  defp step(:refine), do: "refine"

  defp instructions(nil, "review", _agents) do
    """
    Plan the review the way a careful senior reviewer would, in this order:

    1. Find the change. The latest message names it:
       - A pull request link: `gh pr view <link>` for its title, description, base and \
    branch, and `gh pr diff <link>` for the change. When gh isn't signed in, read the \
    link with `.diff` added (public repositories), or find the pull request's branch \
    here with `git branch -a`.
       - A branch: `git log --oneline <base>..<branch>` and `git diff --stat \
    <base>...<branch>`, then `git diff <base>...<branch>`, where the base is main or \
    master.
       - Uncommitted changes: `git status` and `git diff --stat`, then `git diff`.
       - The latest commits on a branch: `git log --oneline -<n>` and `git diff \
    <oldest>~1..<newest>`.
       - Neither, or you can't find it: call ask_user, offering the branches with the \
    latest work (`git branch --sort=-committerdate`) and asking for a link.
    2. Work out what it's for: the description, the commit messages, any issue it names.
    3. Read the changed code in context: the code around each change, what calls it, \
    and the tests that cover it, and the project's own rules (README, AGENTS.md, \
    CLAUDE.md).
    4. Write the review plan with the factory tools: create_plan with a one-sentence \
    summary of what the change does and the approach (base and branch, how many files, \
    and where the risk is), then add_tasks, one task per area to check, riskiest \
    first. You plan checks, not changes: nothing in the plan edits code.
       - title: what to check, e.g. "Check the token refresh in lib/auth/session.ex".
       - objective: what must hold for that part to be right.
       - details: what to look at, file by file, and what could be wrong there.
       - verify: how the reviewer confirms it: a test to run, a case to trace through \
    the code, a command and what it must show.
       - model: #{model_guide()}
       Cover correctness, edge cases and errors, security (input, permissions, secrets), \
    tests for the change, and fit with the project's conventions. A small change is one \
    or two tasks.
    5. Check it: call get_plan and read it as the reviewer who'll follow it.

    End with a short reply to the person, 2 to 4 sentences: what the change is, how big, \
    and where you'd look hardest. Don't list the tasks: Factory shows them.
    """
  end

  defp instructions(mode, _job, agents), do: instructions(mode, agents)

  defp instructions(nil, agents) do
    """
    Plan it the way a senior engineer would before anyone writes code, in this order:

    1. Understand the ask. Work out what the person wants and why, what "done" looks \
    like to them, and what they clearly expect but didn't say. The latest message \
    decides what this turn is about.
    2. Look before you plan; never plan from the request alone. Check:
       - the project's own guidance: its README, and AGENTS.md, CLAUDE.md or steering \
    files, for its conventions and rules;
       - what's going on in it: `git status` and `git log --oneline -15`;
       - what's already there: search for code that does this or something close, and \
    read the code the change touches, what calls it, and the tests that cover it;
       - how it's built and checked: its test command, and the tests for that part if \
    they run quickly.
    3. Decide whether it should be done. Don't plan it when it would break what works, \
    repeat what the project already has, go against its design or rules, put data, \
    security or secrets at risk, or cost far more than it's worth. Reply instead, in 3 \
    to 6 sentences: say plainly that you wouldn't do it and why, pointing at what you \
    found in the code, and what you'd do instead. When part of it is sound, plan that \
    part and say what you left out. When it's already done, say where.
    4. If it isn't clear enough to plan without guessing (what should be built, where \
    it goes, how to tell it works), call ask_user with 1 to 5 short, specific \
    questions, with options where that helps, and leave the plan as it is.
    5. Choose the approach: of the ways that fit this codebase, the simplest that fully \
    does the job. Know what could go wrong with it.
    6. Write the plan with the factory tools:
       - With no plan yet, or when the person wants a different one: create_plan with a \
    one-sentence summary and the approach (the parts of the code that change and why, \
    the risks, how it will be tested), then add_tasks, 2 to 5 per call, in build \
    order. Size the plan to the work: a small change is one task, and what can't be \
    built and checked apart stays one task.
       - With a plan already: refine it with what the person said last, using \
    update_task, remove_tasks and add_tasks. Keep what still fits; the person may have \
    edited tasks.
    7. Check it: call get_plan and read it as the agent who'll build it. Every task \
    meets the task standard below and is given to the agent whose work it is, with the \
    model it needs; together they do everything asked and nothing more, and their \
    order works. Fix what doesn't.

    #{String.trim(task_standard(agents))}

    End with a short reply to the person, 2 to 4 sentences: what you found in the \
    project, how you'd do it and why, and anything they should decide. Don't list the \
    tasks: Factory shows them.

    Only if the factory tools aren't available, reply instead with only this JSON \
    object, with no tasks when you wouldn't do it and the reply saying why:
    {"clear": true | false, "reply": "<2 to 6 sentences>", "questions": [{"question": "<question>", "options": ["<option>"]}], "tasks": [#{@task_json}]}
    """
  end

  defp instructions(:scope, agents) do
    """
    The person pressed Scope: before anything is built, check the scope of work. Does \
    this plan do everything they asked, only what they asked, and can each task be built \
    without guessing? This is a review: the plan tools only read the plan this turn. \
    Don't try to change it, and don't call ask_user: questions for the person go in your \
    report.

    Work through it in this order, and don't skip reading the code:
    1. Pin down the ask. From the requests and the spec files, list for yourself each \
    thing that must be true when this is done, including what the person clearly \
    expects but didn't spell out. Where they conflict, the latest request wins.
    2. Read the code. For every task, open the files and functions it names: check they \
    exist, the names are right, and the change fits how the code works today. Find \
    what depends on that code (callers, templates, routes, jobs, migrations, config) \
    and the tests that cover it.
    3. Trace. Match each expectation to the tasks that deliver it. An expectation with \
    no task is missing; a task or step that serves no expectation is beyond scope.
    4. Judge each task against the task standard below: does it say what's true when \
    it's done, how to build it (the files and steps), and how another model can check \
    it (runnable checks)? Is it one change that can be built and tested alone? Is it \
    in build order, with nothing used before the task that makes it?
    5. Look for what breaks: behaviour that changes for existing users or callers, data \
    to migrate, tests that will fail, permissions and security, errors and empty states.

    Then reply with this report, leaving out any section with nothing in it. Back each \
    point with evidence, `path/to/file.ex:line` or the task number. Say so when you \
    couldn't confirm something in the code rather than guessing.

    **Verdict:** Ready to build, Ready after small fixes, or Needs rework, and in one \
    sentence why.
    **Covered:** each expectation and the task numbers that deliver it.
    **Missing:** what the request needs that no task does, and where it belongs: which \
    task, or a new task after which one.
    **Beyond scope:** tasks or steps that go further than asked, and whether to drop them.
    **Wrong or unclear:** names that don't match the code, wrong assumptions about how \
    it works, and tasks an agent couldn't build without guessing.
    **Size and order:** tasks to split or merge, and tasks in the wrong order.
    **Risks:** what could break, and the decisions the person should make, as questions.
    **First changes:** the two or three changes to make first, most important first.

    A line or two per point. Factory shows this report above the plan, and the person's \
    Refine button acts on it.

    #{String.trim(task_standard(agents))}
    """
  end

  defp instructions(:refine, agents) do
    """
    The person pressed Refine: rework the plan below so that it does everything they \
    asked and nothing more, and so that an agent can build every task without guessing. \
    The plan exists: change it only with update_task, remove_tasks and add_tasks. Never \
    call create_plan, which would throw away the person's edits.

    First investigate, without touching the plan:
    1. From the requests and the spec files, list for yourself what must be true when \
    this is done. Where they conflict, the latest request wins.
    2. Read the code each task touches. Check every file, module and function it names \
    exists and is spelled right, and find the real ones where it's wrong. Find the tests \
    that cover that code and how they're written, and what depends on it (callers, \
    templates, routes, jobs, migrations, config).
    3. If there's a scope check below, go through it point by point and confirm each one \
    in the code before acting on it. Skip a point that turns out to be wrong, and say so.
    4. Decide the changes: tasks to fix, split, merge, reorder, drop or add.

    Then change the plan, as little as it takes:
    - Every task ends up meeting the task standard below: its objective, the approach \
    as steps, its checks, the agent that builds it and its model. Fill in what an older \
    task is missing without changing what it does.
    - One change per task, buildable and testable on its own, in build order. Tests go in \
    the task that needs them or the one right after.
    - Leave good tasks as they are. The person may have written or edited tasks: keep \
    their wording and intent, and only add what's missing. Don't add work nobody asked for.
    - If only the person can decide something the plan depends on, call ask_user rather \
    than guess.

    Last, call get_plan and check the result against what you set out to change: every \
    task concrete, nothing missing, nothing beyond scope. Fix what isn't.

    End with a short reply to the person, 2 to 4 sentences: what you changed and why, \
    and what you left for them to decide. Don't list the tasks: Factory shows them.

    #{String.trim(task_standard(agents))}

    Only if the factory tools aren't available, reply instead with only this JSON object, \
    holding the whole reworked plan:
    {"clear": true, "reply": "<2 to 4 sentences>", "questions": [], "tasks": [#{@task_json}]}
    """
  end

  defp thin_text(%{thin: [_ | _] = thin}) do
    """

    Factory's own check found these tasks thin (it looks for steps, named code, a way to \
    check the task is done, and a clear title):
    #{Enum.map_join(thin, "\n", &"- #{&1}")}
    """
  end

  defp thin_text(_action), do: ""

  defp findings_text(%{findings: findings}) when is_binary(findings) do
    """

    <scope-check>
    Your scope check of this plan, from earlier in this chat:

    #{String.trim(findings)}
    </scope-check>
    """
  end

  defp findings_text(_action), do: ""

  @doc """
  Reads a chat plan: `{:ok, %{reply:, tasks:, questions:}}`. When the planner found the
  request unclear, there are questions and no tasks.
  """
  def parse_chat_plan(reply) do
    with {:ok, data} <- decode(reply) do
      questions =
        for q <- List.wrap(data["questions"]),
            text = if(is_map(q), do: Text.text(q["question"]), else: Text.text(q)),
            text != "" do
          options =
            if is_map(q), do: q["options"] |> List.wrap() |> Enum.filter(&is_binary/1), else: []

          %{"question" => text, "options" => Enum.take(options, 4)}
        end

      tasks = tasks(data["tasks"])

      # Unclear means questions first, whatever tasks came with them.
      unclear = data["clear"] == false and questions != []
      tasks = if unclear, do: [], else: Enum.take(tasks, 30)

      {:ok, %{reply: Text.text(data["reply"]), tasks: tasks, questions: Enum.take(questions, 5)}}
    end
  end

  defp json_shape do
    """
    Reply with only this JSON object and nothing else:
    #{String.trim_trailing(@task_json, "}")}, "why": "<one sentence: how you scoped it>"}\
    """
  end

  @doc """
  Reads an improved or new task: `{:ok, %{title:, objective:, details:, verify:, model:,
  requirements:, why:}}`.
  """
  def parse_improvement(reply) do
    with {:ok, data} <- decode(reply) do
      case task(data) do
        nil ->
          {:error, "Kiro didn't suggest a task."}

        t ->
          {:ok,
           %{
             title: t["title"],
             objective: if(t["objective"] == "", do: nil, else: t["objective"]),
             details: t["details"],
             verify: t["verify"],
             agent: t["agent"],
             model: t["model"],
             requirements: t["requirements"],
             why: Text.text(data["why"])
           }}
      end
    end
  end

  defp spec_text(files) do
    Enum.map_join(files, "\n\n", fn {name, text} ->
      ~s(<file name="#{name}">\n#{text}\n</file>)
    end)
  end

  @doc "Reads turn 1's reply: `{:ok, %{\"project\" => …, \"questions\" => […]}}`."
  def parse_questions(reply) do
    with {:ok, data} <- decode(reply) do
      questions =
        for %{"question" => q} = item <- List.wrap(data["questions"]),
            is_binary(q),
            options = item["options"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.take(4),
            length(options) >= 2 do
          %{"question" => String.trim(q), "why" => Text.text(item["why"]), "options" => options}
        end

      {:ok, %{"project" => Text.text(data["project"]), "questions" => Enum.take(questions, 6)}}
    end
  end

  @doc "Reads turn 2's reply: `{:ok, [%{\"title\" => …, …}]}`, never empty."
  def parse_tasks(reply) do
    with {:ok, data} <- decode(reply) do
      # Suggestions keep their size, for the list to pick from.
      tasks =
        for raw <- List.wrap(data["tasks"]), t = task(raw), t != nil do
          Map.put(t, "size", if(raw["size"] in ~w(S M L), do: raw["size"]))
        end

      case tasks do
        [] -> {:error, "Kiro didn't suggest any tasks."}
        tasks -> {:ok, Enum.take(tasks, 30)}
      end
    end
  end

  @doc """
  The chosen tasks as Kiro's tasks.md checklist, numbered from `first`:

      - [ ] 3. Add the reset form
        - Details of the task
        - _Requirements: 1.1, 1.2_
  """
  def to_markdown(tasks, first) do
    tasks
    |> unique_titles()
    |> Enum.with_index(first)
    |> Enum.map_join("\n\n", fn {task, n} ->
      {_, [block]} = Factory.Spec.blocks("- [ ] #{n}. #{task["title"]}")

      block
      |> Factory.Spec.edit_block(%{
        title: task["title"],
        objective: task["objective"],
        details: clean(task["details"]),
        verify: clean(task["verify"]),
        agent: task["agent"],
        model: task["model"],
        requirements: clean(task["requirements"])
      })
      |> Map.fetch!(:lines)
      |> Enum.join("\n")
    end)
  end

  defp clean(list), do: list |> List.wrap() |> Enum.reject(&(String.trim(&1) == ""))

  @doc "A short line for what Kiro is doing, from an ACP tool_call update."
  def describe_tool(update, workdir) do
    path =
      case update do
        %{"locations" => [%{"path" => path} | _]} -> Path.relative_to(path, workdir)
        _ -> nil
      end

    describe_plan_tool(update["title"], update["rawInput"]) ||
      describe_file_tool(update["kind"], path, update)
  end

  # Factory's own tools (`Factory.PlanTools`), as Kiro titles them: "@factory/add_tasks".
  defp describe_plan_tool("@factory/" <> tool, input) do
    input = if is_map(input), do: input, else: %{}

    case {tool, List.wrap(input["tasks"])} do
      {"create_plan", _} -> "Writing the plan"
      {"add_tasks", [%{"title" => title}]} when is_binary(title) -> "Adding “#{title}”"
      {"add_tasks", tasks} -> "Adding #{length(tasks)} tasks"
      {"update_task", _} -> "Changing task #{input["number"]}"
      {"remove_tasks", _} -> "Removing tasks"
      {"get_plan", _} -> "Checking the plan"
      {"ask_user", _} -> "Writing questions"
      _ -> nil
    end
  end

  defp describe_plan_tool(_title, _input), do: nil

  defp describe_file_tool(kind, path, update) do
    case {kind, path, update["title"]} do
      {"read", path, _} when is_binary(path) ->
        "Reading #{path}"

      {"search", path, _} when is_binary(path) ->
        "Searching #{path}"

      {_, _, title} when title in ["web_search", "Web Search"] ->
        "Searching the web"

      {"fetch", _, _} ->
        "Reading a web page"

      {_, _, title} when title in ["web_fetch", "Fetch"] ->
        "Reading a web page"

      {_, _, title} when is_binary(title) ->
        title |> String.replace("_", " ") |> String.capitalize()

      _ ->
        "Looking around"
    end
  end

  defp decode(reply) do
    case Text.decode_json(reply) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, "Kiro's reply wasn't something Factory could read."}
    end
  end
end
