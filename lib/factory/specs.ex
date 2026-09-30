defmodule Factory.Specs do
  @moduledoc """
  Specs for spec-driven development: an overview (the main spec file), then
  requirements, design and tasks, each approved by a person before the next step opens. An approved spec starts runs.
  """
  import Ecto.Query
  alias Factory.{Repo, Runs, Spec}
  alias Factory.Specs.{Planner, Review}
  alias Factory.Specs.Spec, as: SpecDoc

  # A spec's steps (see SpecDoc.steps/0), for guards.
  @parts ~w(overview requirements design tasks)

  @doc "Subscribes to `{:specs_changed}` for the list."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, "specs")

  @doc "Subscribes to `{:spec_updated, spec}` for one spec."
  def subscribe(id), do: Phoenix.PubSub.subscribe(Factory.PubSub, "spec:#{id}")

  @doc "Run specs: each one run's own spec, newest first."
  def list_specs do
    Repo.all(
      from s in SpecDoc,
        where: s.kind == "run",
        order_by: [desc: s.updated_at, desc: s.id],
        preload: [runs: :tasks]
    )
  end

  # Base specs: company rules and conventions, kept and included in any run.

  @doc "Base specs, by name."
  def list_base_specs do
    Repo.all(
      from s in SpecDoc, where: s.kind == "base", order_by: [asc: fragment("lower(?)", s.name)]
    )
  end

  @doc "A base spec: a name and one markdown document."
  def create_base_spec(name, content) do
    create_spec(name, %{kind: "base", overview: content || ""})
  end

  @doc "The base specs with these ids as files for Kiro, in the order given: `[{name, text}]`."
  def base_files(ids) when is_list(ids) and ids != [] do
    by_id =
      Repo.all(from s in SpecDoc, where: s.kind == "base" and s.id in ^ids)
      |> Map.new(&{&1.id, &1})

    for id <- ids,
        spec = by_id[id],
        String.trim(spec.overview) != "",
        do: {"base-spec: #{spec.name}.md", spec.overview}
  end

  def base_files(_ids), do: []

  @doc "The base specs a run includes (`settings[\"base_spec_ids\"]`), as files."
  def base_files_for_run(%{settings: settings}),
    do: base_files((settings || %{})["base_spec_ids"])

  def base_files_for_run(_run), do: []

  def get_spec(id), do: SpecDoc |> Repo.get(id) |> preload()

  @doc """
  A run's own spec: its plan (overview, requirements, design, tasks). Everything that
  plans a run writes here, whether in the chat or on the Spec page. Until the run
  starts, its tasks and the text its agents read follow the spec (`update_spec/2`).
  Made the first time it's needed, in the run's project folder.
  """
  def for_run(%Factory.Runs.Run{spec_id: id} = run) when is_integer(id),
    do: get_spec(id) || new_for_run(run)

  def for_run(%Factory.Runs.Run{} = run), do: new_for_run(run)

  # A run planned before it had a spec keeps its files in its spec text; the new spec
  # starts from them, so the run's tasks aren't lost.
  defp new_for_run(run) do
    {:ok, spec} = create_spec(run.title)
    {:ok, spec} = set_project_dir(spec, run.settings["project_dir"])
    {:ok, _run} = Factory.Runs.update_run(run, %{spec_id: spec.id})

    case run_files(run.spec) do
      [] -> spec
      files -> spec |> add_files(files) |> elem(1)
    end
  end

  # The files in a run's spec text (`Factory.Runs.attach_spec/3`), as `[{name, text}]`.
  defp run_files(nil), do: []

  defp run_files(text) do
    ~r/<!-- file: (.+?) -->\n/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [marker, body] ->
        [_, name] = Regex.run(~r/<!-- file: (.+?) -->/, marker)
        [{name, String.trim(body)}]

      _ ->
        []
    end)
  end

  @doc """
  Adds files (`[{name, content}]`) to the spec, each in the step its name says
  (`step_for/1`). A tasks file replaces the tasks; other text is added after what the
  step has, unless it's there already.
  """
  def add_files(%SpecDoc{} = spec, files) do
    changes =
      Enum.reduce(files, %{}, fn {name, text}, changes ->
        step = String.to_existing_atom(step_for(name))
        text = String.trim(text)
        now = Map.get(changes, step, Map.fetch!(spec, step) || "")

        cond do
          text == "" or String.contains?(now, text) -> changes
          step == :tasks or String.trim(now) == "" -> Map.put(changes, step, text <> "\n")
          true -> Map.put(changes, step, String.trim_trailing(now) <> "\n\n" <> text <> "\n")
        end
      end)

    if changes == %{}, do: {:ok, spec}, else: update_spec(spec, changes)
  end

  @doc """
  Brings a run in step with its spec: the run's tasks and the spec text its agents
  read (`Factory.Runs.attach_spec/3`).
  """
  def sync_run(%SpecDoc{} = spec, %Factory.Runs.Run{} = run),
    do: Factory.Runs.attach_spec(run, files(spec), tasks(spec))

  def create_spec(name, attrs \\ %{}) do
    %SpecDoc{}
    |> SpecDoc.changeset(Map.put(attrs, :name, name))
    |> Repo.insert()
    |> preloaded()
  end

  @doc """
  Creates a spec from files (`[{name, content}]`). Each goes into the step its name
  says (requirements.md, design.md, tasks.md); any other file is the main spec and
  goes into the overview. A file given as `{name, content, step}` goes into that step.
  Without a name, the spec is named after the first heading or file.
  """
  def create_from_files(name, files) do
    files =
      Enum.map(files, fn
        {file, text} -> {file, text, step_for(file)}
        {file, text, step} when step in @parts -> {file, text, step}
      end)

    steps =
      files
      |> Enum.group_by(&elem(&1, 2), &elem(&1, 1))
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

  # The main spec names it: the first line of a typed description, else the first
  # heading in a main spec file. Failing that, the first heading in any file (a
  # requirements.md's "# Requirements" says little), else the first file's name.
  defp name_from([first | _] = files) do
    {main, others} = Enum.split_with(files, &(elem(&1, 2) == "overview"))
    Enum.find_value(main ++ others, fallback_name(first), &name_of/1)
  end

  defp name_of({:description, text, _}) do
    first = text |> String.split(~r/\R/u, trim: true) |> List.first("")

    case first |> String.replace(~r/^\s*#+\s*/, "") |> String.trim() do
      "" -> nil
      line -> if String.length(line) > 60, do: String.slice(line, 0, 57) <> "…", else: line
    end
  end

  defp name_of({_file, text, _}) do
    case Regex.run(~r/^#\s+(.+)$/m, text) do
      [_, heading] -> heading |> String.trim() |> String.slice(0, 80)
      _ -> nil
    end
  end

  defp fallback_name({file, _, _}) when is_binary(file), do: Path.rootname(Path.basename(file))
  defp fallback_name(_description), do: "New spec"

  @doc """
  The parts Kiro writes when it plans a run that this spec doesn't have yet, in order:
  some of "requirements", "design" and "tasks". Tasks count as missing until there's
  at least one.
  """
  def missing_parts(%SpecDoc{} = spec) do
    for part <- ~w(requirements design tasks),
        missing?(spec, part),
        do: part
  end

  defp missing?(spec, "tasks"), do: tasks(spec) == []

  defp missing?(spec, part),
    do: String.trim(Map.fetch!(spec, String.to_existing_atom(part))) == ""

  @doc "Changes the spec's text. A run planned in it and not started yet follows the change."
  def update_spec(%SpecDoc{} = spec, attrs) do
    with {:ok, spec} <- spec |> SpecDoc.changeset(attrs) |> Repo.update() |> preloaded() do
      case home_run(spec) do
        %{status: "draft"} = run -> sync_run(spec, run)
        _ -> :ok
      end

      {:ok, spec}
    end
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

  @doc """
  Kiro writes the parts the spec is missing (`missing_parts/1`) in the background, in
  one turn, keeping to the parts it has; then QA reviews the spec. Kiro reads the
  project first (read-only). Progress is in `spec.plan["write"]`: `"status"` is
  "running", "done" (with `"wrote"` and `"why"`) or "error" (with `"error"`).
  Returns `{:error, :nothing_missing}` when every part is there.
  """
  def write_missing(%SpecDoc{} = spec) do
    case missing_parts(spec) do
      [] ->
        {:error, :nothing_missing}

      write ->
        run = home_run(spec)

        with %Factory.Agents.Workflow{} = workflow <- Factory.Workflows.for_run(run || %{}) do
          type = Factory.Runs.Types.get(Factory.Workflows.kind(workflow))

          agents =
            workflow.id
            |> Factory.Engine.workflow_steps()
            |> Enum.reject(&(&1.kind == "action"))
            |> Enum.map_join(" → ", & &1.name)

          prompt = Planner.run_prompt(type, kiro_files(spec), write: write, agents: agents)
          {:ok, spec} = set_write(spec, %{"status" => "running", "writing" => write})
          dir = project_dir(spec)

          Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
            result =
              with {:ok, reply} <-
                     Factory.Kiro.ask(prompt,
                       workdir: dir,
                       allow: ["read", "search"],
                       on_tool:
                         &broadcast(
                           "spec:#{spec.id}",
                           {:plan_activity, Planner.describe_tool(&1, dir)}
                         ),
                       usage: %{source: "plan_run", spec_id: spec.id, run_id: run && run.id}
                     ) do
                Planner.parse_run_plan(reply, write)
              end

            if spec = get_spec(spec.id), do: wrote(spec, write, result)
          end)

          {:ok, spec}
        else
          nil -> wrote(spec, write, {:error, "This run's workflow no longer exists."})
        end
    end
  end

  defp wrote(spec, _write, {:error, reason}),
    do: set_write(spec, %{"status" => "error", "error" => reason})

  defp wrote(spec, write, {:ok, plan}) do
    changes =
      for part <- write, into: %{} do
        case part do
          "requirements" -> {:requirements, plan.requirements}
          "design" -> {:design, plan.design}
          # After any text the person gave that has no tasks in it.
          "tasks" -> {:tasks, join(spec.tasks, Planner.to_markdown(plan.tasks, 1) <> "\n")}
        end
      end

    {:ok, spec} = update_spec(spec, changes)
    {:ok, spec} = set_write(spec, %{"status" => "done", "wrote" => write, "why" => plan.why})
    review(spec)
    {:ok, spec}
  end

  defp join(text, more) do
    case String.trim(text || "") do
      "" -> more
      text -> text <> "\n\n" <> more
    end
  end

  defp set_write(spec, write), do: set_plan(spec, Map.put(spec.plan || %{}, "write", write))

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

    # Writing the missing parts keeps its progress under the plan's "write" key.
    from(s in SpecDoc,
      where: fragment("?->'write'->>'status' = 'running'", s.plan),
      update: [set: [plan: fragment("jsonb_set(?, '{write}', ?)", s.plan, type(^stopped, :map))]]
    )
    |> Repo.update_all([])
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

  @doc """
  Step 2: with the answers (`[%{\"question\", \"answer\"}]`), Kiro suggests tasks. It adds
  them with Factory's `suggest_tasks` tool (`Factory.PlanTools`), so they show as they
  come (`plan["tasks"]` while `"writing"`); without the tool, its JSON reply is read.
  """
  def plan_tasks(%SpecDoc{} = spec, answers) do
    if planning?(spec) do
      {:error, :running}
    else
      ref = Ecto.UUID.generate()

      plan =
        Map.merge(spec.plan, %{
          "status" => "writing",
          "answers" => answers,
          "tasks" => [],
          "ref" => ref
        })

      {:ok, spec} = set_plan(spec, plan)
      prompt = Planner.tasks_prompt(kiro_files(spec), plan["project"] || "", answers)
      failed = plan |> Map.put("failed", "writing") |> Map.delete("tasks")
      token = Factory.PlanTools.grant_suggest(spec.id, ref)

      # What the tool added, else the reply's JSON.
      parse = fn reply ->
        case get_spec(spec.id) do
          %{plan: %{"ref" => ^ref, "tasks" => [_ | _] = tasks}} -> {:ok, tasks}
          _ -> Planner.parse_tasks(reply)
        end
      end

      run_plan(
        spec,
        "plan_tasks",
        prompt,
        parse,
        failed,
        fn tasks -> Map.merge(plan, %{"status" => "tasks", "tasks" => tasks}) end,
        mcp_servers: [Factory.PlanTools.mcp_server(token)]
      )

      {:ok, spec}
    end
  end

  @doc """
  Adds suggested tasks (in `Factory.Specs.Planner.task/1`'s shape, with a size) to the
  spec's suggestions while round `ref` is being written: `{:ok, how many now}`, or
  `{:error, :full}` at 30, or `{:error, :stale}` when that round is over or replaced.
  """
  def add_suggestions(spec_id, ref, tasks) do
    result =
      Repo.transact(fn ->
        spec = Repo.one(from s in SpecDoc, where: s.id == ^spec_id, lock: "FOR UPDATE")
        have = (spec && spec.plan["tasks"]) || []

        cond do
          spec == nil or spec.plan["status"] != "writing" or spec.plan["ref"] != ref ->
            {:error, :stale}

          length(have) >= 30 ->
            {:error, :full}

          true ->
            all = have ++ Enum.take(tasks, 30 - length(have))
            spec |> Ecto.Changeset.change(plan: Map.put(spec.plan, "tasks", all)) |> Repo.update()
        end
      end)

    with {:ok, spec} <- preloaded(result), do: {:ok, length(spec.plan["tasks"])}
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
  defp run_plan(spec, source, prompt, parse, base, done, opts \\ []) do
    dir = spec.project_dir
    topic = "spec:#{spec.id}"

    on_tool = fn update ->
      broadcast(topic, {:plan_activity, Planner.describe_tool(update, dir)})
    end

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      plan =
        with {:ok, reply} <-
               Factory.Kiro.ask(
                 prompt,
                 [
                   workdir: dir,
                   allow: ["read", "search"],
                   on_tool: on_tool,
                   usage: %{source: source, spec_id: spec.id}
                 ] ++ opts
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
    run = home_run(spec)

    workflow_id =
      case run do
        %{settings: %{"workflow_id" => id}} -> id
        _ -> nil
      end

    # The base specs the run follows come first: everything else must respect them.
    base = base_files_for_run(run)

    case Factory.Sources.context(workflow_id) do
      "" -> base ++ files(spec)
      text -> base ++ files(spec) ++ [{"data-sources.md", text}]
    end
  end

  @doc "The spec as Kiro's three files, skipping empty ones."
  def files(%SpecDoc{} = spec) do
    for step <- SpecDoc.steps(),
        text = Map.fetch!(spec, String.to_existing_atom(step)),
        String.trim(text) != "",
        do: {step <> ".md", text}
  end

  @doc "The run this spec was written for: the first one it's linked to (`for_run/1`)."
  def home_run(%SpecDoc{id: id}) do
    Repo.one(
      from r in Factory.Runs.Run,
        where: r.spec_id == ^id,
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
        asked = (home_run(spec) || %{description: nil}).description
        prompt = Planner.improve_prompt(kiro_files(spec), task, instruction, asked || "")

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

  # Changing a plan from the chat, while its run is still being planned. The chat's
  # planner writes the tasks without the Spec page's step order (Factory.PlanTools),
  # and so do these; only an approved tasks step is closed to them.

  @doc """
  Changes task `index` of a plan being made in the chat: its title, details (one per
  line) and requirements (comma separated). `{:error, :locked}` once the tasks step is
  approved on the Spec page.
  """
  def edit_plan_task(%SpecDoc{} = spec, index, %{} = params) do
    title = params |> Map.get("title", "") |> to_string() |> String.trim()

    details =
      params |> Map.get("details", "") |> to_string() |> String.split(~r/\R/u) |> clean_lines()

    requirements =
      params |> Map.get("requirements", "") |> to_string() |> String.split(",") |> clean_lines()

    {preamble, blocks} = Spec.blocks(spec.tasks)

    cond do
      SpecDoc.approved?(spec, "tasks") ->
        {:error, :locked}

      title == "" ->
        {:error, :blank_title}

      Enum.at(blocks, index) == nil ->
        {:error, :not_found}

      true ->
        blocks = List.update_at(blocks, index, &Spec.edit_block(&1, title, details, requirements))
        update_spec(spec, %{tasks: Spec.render_blocks(preamble, blocks)})
    end
  end

  @doc "Removes task `index` from a plan being made in the chat, like `edit_plan_task/3`."
  def remove_plan_task(%SpecDoc{} = spec, index) do
    {preamble, blocks} = Spec.blocks(spec.tasks)

    cond do
      SpecDoc.approved?(spec, "tasks") ->
        {:error, :locked}

      Enum.at(blocks, index) == nil ->
        {:error, :not_found}

      true ->
        kept = List.delete_at(blocks, index)
        tasks = if kept == [], do: "", else: Spec.render_blocks(preamble, kept)

        with {:ok, spec} <- update_spec(spec, %{tasks: tasks}) do
          titles = Enum.map(kept, & &1.title)
          set_queue(spec, Enum.filter(spec.queue, &(&1 in titles)))
        end
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
