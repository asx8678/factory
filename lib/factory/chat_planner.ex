defmodule Factory.ChatPlanner do
  @moduledoc """
  Planning in a chat: what the person writes to the workflow's planner is turned into
  tasks. The planner (on Kiro, read-only, in the chat's project folder) rethinks how
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
  alias Factory.Specs.Planner

  @doc "Adds spec files attached in the chat to the run's spec, for the planner to read."
  def keep_files(%Run{} = run, files) do
    {:ok, _spec} = run |> Specs.for_run() |> Specs.add_files(files)
    Runs.get_run(run.id)
  end

  @doc "Plans in the background; the reply is posted to the run."
  def start(%Run{} = run, planner) do
    with {:ok, {run, files, prompt}} <- prepare(run, planner) do
      start_request(run, planner, files, prompt)
    end
  end

  defp prepare(run, planner) do
    Runs.with_locked_run(run.id, fn run ->
      if run.status == "draft" do
        requests =
          for m <- Runs.list_messages(run.id),
              m.role == "user",
              text = String.trim(m.body),
              text != "" and not String.starts_with?(text, "/"),
              do: text

        spec = Specs.for_run(run)
        # Base specs are rules, not part of the run's own files.
        files = Enum.reject(Specs.files(spec), &(elem(&1, 0) == "tasks.md"))
        base = Specs.base_files_for_run(run)
        current = if Specs.tasks(spec) == [], do: nil, else: PlanTools.describe(spec, :full)
        prompt = Planner.chat_prompt(planner.name, requests, base ++ files, current)

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

  defp start_request(run, planner, files, prompt) do
    dir = run.settings["project_dir"] || Kiro.config(:workspace)
    generation = run.planner_generation

    Agents.set_activity(planner.id, "running", "Planning “#{run.title}”")
    show_progress(run.id, planner, "Reading the project…")

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      token = PlanTools.grant(run.id, generation, planner)

      result =
        with {:ok, reply} <-
               Kiro.ask(prompt,
                 workdir: dir,
                 allow: ["read", "search"],
                 mcp_servers: [PlanTools.mcp_server(token)],
                 reply: :last,
                 on_tool: &show_progress(run.id, planner, Planner.describe_tool(&1, dir)),
                 usage: %{source: "plan_chat", run_id: run.id, agent_id: planner.id}
               ) do
          read_result(reply, generation)
        end

      finish(run.id, generation, planner, files, result)
    end)

    :ok
  end

  # What the tools reported while Kiro worked (`Factory.PlanTools`). Without any tool
  # call, the reply is the JSON plan the prompt asks for when the tools are missing, or
  # just an answer that leaves the plan as it is.
  defp read_result(reply, generation) do
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
      {:agent_stream, %{agent_id: planner.id, name: planner.name, text: text}}
    )
  end

  defp blank(text, default), do: if(String.trim(text) == "", do: default, else: text)
end
