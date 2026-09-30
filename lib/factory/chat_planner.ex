defmodule Factory.ChatPlanner do
  @moduledoc """
  Planning in a chat: what the person writes to the workflow's planner is turned into
  tasks, on the planner's own Kiro session (`Factory.Kiro.run_step/4`), so later
  messages keep the conversation; a one-off `Kiro.ask` when that session is busy in
  another folder. The planner (on Kiro, read-only, in the chat's project folder) rethinks how
  it's best done from everything asked so far, the spec files attached and the plan so
  far. It writes the plan with Factory's tools as it goes (`Factory.PlanTools`): a
  summary and approach, then the tasks a few at a time, or changes to the tasks already
  there, so edits the person made to them are kept. It can ask questions instead. Its
  closing message asks whether to implement the tasks (the "start" action).

  Spec files attached in the chat and the plan go into the run's spec
  (`Factory.Specs.for_run/1`), which opens on the Spec page to edit. While it works,
  the planner's live bubble shows what it's doing and the tasks so far
  (`{:agent_stream, …}` on `"run:ID"`). If Kiro can't reach the tools, the planner
  replies with the whole plan as JSON, which replaces the tasks as before.
  """
  alias Factory.{Agents, Kiro, PlanTools, Repo, Runs, Specs}
  alias Factory.Runs.Run
  alias Factory.Specs.{Planner, TaskCheck}

  @doc """
  Whether a chat message is a plan review asked with the Review plan button, which
  earlier versions posted to the chat (marked `"kind" => "review"`, or before that only
  by its opening). Such a message isn't something the person wrote.
  """
  def review_message?(%{role: "user", meta: %{"kind" => "review"}}), do: true

  def review_message?(%{role: "user", body: body}) when is_binary(body),
    do: String.starts_with?(body, "Look at the code again and improve this plan.")

  def review_message?(_message), do: false

  @doc "Adds spec files attached in the chat to the run's spec, for the planner to read."
  def keep_files(%Run{} = run, files) do
    {:ok, _spec} = run |> Specs.for_run() |> Specs.add_files(files)
    Runs.get_run(run.id)
  end

  @doc """
  Plans in the background; the reply is posted to the run. `action:` is a button in
  the chat's plan, which the planner is asked in place of a message (it isn't posted
  to the chat nor counted among the person's requests):

    * `:scope` checks the scope of work: it reads the code and reports, and the plan
      tools only read the plan. The report is posted as it is, marked `"check" => true`.
    * `:refine` reworks the plan in place (it can't be replaced), acting on
      `findings:`, the scope check shown with the plan, if any.

  Both are told which tasks Factory's own rules find thin (`Factory.Specs.TaskCheck`).
  """
  def start(%Run{} = run, planner, opts \\ []) do
    mode = opts[:action]

    with {:ok, {run, files, prompt}} <- prepare(run, planner, mode, opts[:findings]) do
      start_request(run, planner, files, prompt, mode)
    end
  end

  defp prepare(run, planner, mode, findings) do
    Runs.with_locked_run(run.id, fn run ->
      if run.status == "draft" do
        requests =
          for m <- Runs.list_messages(run.id),
              m.role == "user",
              text = String.trim(m.body),
              text != "" and not String.starts_with?(text, "/"),
              # Review requests posted before they became internal aren't requests.
              not review_message?(m),
              do: text

        spec = Specs.for_run(run)
        # Base specs are rules, not part of the run's own files.
        files = Enum.reject(Specs.files(spec), &(elem(&1, 0) == "tasks.md"))
        base = Specs.base_files_for_run(run)
        current = if Specs.tasks(spec) == [], do: nil, else: PlanTools.describe(spec, :full)

        action = mode && %{mode: mode, thin: thin_tasks(spec), findings: findings}

        # What the chat plans for: a review plans checks, not changes.
        workflow = Factory.Workflows.for_run(run)
        job = workflow && Factory.Workflows.kind(workflow)
        # Who can build: each task is given to one of them, with its model.
        agents = Factory.Workflows.builders(workflow)
        prompt_args = [planner.name, requests, base ++ files, current, action, job, agents]

        prompt = %{
          full: apply(Planner, :chat_prompt, prompt_args),
          parts: apply(Planner, :chat_prompt_parts, prompt_args)
        }

        run =
          Runs.get_run(run.id)
          |> Ecto.Changeset.change(planner_generation: Ecto.UUID.generate())
          |> Repo.update!()

        {:ok, run} = Runs.update_run(run, %{description: Enum.join(requests, "\n\n")})
        {:ok, {run, files, prompt}}
      else
        {:error, :not_draft}
      end
    end)
  end

  # Each task Factory's rules find thin, by its number, with what it's missing: the same
  # tasks the chat's plan marks.
  defp thin_tasks(spec) do
    {_, tasks} = Factory.Spec.blocks(spec.tasks || "")

    for {task, i} <- Enum.with_index(tasks, 1), TaskCheck.thin?(task) do
      "Task #{i}, #{task.title}: #{Enum.join(TaskCheck.issues(task), ", ")}"
    end
  end

  defp start_request(run, planner, files, prompt, mode) do
    dir = run.settings["project_dir"] || Kiro.config(:workspace)
    generation = run.planner_generation
    prompt = Map.put(prompt, :model, planning_model(planner))

    Agents.set_activity(planner.id, "running", "Planning “#{run.title}”")
    show_progress(run.id, planner, "Reading the project…")

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      # On the planner's own Kiro session, which keeps the conversation between
      # messages; a one-off session when that one is busy in another folder.
      result =
        case plan_in_session(run, planner, prompt, generation, dir, mode) do
          {:error, :busy} -> plan_once(run, planner, prompt, generation, dir, mode)
          result -> result
        end

      result = with {:ok, r} <- result, do: {:ok, Map.put(r, :check, mode == :scope)}
      finish(run.id, generation, planner, files, result)
    end)

    :ok
  end

  defp plan_in_session(run, planner, prompt, generation, dir, mode) do
    {brief, ask} = prompt.parts

    brief =
      if String.trim(brief) == "",
        do: nil,
        else: {brief, "chat:#{run.id}:" <> Factory.Context.sha256(brief)}

    reply =
      Kiro.run_step(planner, run.id, ask,
        brief: brief,
        source: "plan_chat",
        context: :skip,
        reply: :last,
        post: false,
        stream: false,
        activity: "Planning “#{run.title}”",
        model: prompt.model,
        on_tool: &show_progress(run.id, planner, Planner.describe_tool(&1, dir)),
        planning: %{
          generation: generation,
          notify: self(),
          read_only: mode == :scope,
          keep_plan: mode == :refine
        },
        on_busy: :return
      )

    with {:ok, reply} <- reply, do: read_result(reply, generation, mode == :scope)
  end

  defp plan_once(run, planner, prompt, generation, dir, mode) do
    token =
      PlanTools.grant(run.id, generation, planner,
        read_only: mode == :scope,
        keep_plan: mode == :refine
      )

    with {:ok, reply} <-
           Kiro.ask(prompt.full,
             workdir: dir,
             model: prompt.model,
             allow: ["read", "search", "look"],
             mcp_servers: [PlanTools.mcp_server(token)],
             reply: :last,
             on_tool: &show_progress(run.id, planner, Planner.describe_tool(&1, dir)),
             usage: %{source: "plan_chat", run_id: run.id, agent_id: planner.id}
           ) do
      read_result(reply, generation, mode == :scope)
    end
  end

  # Plans on the planning model (Settings), unless the planner's card names its own.
  defp planning_model(planner) do
    if planner.model in Kiro.models() and planner.model != "auto",
      do: planner.model,
      else: Kiro.planning_model()
  end

  # What the tools reported while Kiro worked (`Factory.PlanTools`). Without any tool
  # call, the reply is the JSON plan the prompt asks for when the tools are missing, or
  # just an answer that leaves the plan as it is.
  # A check's reply is what it found, never a plan to apply.
  defp read_result(reply, generation, true) do
    _ = tool_events(generation, [])

    case String.trim(reply) do
      "" -> {:error, "The check ended without a reply."}
      reply -> {:ok, %{reply: reply, questions: [], written: true}}
    end
  end

  defp read_result(reply, generation, false) do
    reply = String.trim(reply)

    case tool_events(generation, []) do
      [] ->
        case Planner.parse_chat_plan(reply) do
          {:ok, plan} ->
            {:ok, plan}

          {:error, _} when reply != "" ->
            {:ok, %{reply: reply, questions: [], written: true}}

          {:error, _} ->
            {:error, "The planner ended without a plan or a reply."}
        end

      events ->
        questions = for {:questions, qs} <- events, q <- qs, do: q
        {:ok, %{reply: reply, questions: Enum.take(questions, 5), written: true}}
    end
  end

  defp tool_events(generation, acc) do
    receive do
      {:plan_tools, ^generation, event} -> tool_events(generation, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def finish(run_id, generation, planner, files, result) do
    Runs.with_locked_run(run_id, fn run ->
      if run.status == "draft" and not is_nil(generation) and
           run.planner_generation == generation do
        finish(run, planner, files, result)
        run |> Ecto.Changeset.change(planner_generation: nil) |> Repo.update!()
        {:ok, :applied}
      else
        {:ok, :stale}
      end
    end)
  end

  # A check (Check scope): what it found goes to the chat as it is; the plan is unchanged.
  defp finish(run, planner, _files, {:ok, %{check: true, reply: reply}}) do
    Agents.set_activity(planner.id, "idle", nil)
    post(run, planner, reply, %{"check" => true})
  end

  # Written with the tools: the spec already has the plan. With no tasks yet, it's the
  # questions to answer first; with tasks, questions are asked alongside them.
  defp finish(run, planner, files, {:ok, %{written: true, reply: reply, questions: questions}}) do
    Agents.set_activity(planner.id, "idle", nil)
    titles = Enum.map(Runs.get_run(run.id).tasks, & &1.title)

    if titles == [] do
      ask(run, planner, reply, questions)
    else
      post(
        run,
        planner,
        with_questions(blank(reply, "Here's how I'd do it."), questions),
        %{"tasks" => titles, "spec_hint" => files == [], "questions" => questions},
        ["start"]
      )
    end
  end

  # Not clear enough to plan: no tasks, but what's missing and the questions to answer.
  defp finish(run, planner, _files, {:ok, %{reply: reply, tasks: [], questions: questions}}) do
    Agents.set_activity(planner.id, "idle", nil)
    ask(run, planner, reply, questions)
  end

  # The plan replaces the spec's tasks: the planner rethinks it from everything asked.
  defp finish(run, planner, files, {:ok, %{reply: reply, tasks: tasks}}) do
    {:ok, _spec} =
      Specs.update_spec(Specs.for_run(run), %{tasks: Planner.to_markdown(tasks, 1) <> "\n"})

    run = Runs.get_run(run.id)
    Agents.set_activity(planner.id, "idle", nil)

    post(
      run,
      planner,
      blank(reply, "Here's how I'd do it."),
      %{
        "tasks" => Enum.map(tasks, & &1["title"]),
        "spec_hint" => files == []
      },
      ["start"]
    )
  end

  defp finish(run, planner, _files, {:error, reason}) do
    Agents.set_activity(planner.id, "error", reason)
    post(run, planner, "I couldn't plan it: #{reason} Try again, or say it differently.", %{})
  end

  defp ask(run, planner, reply, questions) do
    body =
      with_questions(
        blank(reply, "I need a bit more information before I can plan this."),
        questions
      )

    post(run, planner, body, %{"unclear" => questions != [], "questions" => questions})
  end

  defp with_questions(body, []), do: body

  defp with_questions(body, questions) do
    listed =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {q, i} ->
        options = if q["options"] == [], do: "", else: " (#{Enum.join(q["options"], " / ")})"
        "#{i}. #{q["question"]}#{options}"
      end)

    body <> "\n\n" <> listed
  end

  defp post(run, planner, body, meta, actions \\ []) do
    Runs.post(run, "factory", body,
      author: planner.name,
      meta: Map.put(meta, "agent_id", planner.id),
      actions: actions
    )
  end

  @doc """
  Shows in the planner's live bubble what it's doing (`activity`) and the tasks so far,
  read from the run's spec. `planner` needs its `id` and `name`.
  """
  def show_progress(run_id, planner, activity) do
    tasks =
      with %{spec_id: id} when is_integer(id) <- Runs.get_run(run_id),
           %{} = spec <- Specs.get_spec(id),
           [_ | _] = tasks <- Specs.tasks(spec) do
        "\n\n**Tasks so far**\n\n" <>
          (tasks
           |> Enum.with_index(1)
           |> Enum.map_join("\n", fn {t, i} -> "#{i}. #{t.title}" end))
      else
        _ -> ""
      end

    text = "_#{activity}_" <> tasks

    Phoenix.PubSub.broadcast(
      Factory.PubSub,
      "run:#{run_id}",
      {:agent_stream, %{agent_id: planner.id, name: planner.name, text: text, activity: activity}}
    )
  end

  defp blank(text, default), do: if(String.trim(text) == "", do: default, else: text)
end
