defmodule Factory.ChatPlanner do
  @moduledoc """
  Planning in a chat: what the person writes to the workflow's planner is turned into
  tasks. The planner (on Kiro, read-only, in the chat's project folder) rethinks how
  it's best done from everything asked so far, the spec files attached and the tasks
  it wrote before, then replies with its approach and the tasks. The tasks become the
  run's tasks, and the reply asks whether to implement them (the "start" action).

  Spec files attached in the chat and the tasks it writes go into the run's spec
  (`Factory.Specs.for_run/1`), which opens on the Spec page to edit. While it works,
  the planner's live bubble shows what it's reading (`{:agent_stream, …}` on `"run:ID"`).
  """
  alias Factory.{Agents, Kiro, Runs, Specs}
  alias Factory.Runs.Run
  alias Factory.Specs.Planner

  @doc "Adds spec files attached in the chat to the run's spec, for the planner to read."
  def keep_files(%Run{} = run, files) do
    {:ok, _spec} = run |> Specs.for_run() |> Specs.add_files(files)
    Runs.get_run(run.id)
  end

  @doc "Plans in the background; the reply is posted to the run."
  def start(%Run{} = run, planner) do
    topic = "run:#{run.id}"
    dir = run.settings["project_dir"] || Kiro.config(:workspace)

    requests =
      for m <- Runs.list_messages(run.id),
          m.role == "user",
          text = String.trim(m.body),
          text != "" and not String.starts_with?(text, "/"),
          do: text

    spec = Specs.for_run(run)
    # The spec's own text, and the base specs (company rules), which aren't the run's own.
    files = Enum.reject(Specs.files(spec), &(elem(&1, 0) == "tasks.md"))
    base = Specs.base_files_for_run(run)
    current = if Specs.tasks(spec) == [], do: nil, else: spec.tasks
    prompt = Planner.chat_prompt(planner.name, requests, base ++ files, current)

    # The engine's agents are told the job is what was asked.
    {:ok, run} = Runs.update_run(run, %{description: Enum.join(requests, "\n\n")})

    Agents.set_activity(planner.id, "running", "Planning “#{run.title}”")
    say_live(topic, planner, "_Reading the project…_")

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      result =
        with {:ok, reply} <-
               Kiro.ask(prompt,
                 workdir: dir,
                 allow: ["read", "search"],
                 on_tool: &say_live(topic, planner, "_#{Planner.describe_tool(&1, dir)}_"),
                 usage: %{source: "plan_chat", run_id: run.id, agent_id: planner.id}
               ) do
          Planner.parse_chat_plan(reply)
        end

      if run = Runs.get_run(run.id), do: finish(run, planner, files, result)
    end)

    :ok
  end

  # Not clear enough to plan: no tasks, but what's missing and the questions to answer.
  defp finish(run, planner, _files, {:ok, %{reply: reply, tasks: [], questions: questions}}) do
    Agents.set_activity(planner.id, "idle", nil)

    listed =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {q, i} ->
        options = if q["options"] == [], do: "", else: " (#{Enum.join(q["options"], " / ")})"
        "#{i}. #{q["question"]}#{options}"
      end)

    body =
      [blank(reply, "I need a bit more information before I can plan this."), listed]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    post(run, planner, body, %{"unclear" => questions != [], "questions" => questions})
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

  defp post(run, planner, body, meta, actions \\ []) do
    Runs.post(run, "factory", body,
      author: planner.name,
      meta: Map.put(meta, "agent_id", planner.id),
      actions: actions
    )
  end

  defp say_live(topic, planner, text) do
    Phoenix.PubSub.broadcast(
      Factory.PubSub,
      topic,
      {:agent_stream, %{agent_id: planner.id, name: planner.name, text: text}}
    )
  end

  defp blank(text, default), do: if(String.trim(text) == "", do: default, else: text)
end
