defmodule Factory.Specs do
  @moduledoc """
  Specs for spec-driven development: an overview (the main spec file), then
  requirements, design and tasks, each approved by a person before the next step opens. An approved spec starts runs.
  """
  import Ecto.Query
  alias Factory.{Repo, Runs, Spec}
  alias Factory.Specs.{Planner, Review}
  alias Factory.Specs.Spec, as: SpecDoc

  @doc "Subscribes to `{:specs_changed}` for the list."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, "specs")

  @doc "Subscribes to `{:spec_updated, spec}` for one spec."
  def subscribe(id), do: Phoenix.PubSub.subscribe(Factory.PubSub, "spec:#{id}")

  def list_specs do
    Repo.all(
      from s in SpecDoc,
        order_by: [desc: s.updated_at, desc: s.id],
        preload: [runs: :tasks]
    )
  end

  def get_spec(id), do: SpecDoc |> Repo.get(id) |> preload()

  def create_spec(name, attrs \\ %{}) do
    %SpecDoc{}
    |> SpecDoc.changeset(Map.put(attrs, :name, name))
    |> Repo.insert()
    |> preloaded()
  end

  @doc """
  Creates a spec from files (`[{name, content}]`). Each goes into the step its name
  says (requirements.md, design.md, tasks.md); any other file is the main spec and
  goes into the overview.
  Without a name, the spec is named after the first heading or file.
  """
  def create_from_files(name, files) do
    steps =
      files
      |> Enum.group_by(fn {file, _} -> step_for(file) end, &elem(&1, 1))
      |> Map.new(fn {step, texts} ->
        {String.to_existing_atom(step), Enum.join(texts, "\n\n")}
      end)

    name = if String.trim(name || "") == "", do: name_from(files), else: name
    create_spec(name, steps)
  end

  @doc "The step a file goes into, by its name. A typed description is the overview."
  def step_for(:description), do: "overview"

  def step_for(file) do
    base = file |> Path.basename() |> String.downcase()

    cond do
      base =~ "design" -> "design"
      base =~ "task" -> "tasks"
      base =~ "requirement" -> "requirements"
      true -> "overview"
    end
  end

  # The first heading in any file; otherwise the first file's name, or the first
  # line of a typed description.
  defp name_from([first | _] = files) do
    Enum.find_value(files, fallback_name(first), fn {_, text} ->
      case Regex.run(~r/^#\s+(.+)$/m, text) do
        [_, heading] -> heading |> String.trim() |> String.slice(0, 80)
        _ -> nil
      end
    end)
  end

  defp fallback_name({:description, text}) do
    line = text |> String.split(~r/\R/u, trim: true) |> List.first("") |> String.trim()
    if String.length(line) > 60, do: String.slice(line, 0, 57) <> "…", else: line
  end

  defp fallback_name({file, _}), do: Path.rootname(Path.basename(file))

  def change_spec(spec, attrs \\ %{}), do: SpecDoc.changeset(spec, attrs)

  def update_spec(%SpecDoc{} = spec, attrs) do
    spec |> SpecDoc.changeset(attrs) |> Repo.update() |> preloaded()
  end

  def delete_spec(%SpecDoc{} = spec) do
    with {:ok, spec} <- Repo.delete(spec) do
      broadcast("specs", {:specs_changed})
      {:ok, spec}
    end
  end

  @doc """
  Asks Kiro (v3, auto model) to review and score the spec, in the background.
  Subscribers to the spec get `{:spec_updated, spec}` when it starts and when it's done.
  """
  def review(%SpecDoc{} = spec) do
    files = files(spec)

    cond do
      files == [] ->
        {:error, :empty}

      spec.review["status"] == "running" ->
        {:error, :running}

      true ->
        {:ok, spec} = set_review(spec, %{"status" => "running"})

        Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
          review =
            with {:ok, reply} <-
                   Factory.Kiro.ask(Review.prompt(files),
                     usage: %{source: "review", spec_id: spec.id}
                   ),
                 {:ok, review} <- Review.parse(reply) do
              Map.merge(review, %{"status" => "done", "hash" => hash(spec)})
            else
              {:error, reason} -> %{"status" => "error", "error" => reason}
            end

          if spec = get_spec(spec.id), do: set_review(spec, review)
        end)

        {:ok, spec}
    end
  end

  @doc "Whether the spec was changed after its review."
  def changed_since_review?(%SpecDoc{review: %{"hash" => hash}} = spec), do: hash != hash(spec)
  def changed_since_review?(_spec), do: false

  defp hash(spec), do: spec |> files() |> :erlang.phash2()

  defp set_review(spec, review) do
    review = Map.put(review, "at", DateTime.utc_now(:second) |> DateTime.to_iso8601())
    spec |> Ecto.Changeset.change(review: review) |> Repo.update() |> preloaded()
  end

  @doc "Reviews and task suggestions can't survive a restart: mark running ones as stopped."
  def reset_reviews do
    stopped = %{"status" => "error", "error" => "Stopped when Factory restarted."}

    Repo.update_all(
      from(s in SpecDoc, where: fragment("?->>'status' = 'running'", s.review)),
      set: [review: stopped]
    )

    Repo.update_all(
      from(s in SpecDoc, where: fragment("?->>'status' in ('reading', 'writing')", s.plan)),
      set: [plan: stopped]
    )
  end

  # Suggesting tasks: Kiro reads the project, asks questions, then suggests tasks.
  # Progress is kept in the spec's `plan`; what Kiro is reading right now is only
  # broadcast, as `{:plan_activity, text}`.

  @doc "The folder Kiro reads when suggesting tasks: the spec's, or the Kiro workspace."
  def project_dir(%SpecDoc{project_dir: dir}) when is_binary(dir) and dir != "", do: dir
  def project_dir(_spec), do: Factory.Kiro.config(:workspace)

  @doc "Step 1: Kiro reads the project in `dir` and asks questions, in the background."
  def plan_questions(%SpecDoc{} = spec, dir) do
    dir = dir |> to_string() |> String.trim() |> Path.expand()

    cond do
      planning?(spec) ->
        {:error, :running}

      not File.dir?(dir) ->
        {:error, :no_folder}

      true ->
        {:ok, spec} =
          spec
          |> Ecto.Changeset.change(project_dir: dir, plan: %{"status" => "reading"})
          |> Repo.update()
          |> preloaded()

        prompt = Planner.questions_prompt(kiro_files(spec))

        run_plan(
          spec,
          "plan_questions",
          prompt,
          &Planner.parse_questions/1,
          %{"failed" => "reading"},
          fn result ->
            Map.merge(result, %{"status" => "questions"})
          end
        )

        {:ok, spec}
    end
  end

  @doc "Step 2: with the answers (`[%{\"question\", \"answer\"}]`), Kiro suggests tasks."
  def plan_tasks(%SpecDoc{} = spec, answers) do
    if planning?(spec) do
      {:error, :running}
    else
      plan = Map.merge(spec.plan, %{"status" => "writing", "answers" => answers})
      {:ok, spec} = set_plan(spec, plan)
      prompt = Planner.tasks_prompt(kiro_files(spec), plan["project"] || "", answers)

      failed = Map.put(plan, "failed", "writing")

      run_plan(spec, "plan_tasks", prompt, &Planner.parse_tasks/1, failed, fn tasks ->
        Map.merge(plan, %{"status" => "tasks", "tasks" => tasks})
      end)

      {:ok, spec}
    end
  end

  @doc "Forgets the suggestions, to start over."
  def reset_plan(%SpecDoc{} = spec), do: set_plan(spec, %{})

  @doc """
  Adds chosen tasks to the spec's tasks step, after the tasks already there or
  instead of them (`:replace`). Numbering continues from the last task.
  """
  def add_tasks(%SpecDoc{} = spec, tasks, mode \\ :append) do
    existing = if mode == :replace, do: "", else: String.trim_trailing(spec.tasks || "")

    first =
      existing
      |> Spec.parse_tasks()
      |> Enum.map(&((&1.ref || "0") |> String.split(".") |> hd() |> String.to_integer()))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    added = Planner.to_markdown(tasks, first)
    text = if existing == "", do: added <> "\n", else: existing <> "\n\n" <> added <> "\n"
    update_spec(spec, %{tasks: text})
  end

  defp planning?(spec), do: spec.plan["status"] in ["reading", "writing"]

  # Runs one turn in the background. On failure the plan keeps what it had (so the
  # answers survive) and "failed" says which step to try again.
  defp run_plan(spec, source, prompt, parse, base, done) do
    dir = spec.project_dir
    topic = "spec:#{spec.id}"

    on_tool = fn update ->
      broadcast(topic, {:plan_activity, Planner.describe_tool(update, dir)})
    end

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      plan =
        with {:ok, reply} <-
               Factory.Kiro.ask(prompt,
                 workdir: dir,
                 allow: ["read", "search"],
                 on_tool: on_tool,
                 usage: %{source: source, spec_id: spec.id}
               ),
             {:ok, result} <- parse.(reply) do
          done.(result)
        else
          {:error, reason} -> Map.merge(base, %{"status" => "error", "error" => reason})
        end

      if spec = get_spec(spec.id), do: set_plan(spec, plan)
    end)
  end

  defp set_plan(spec, plan) do
    spec |> Ecto.Changeset.change(plan: plan) |> Repo.update() |> preloaded()
  end

  defp broadcast(topic, msg), do: Phoenix.PubSub.broadcast(Factory.PubSub, topic, msg)

  @doc """
  Approves a step. Only an open step with text in it can be approved, except the
  overview, which can be left empty (skipped).
  """
  def approve(%SpecDoc{} = spec, step) do
    cond do
      not SpecDoc.open?(spec, step) ->
        {:error, :locked}

      step != "overview" and String.trim(Map.fetch!(spec, String.to_existing_atom(step))) == "" ->
        {:error, :empty}

      step == "tasks" and tasks(spec) == [] ->
        {:error, :no_tasks}

      true ->
        set_approvals(spec, [{step, DateTime.utc_now(:second)}])
    end
  end

  @doc "Opens an approved step for editing again, which also reopens every step after it."
  def reopen(%SpecDoc{} = spec, step) do
    later = Enum.drop_while(SpecDoc.steps(), &(&1 != step))
    set_approvals(spec, Enum.map(later, &{&1, nil}))
  end

  defp set_approvals(spec, approvals) do
    changes = Map.new(approvals, fn {step, at} -> {SpecDoc.approved_field(step), at} end)
    spec |> Ecto.Changeset.change(changes) |> Repo.update() |> preloaded()
  end

  @doc "The tasks in the spec's tasks step."
  def tasks(%SpecDoc{tasks: text}), do: Spec.parse_tasks(text || "")

  @doc """
  What Kiro reads about a spec: its files, plus the data sources of the workflow its
  run uses (see `Factory.Sources`), as `data-sources.md`.
  """
  def kiro_files(%SpecDoc{} = spec) do
    workflow_id =
      case home_run(spec) do
        %{settings: %{"workflow_id" => id}} -> id
        _ -> nil
      end

    case Factory.Sources.context(workflow_id) do
      "" -> files(spec)
      text -> files(spec) ++ [{"data-sources.md", text}]
    end
  end

  @doc "The spec as Kiro's three files, skipping empty ones."
  def files(%SpecDoc{} = spec) do
    for step <- SpecDoc.steps(),
        text = Map.fetch!(spec, String.to_existing_atom(step)),
        String.trim(text) != "",
        do: {step <> ".md", text}
  end

  @doc "The factory run this spec was written for, if it was (see Factory.Launch)."
  def home_run(%SpecDoc{id: id}) do
    Repo.one(
      from r in Factory.Runs.Run,
        where: r.spec_id == ^id and not is_nil(r.kind),
        order_by: r.id,
        limit: 1,
        preload: :tasks
    )
  end

  @doc "Sets the folder Kiro reads for this spec's project."
  def set_project_dir(%SpecDoc{} = spec, dir) do
    spec |> Ecto.Changeset.change(project_dir: dir) |> Repo.update() |> preloaded()
  end

  @doc """
  Starts a new run from an approved spec: a chat with the spec attached. With a
  queue, the run gets only the queued tasks, in queue order, and the queue empties.
  """
  def start_run(%SpecDoc{} = spec) do
    if SpecDoc.current_step(spec) == "ready" do
      files =
        case queued(spec) do
          [] ->
            files(spec)

          blocks ->
            {preamble, _} = Spec.blocks(spec.tasks)

            Enum.map(files(spec), fn
              {"tasks.md", _} -> {"tasks.md", Spec.render_blocks(preamble, blocks)}
              file -> file
            end)
        end

      # A factory run made for this spec (see Factory.Launch) runs it the first time;
      # after that, or for a spec made on its own, each start is a new run.
      home = home_run(spec)

      created =
        if home && home.status == "draft" && home.tasks == [],
          do: {:ok, home},
          else: Runs.create_run(spec.name)

      with {:ok, run} <- created,
           {:ok, run} <- Runs.update_run(run, %{spec_id: spec.id}) do
        Factory.Chat.attach_spec(run, files)
        if spec.queue != [], do: set_queue(spec, [])
        {:ok, run}
      end
    else
      {:error, :not_approved}
    end
  end

  # Managing tasks. The tasks step's text is the source; these rewrite it, so moving
  # and deleting only work while the step is being written. Editing one task, and
  # the queue, work any time once the tasks step is open.

  @doc "The spec's tasks, each with its place in the queue and its status in the latest run."
  def task_list(%SpecDoc{} = spec) do
    {_, blocks} = Spec.blocks(spec.tasks)
    latest = List.first(spec.runs || [])
    run_status = if latest, do: Map.new(latest.tasks, &{&1.title, &1.status}), else: %{}

    for block <- blocks do
      Map.merge(block, %{
        queued: Enum.find_index(spec.queue, &(&1 == block.title)),
        run_status: run_status[block.title]
      })
    end
  end

  @doc "Moves task `index` one place up (-1) or down (1)."
  def move_task(%SpecDoc{} = spec, index, by) when by in [-1, 1] do
    edit_tasks(spec, fn blocks ->
      target = index + by

      if target < 0 or target >= length(blocks),
        do: blocks,
        else:
          blocks
          |> List.replace_at(index, Enum.at(blocks, target))
          |> List.replace_at(target, Enum.at(blocks, index))
    end)
  end

  @doc "Deletes the tasks at `indices` and renumbers the rest."
  def delete_tasks(%SpecDoc{} = spec, indices) do
    with {:ok, spec} <- edit_tasks(spec, &drop_indices(&1, indices)) do
      titles = spec |> task_list() |> Enum.map(& &1.title)
      set_queue(spec, Enum.filter(spec.queue, &(&1 in titles)))
    end
  end

  @doc """
  Asks Kiro, in the background, to improve task `index` as `instruction` says.
  Kiro reads the spec's project folder while it works. Subscribers to the spec get
  `{:task_activity, title, text}` as it reads and then
  `{:task_improved, title, {:ok, suggestion} | {:error, reason}}`, where `title`
  is the task's title when it was asked and a suggestion has `title`, `details`,
  `requirements` and `why`. Nothing changes until the suggestion is applied.
  """
  def improve_task(%SpecDoc{} = spec, index, instruction) do
    case Enum.at(task_list(spec), index) do
      nil ->
        {:error, :not_found}

      task ->
        dir = project_dir(spec)
        topic = "spec:#{spec.id}"
        prompt = Planner.improve_prompt(kiro_files(spec), task, instruction)

        on_tool = fn update ->
          broadcast(topic, {:task_activity, task.title, Planner.describe_tool(update, dir)})
        end

        Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
          result =
            with {:ok, reply} <-
                   Factory.Kiro.ask(prompt,
                     workdir: dir,
                     allow: ["read", "search"],
                     on_tool: on_tool,
                     usage: %{source: "improve_task", spec_id: spec.id}
                   ) do
              Planner.parse_improvement(reply)
            end

          broadcast(topic, {:task_improved, task.title, result})
        end)

        {:ok, task.title}
    end
  end

  @doc """
  Asks Kiro, in the background, to write a new task from a rough `title` and
  `notes`. Kiro takes a quick look at the spec's project folder. Subscribers to the
  spec get `{:draft_activity, ref, text}` as it reads, then
  `{:task_drafted, ref, {:ok, suggestion} | {:error, reason}}` (a suggestion as in
  `improve_task/3`). Nothing is added until `add_task/2`.
  """
  def draft_task(%SpecDoc{} = spec, title, notes, ref) do
    dir = project_dir(spec)
    topic = "spec:#{spec.id}"
    prompt = Planner.draft_prompt(kiro_files(spec), title, notes)

    on_tool = fn update ->
      broadcast(topic, {:draft_activity, ref, Planner.describe_tool(update, dir)})
    end

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      result =
        with {:ok, reply} <-
               Factory.Kiro.ask(prompt,
                 workdir: dir,
                 allow: ["read", "search"],
                 on_tool: on_tool,
                 usage: %{source: "draft_task", spec_id: spec.id}
               ) do
          Planner.parse_improvement(reply)
        end

      broadcast(topic, {:task_drafted, ref, result})
    end)

    :ok
  end

  @doc """
  Adds one task at the end, from a title, details (one per line) and requirements
  (comma separated). Works whenever the tasks step is open, like editing a task.
  """
  def add_task(%SpecDoc{} = spec, %{} = params) do
    title = params |> Map.get("title", "") |> String.trim()

    cond do
      not SpecDoc.open?(spec, "tasks") ->
        {:error, :locked}

      title == "" ->
        {:error, :blank_title}

      true ->
        add_tasks(spec, [
          %{
            "title" => String.replace(title, ~r/\s*\R\s*/u, " "),
            "details" =>
              params |> Map.get("details", "") |> String.split(~r/\R/u) |> clean_lines(),
            "requirements" =>
              params |> Map.get("requirements", "") |> String.split(",") |> clean_lines()
          }
        ])
    end
  end

  @doc """
  Changes task `index`: its title, details (one per line) and requirements
  (comma separated). A renamed task keeps its place in the queue.
  """
  def update_task(%SpecDoc{} = spec, index, %{} = params) do
    title = params |> Map.get("title", "") |> String.trim()
    details = params |> Map.get("details", "") |> String.split(~r/\R/u) |> clean_lines()

    requirements =
      params |> Map.get("requirements", "") |> String.split(",") |> clean_lines()

    old = spec |> task_list() |> Enum.at(index)

    cond do
      old == nil ->
        {:error, :not_found}

      title == "" ->
        {:error, :blank_title}

      true ->
        with {:ok, spec} <-
               rewrite_tasks(spec, fn blocks ->
                 List.update_at(blocks, index, &Spec.edit_block(&1, title, details, requirements))
               end) do
          new_title = spec |> task_list() |> Enum.at(index) |> Map.fetch!(:title)

          if old.title != new_title and old.title in spec.queue,
            do:
              set_queue(spec, Enum.map(spec.queue, &if(&1 == old.title, do: new_title, else: &1))),
            else: {:ok, spec}
        end
    end
  end

  defp clean_lines(lines),
    do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp drop_indices(blocks, indices) do
    for {block, i} <- Enum.with_index(blocks), i not in indices, do: block
  end

  defp edit_tasks(spec, fun) do
    if SpecDoc.approved?(spec, "tasks"), do: {:error, :locked}, else: rewrite_tasks(spec, fun)
  end

  defp rewrite_tasks(spec, fun) do
    if SpecDoc.open?(spec, "tasks") do
      {preamble, blocks} = Spec.blocks(spec.tasks)
      update_spec(spec, %{tasks: Spec.render_blocks(preamble, fun.(blocks))})
    else
      {:error, :locked}
    end
  end

  @doc "Adds tasks (by title) to the end of the queue; ones already queued stay put."
  def queue_tasks(%SpecDoc{} = spec, titles),
    do: set_queue(spec, spec.queue ++ Enum.reject(titles, &(&1 in spec.queue)))

  def unqueue_tasks(%SpecDoc{} = spec, titles),
    do: set_queue(spec, Enum.reject(spec.queue, &(&1 in titles)))

  @doc "Moves a queued task one place earlier (-1) or later (1) in the queue."
  def move_queued(%SpecDoc{} = spec, title, by) when by in [-1, 1] do
    queue = spec.queue

    case Enum.find_index(queue, &(&1 == title)) do
      nil ->
        {:ok, spec}

      i when i + by < 0 or i + by >= length(queue) ->
        {:ok, spec}

      i ->
        other = Enum.at(queue, i + by)
        set_queue(spec, queue |> List.replace_at(i, other) |> List.replace_at(i + by, title))
    end
  end

  def clear_queue(%SpecDoc{} = spec), do: set_queue(spec, [])

  # The queued tasks, in queue order, skipping titles that no longer exist.
  defp queued(spec) do
    {_, blocks} = Spec.blocks(spec.tasks)
    by_title = Map.new(blocks, &{&1.title, &1})
    for title <- spec.queue, block = by_title[title], do: block
  end

  defp set_queue(spec, queue) do
    spec |> Ecto.Changeset.change(queue: queue) |> Repo.update() |> preloaded()
  end

  defp preload(nil), do: nil
  defp preload(spec), do: Repo.preload(spec, [runs: :tasks], force: true)

  defp preloaded({:ok, spec}) do
    spec = preload(spec)
    broadcast("spec:#{spec.id}", {:spec_updated, spec})
    broadcast("specs", {:specs_changed})
    {:ok, spec}
  end

  defp preloaded(error), do: error
end
