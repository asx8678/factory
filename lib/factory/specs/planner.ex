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

  @doc "Prompt for turn 1: read the project, then ask questions."
  def questions_prompt(files) do
    """
    <task-planning step="questions">
    You are planning how to build the spec below in the project in the current folder.

    First look at the project: read the files you need to understand its structure, stack, \
    conventions and the code this feature touches. Don't change anything and don't run commands.

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
  def tasks_prompt(files, project, answers) do
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
    You may read files again to check details. Don't change anything and don't run commands.

    What you found about the project:
    #{project}

    Questions and answers:
    #{qa}

    Suggest about 20 implementation tasks in build order. Each task is one small change \
    that can be built and tested on its own, names the files or modules it touches, and \
    traces back to the requirements it covers. Include tasks for tests. Don't repeat tasks \
    the spec's tasks file already has.

    Reply with only this JSON object and nothing else:
    {"tasks": [{"title": "<imperative, under 80 characters>", "details": "<1 or 2 sentences: what to change and where>", "requirements": ["<requirement number, e.g. 1.2>"], "size": "S" | "M" | "L"}]}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc """
  Prompt for improving one task: Kiro may read the project, then rewrites the task
  following the person's instruction (or its own judgement when there is none).
  """
  def improve_prompt(files, task, instruction) do
    ask =
      case String.trim(instruction) do
        "" -> "Make it clearer, more specific and easier to build and test on its own."
        text -> text
      end

    current =
      Enum.join(
        ["Title: #{task.title}"] ++
          Enum.map(task.details, &"- #{&1}") ++
          if(task.requirements == [],
            do: [],
            else: ["Requirements: #{Enum.join(task.requirements, ", ")}"]
          ),
        "\n"
      )

    """
    <task-planning step="improve">
    You are improving one implementation task of the spec below, for the project in the \
    current folder. You may read files to check names, paths and conventions. \
    Don't change anything and don't run commands.

    The task now:
    #{current}

    What the person wants done better:
    #{ask}

    Keep the task one small change that can be built and tested on its own. Name the \
    files or modules it touches. Keep requirement numbers that still apply. Wrap code, \
    paths and commands in `backticks`.

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
  def draft_prompt(files, title, notes) do
    idea =
      [String.trim(title), String.trim(notes)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    """
    <task-planning step="draft">
    You are adding one new implementation task to the spec below, for the project in the \
    current folder. Scope it quickly: read only the few files this task touches (about 5 at \
    most) to get names, paths and conventions right. Don't change anything and don't run commands.

    The person's rough idea for the task:
    #{idea}

    Write it as one small change that can be built and tested on its own. Name the files \
    or modules it touches and say how to check it works. Use the spec's requirement \
    numbers it covers. Don't repeat what the spec's existing tasks already do. Wrap code, \
    paths and commands in `backticks`.

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
     ~s|- "tasks": small implementation tasks in build order, each buildable and testable on \
its own, naming the files it touches and the requirement numbers it covers. Include tests.|,
     ~s|"tasks": [{"title": "<imperative, under 80 characters>", "details": ["<step or note>"], "requirements": ["<number>"]}]|}
  ]

  @doc """
  Prompt for planning a factory run in one turn: Kiro reads the project and writes the
  parts of the spec that are missing (`write:`, some of "requirements", "design" and
  "tasks"), keeping to the parts the person gave. `agents:` names the agents that will
  do the work, in order.
  """
  def run_prompt(type, files, opts) do
    write = Keyword.fetch!(opts, :write)
    given = for {part, _, _} <- @run_parts, part not in write, do: part

    keep =
      if given != [],
        do:
          "The spec already has its #{Enum.join(given, " and ")}: keep to them and don't rewrite them.",
        else: ""

    size =
      if "tasks" in write,
        do: if(type.id == "feature", do: "About 8 to 20 tasks.", else: "Usually 3 to 10 tasks."),
        else: ""

    asked = for {part, what, _} <- @run_parts, part in write, do: what
    json = for {part, _, shape} <- @run_parts, part in write, do: shape

    """
    <task-planning step="run">
    You are planning a job for a software factory: "#{type.label}". The spec files below \
    say what the person wants; the project is in the current folder. Look at the project \
    first: read the files you need to understand its stack, structure, conventions and the \
    code this job touches. Don't change anything and don't run commands.

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
      tasks =
        for %{"title" => title} = t <- List.wrap(data["tasks"]),
            is_binary(title) and String.trim(title) != "" do
          %{
            "title" => title |> String.trim() |> String.slice(0, 200),
            "details" =>
              t["details"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1),
            "requirements" =>
              t["requirements"] |> List.wrap() |> Enum.map(&to_string/1) |> Enum.take(8)
          }
        end

      plan = %{
        requirements: text(data["requirements"]),
        design: text(data["design"]),
        tasks: Enum.take(tasks, 30),
        why: text(data["why"])
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
  Prompt for planning in a chat: the planner reads the project, rethinks how the
  person's requests (oldest first) are best done, and turns them into tasks, refining
  `current` (the tasks so far, markdown) rather than starting over.
  """
  def chat_prompt(name, requests, files, current) do
    asked = requests |> Enum.with_index(1) |> Enum.map_join("\n\n", fn {r, i} -> "#{i}. #{r}" end)

    current =
      if String.trim(current || "") == "",
        do: "None yet.",
        else: current

    """
    <task-planning step="chat">
    You are #{name}, the planner in a software factory. The person is chatting with you \
    about a change to the project in the current folder. Look at the project first: read \
    the files you need to understand its stack, conventions and the code this touches. \
    Don't change anything and don't run commands.

    Then decide whether the request is clear enough to plan without guessing: you know \
    what should be built, where it goes in the code, and how to tell it works.

    - If it isn't clear, don't write any tasks. Set "clear" to false, say in "reply" what \
    is missing, and ask 1 to 5 short, specific questions in "questions" (with 2 to 4 \
    options where that helps). Keep the tasks so far as they are.
    - If it is clear, set "clear" to true, rethink how it is best done, and write it as \
    small implementation tasks in build order, each buildable and testable on its own, \
    naming the files it touches. Include tests. Refine the tasks so far with what the \
    person said last: keep what still fits, change what doesn't.

    The tasks so far:
    #{current}

    Reply with only this JSON object and nothing else:
    {"clear": true | false, "reply": "<2 to 4 sentences: how you'd do it and why, or what is missing>", "questions": [{"question": "<question>", "options": ["<option>"]}], "tasks": [{"title": "<imperative, under 80 characters>", "details": ["<step or note>"]}]}
    </task-planning>

    <requests>
    #{asked}
    </requests>

    #{spec_text(files)}
    """
  end

  @doc """
  Reads a chat plan: `{:ok, %{reply:, tasks:, questions:}}`. When the planner found the
  request unclear, there are questions and no tasks.
  """
  def parse_chat_plan(reply) do
    with {:ok, data} <- decode(reply) do
      questions =
        for q <- List.wrap(data["questions"]),
            text = if(is_map(q), do: text(q["question"]), else: text(q)),
            text != "" do
          options =
            if is_map(q), do: q["options"] |> List.wrap() |> Enum.filter(&is_binary/1), else: []

          %{"question" => text, "options" => Enum.take(options, 4)}
        end

      tasks =
        for %{"title" => title} = t <- List.wrap(data["tasks"]),
            is_binary(title) and String.trim(title) != "" do
          %{
            "title" => title |> String.trim() |> String.slice(0, 200),
            "details" =>
              t["details"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1),
            "requirements" => []
          }
        end

      # Unclear means questions first, whatever tasks came with them.
      unclear = data["clear"] == false and questions != []
      tasks = if unclear, do: [], else: Enum.take(tasks, 30)

      {:ok, %{reply: text(data["reply"]), tasks: tasks, questions: Enum.take(questions, 5)}}
    end
  end

  defp json_shape do
    """
    Reply with only this JSON object and nothing else:
    {"title": "<imperative, under 80 characters>", "details": ["<one step or note per item, 1 to 6 items>"], "requirements": ["<requirement number>"], "why": "<one sentence: how you scoped it>"}\
    """
  end

  @doc "Reads an improved or new task: `{:ok, %{title:, details:, requirements:, why:}}`."
  def parse_improvement(reply) do
    with {:ok, data} <- decode(reply) do
      title = text(data["title"])

      details =
        data["details"]
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.flat_map(&String.split(&1, ~r/\R/u))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      if title == "" do
        {:error, "Kiro didn't suggest a task."}
      else
        {:ok,
         %{
           title: String.slice(title, 0, 200),
           details: Enum.take(details, 12),
           requirements:
             data["requirements"] |> List.wrap() |> Enum.map(&to_string/1) |> Enum.take(8),
           why: text(data["why"])
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
          %{"question" => String.trim(q), "why" => text(item["why"]), "options" => options}
        end

      {:ok, %{"project" => text(data["project"]), "questions" => Enum.take(questions, 6)}}
    end
  end

  @doc "Reads turn 2's reply: `{:ok, [%{\"title\" => …, …}]}`, never empty."
  def parse_tasks(reply) do
    with {:ok, data} <- decode(reply) do
      tasks =
        for %{"title" => title} = t <- List.wrap(data["tasks"]),
            is_binary(title) and String.trim(title) != "" do
          %{
            "title" => title |> String.trim() |> String.slice(0, 200),
            "details" => text(t["details"]),
            "requirements" =>
              t["requirements"] |> List.wrap() |> Enum.map(&to_string/1) |> Enum.take(8),
            "size" => if(t["size"] in ~w(S M L), do: t["size"])
          }
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
    |> Enum.with_index(first)
    |> Enum.map_join("\n\n", fn {task, n} ->
      details = task["details"] |> List.wrap() |> Enum.reject(&(String.trim(&1) == ""))
      lines = ["- [ ] #{n}. #{task["title"]}" | Enum.map(details, &"  - #{&1}")]

      lines =
        if task["requirements"] != [],
          do: lines ++ ["  - _Requirements: #{Enum.join(task["requirements"], ", ")}_"],
          else: lines

      Enum.join(lines, "\n")
    end)
  end

  @doc "A short line for what Kiro is doing, from an ACP tool_call update."
  def describe_tool(update, workdir) do
    path =
      case update do
        %{"locations" => [%{"path" => path} | _]} -> Path.relative_to(path, workdir)
        _ -> nil
      end

    case {update["kind"], path} do
      {"read", path} when is_binary(path) -> "Reading #{path}"
      {"search", path} when is_binary(path) -> "Searching #{path}"
      _ -> update["title"] || "Looking around"
    end
  end

  defp decode(reply) do
    with [json] <- Regex.run(~r/\{.*\}/s, reply),
         {:ok, data} when is_map(data) <- JSON.decode(json) do
      {:ok, data}
    else
      _ -> {:error, "Kiro's reply wasn't something Factory could read."}
    end
  end

  defp text(s) when is_binary(s), do: String.trim(s)
  defp text(_), do: ""
end
