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

  @doc """
  Prompt for planning a whole factory run in one turn: from the overview (what the
  person asked for) Kiro writes the requirements, the design and the tasks. When
  asked to (`pick_workflow`, `pick_model`), it also chooses the agents and the model.
  """
  def run_prompt(type, files, opts) do
    roles =
      Enum.map_join(opts[:roles], "\n", fn r -> "- #{r["kind"]}: #{r["name"]}, #{r["does"]}" end)

    workflow =
      Enum.map_join(opts[:workflow], " → ", & &1["name"])

    choose =
      [
        opts[:pick_workflow] &&
          ~s|Choose the workflow: the agents that should do this job, in order, from these roles \
(rename them to fit the job):\n#{roles}\nPut it in "workflow" as [{"kind", "name", "does"}].|,
        opts[:pick_model] &&
          ~s(Choose the model for the agents from: #{Enum.join(opts[:models], ", ")}. \
Pick "auto" unless the job clearly needs a stronger or cheaper one. Put it in "model".)
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n\n")

    """
    <task-planning step="run">
    You are planning a job for a software factory: "#{type.label}". The person described it \
    in the overview below; the project is in the current folder. Look at the project first: \
    read the files you need to understand its stack, structure, conventions and the code this \
    job touches. Don't change anything and don't run commands.

    Then write the plan as the rest of the spec:
    - "requirements": markdown. What must be true when the job is done, as numbered \
    requirements with WHEN/THEN acceptance criteria (for a bug: the expected behaviour).
    - "design": markdown. How it will be done: the parts of the code that change, the \
    approach, risks and how it will be tested (for a bug: the likely cause and the fix).
    - "tasks": small implementation tasks in build order, each buildable and testable on \
    its own, naming the files it touches and the requirement numbers it covers. Include \
    tests. #{if type.id == "feature", do: "About 8 to 20 tasks.", else: "Usually 3 to 10 tasks."}

    The agents that will do the work: #{workflow}.

    #{choose}

    Reply with only this JSON object and nothing else:
    {"requirements": "<markdown>", "design": "<markdown>", "tasks": [{"title": "<imperative, under 80 characters>", "details": ["<step or note>"], "requirements": ["<number>"]}], #{if opts[:pick_workflow], do: ~s("workflow": [{"kind": "<role>", "name": "<name>", "does": "<one line>"}], ), else: ""}#{if opts[:pick_model], do: ~s("model": "<model>", ), else: ""}"why": "<one or two sentences: what you found in the project and how you approached the plan>"}
    </task-planning>

    #{spec_text(files)}
    """
  end

  @doc """
  Reads a run plan: `{:ok, %{requirements:, design:, tasks: [task], workflow: [step] | nil,
  model: string | nil, why:}}`. Tasks are in `to_markdown/2`'s shape. Workflow steps
  and the model are kept only if they're ones Factory knows (`kinds`, `models`).
  """
  def parse_run_plan(reply, kinds, models) do
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

      workflow =
        for %{"kind" => kind, "name" => name} = step <- List.wrap(data["workflow"]),
            kind in kinds,
            is_binary(name) and String.trim(name) != "" do
          %{"kind" => kind, "name" => String.trim(name), "does" => text(step["does"])}
        end

      cond do
        tasks == [] ->
          {:error, "Kiro's plan had no tasks."}

        true ->
          {:ok,
           %{
             requirements: text(data["requirements"]),
             design: text(data["design"]),
             tasks: Enum.take(tasks, 30),
             workflow: if(workflow == [], do: nil, else: Enum.take(workflow, 8)),
             model: if(data["model"] in models, do: data["model"]),
             why: text(data["why"])
           }}
      end
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
