defmodule Factory.Launch do
  @moduledoc """
  Starting a factory run: the person picks a kind of job (`Factory.Runs.Types`),
  describes it and chooses how the factory should work. That makes a spec, whose
  overview is what they wrote, and a run that holds it all: the kind, the
  description, the settings and Kiro's planning.

  Kiro then plans the run in the background, in one turn: it reads the project and
  writes the spec's requirements, design and tasks (and, if asked, picks the
  workflow and the model). With `approve_plan` the person reviews and approves the
  plan in the spec; without it the plan is approved and the run is queued at once.

  Subscribers to `"run:ID"` (`Factory.Runs.subscribe/1`) get `{:run_updated, run}`
  as the plan changes and `{:run_activity, text}` while Kiro reads the project.
  """
  import Ecto.Query
  alias Factory.{Kiro, Repo, Runs, Specs}
  alias Factory.Runs.{Run, Setup, Types}
  alias Factory.Specs.Planner

  @doc """
  Starts a factory run of `kind` from the person's `answers` (field key => text) and
  `settings` (see `Types.default_settings/1`). Returns `{:ok, run}` with Kiro's
  planning under way, or `{:error, :unknown_kind | :missing_answer}`.
  """
  def start(kind, answers, settings) do
    cond do
      Types.get(kind) == nil ->
        {:error, :unknown_kind}

      not Types.ready?(kind, answers) ->
        {:error, :missing_answer}

      true ->
        settings = Map.merge(Types.default_settings(kind), settings)
        title = Types.title(kind, answers)
        overview = Types.overview(kind, title, answers)
        dir = project_dir(settings)

        {:ok, run} =
          Repo.transact(fn ->
            with {:ok, spec} <- Specs.create_spec(title, %{overview: overview}),
                 {:ok, spec} <- Specs.set_project_dir(spec, dir),
                 {:ok, spec} <- Specs.approve(spec, "overview"),
                 {:ok, run} <- Runs.create_run(title),
                 {:ok, run} <-
                   Runs.update_run(run, %{
                     kind: kind,
                     description: overview,
                     settings: Map.put(settings, "project_dir", dir),
                     spec_id: spec.id,
                     plan: %{"status" => "writing"}
                   }) do
              {:ok, run}
            end
          end)

        plan(run)
        {:ok, run}
    end
  end

  defp project_dir(settings) do
    case String.trim(settings["project_dir"] || "") do
      "" -> Kiro.config(:workspace)
      dir -> Path.expand(dir)
    end
  end

  @doc "Asks Kiro to plan the run, in the background. Also used to try again after an error."
  def plan(%Run{} = run) do
    {:ok, run} = Runs.update_run(run, %{plan: %{"status" => "writing"}})
    spec = Specs.get_spec(run.spec_id)
    type = Types.get(run.kind)
    settings = run.settings
    dir = settings["project_dir"]
    topic = "run:#{run.id}"

    prompt =
      Planner.run_prompt(type, Specs.kiro_files(spec),
        roles: Types.roles(),
        workflow: settings["workflow"],
        pick_workflow: settings["workflow_mode"] == "kiro",
        pick_model: settings["setup_mode"] == "kiro",
        models: Kiro.models()
      )

    on_tool = fn update ->
      Phoenix.PubSub.broadcast(
        Factory.PubSub,
        topic,
        {:run_activity, Planner.describe_tool(update, dir)}
      )
    end

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      result =
        with {:ok, reply} <-
               Kiro.ask(prompt,
                 workdir: dir,
                 allow: ["read", "search"],
                 on_tool: on_tool,
                 usage: %{source: "plan_run", run_id: run.id, spec_id: spec.id}
               ) do
          Planner.parse_run_plan(reply, Factory.Agents.Agent.kinds(), Kiro.models())
        end

      if run = Runs.get_run(run.id), do: apply_plan(run, result)
    end)

    {:ok, run}
  end

  defp apply_plan(run, {:error, reason}),
    do: Runs.update_run(run, %{plan: %{"status" => "error", "error" => reason}})

  defp apply_plan(run, {:ok, plan}) do
    spec = Specs.get_spec(run.spec_id)

    {:ok, spec} =
      Specs.update_spec(spec, %{
        requirements: plan.requirements,
        design: plan.design,
        tasks: Planner.to_markdown(plan.tasks, 1) <> "\n"
      })

    settings =
      run.settings
      |> then(&if plan.workflow, do: Map.put(&1, "workflow", plan.workflow), else: &1)
      |> then(&if plan.model, do: Map.put(&1, "model", plan.model), else: &1)

    {:ok, run} =
      Runs.update_run(run, %{
        settings: settings,
        plan: %{"status" => "done", "why" => plan.why, "tasks" => length(plan.tasks)}
      })

    if settings["approve_plan"] == false, do: approve_and_queue(run, spec), else: {:ok, run}
  end

  # No approval asked for: approve every step and queue the run.
  defp approve_and_queue(run, spec) do
    with {:ok, spec} <- approve(spec, "requirements"),
         {:ok, spec} <- approve(spec, "design"),
         {:ok, spec} <- approve(spec, "tasks"),
         {:ok, run} <- Specs.start_run(spec) do
      # start_run attaches the tasks; read the run again so /run sees them.
      Factory.Chat.action(Runs.get_run(run.id), "start")
      {:ok, Runs.get_run(run.id)}
    else
      _ ->
        # Something couldn't be approved (e.g. empty design): leave it for the person.
        {:ok, run}
    end
  end

  defp approve(spec, step) do
    if Specs.Spec.approved?(spec, step), do: {:ok, spec}, else: Specs.approve(spec, step)
  end

  @doc """
  What to do next with a run, for its Continue button:
  `{label, path}`, `{label, :start}`, or `nil` while Kiro is planning or after it
  failed (the run page offers to try again).
  """
  def next_step(%Run{kind: nil} = run), do: {"Open chat", "/chat/#{run.id}"}

  def next_step(%Run{} = run) do
    spec = run.spec_id && Specs.get_spec(run.spec_id)

    cond do
      run.plan["status"] in ["writing", "error"] ->
        nil

      run.tasks != [] ->
        {"Open chat", "/chat/#{run.id}"}

      spec == nil ->
        {"Open chat", "/chat/#{run.id}"}

      Specs.Spec.current_step(spec) == "ready" ->
        {"Start run", :start}

      true ->
        step = Specs.Spec.current_step(spec)
        {"Review #{step}", "/specs/#{spec.id}?step=#{step}"}
    end
  end

  # Saved setups

  def list_setups, do: Repo.all(from s in Setup, order_by: [desc: s.updated_at, desc: s.id])
  def get_setup(id), do: Repo.get(Setup, id)

  @doc "Saves a run's choices (without the project folder's answers) to start from later."
  def save_setup(name, kind, settings) do
    %Setup{} |> Setup.changeset(%{name: name, kind: kind, settings: settings}) |> Repo.insert()
  end

  def delete_setup(%Setup{} = setup), do: Repo.delete(setup)

  @doc "Factory runs, newest first, each with its usage: `[{run, totals}]`."
  def recent_runs(limit \\ 8) do
    runs =
      Repo.all(
        from r in Run,
          where: not is_nil(r.kind),
          order_by: [desc: r.updated_at, desc: r.id],
          limit: ^limit,
          preload: :tasks
      )

    Enum.map(runs, &{&1, Factory.Usage.totals({:run, &1.id})})
  end
end
