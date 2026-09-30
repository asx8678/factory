defmodule Factory.Chat do
  @moduledoc """
  Handles what a person types into a run's chat. Slash commands are carried out
  here in Elixir. Written to an agent, a message goes to its Kiro session; written to
  the workflow's planner before the run starts, it's planned into the run's spec
  (`Factory.ChatPlanner`). Spec files dropped in go into the run's spec too.
  """
  alias Factory.{Agents, Engine, Kiro, Runs, Spec, Specs, Workflows}
  alias Factory.Runs.Run

  @commands [
    {"/help", "Show the commands"},
    {"/ask", "Ask an agent on Kiro, e.g. /ask Coder what does mix.exs do?"},
    {"/compact", "Shorten an agent's conversation to save context, e.g. /compact Coder"},
    {"/run", "Start the run with the attached spec"},
    {"/status", "Show progress"},
    {"/tasks", "List the tasks"},
    {"/pause", "Pause the run"},
    {"/resume", "Resume a paused run"},
    {"/cancel", "Cancel the run"},
    {"/rename", "Rename this chat, e.g. /rename Login page"},
    {"/workflow", "Show the agents the run will use"}
  ]

  def commands, do: @commands

  @doc """
  Posts the person's message, applies any attached spec files
  (`[{name, content}]`), then runs the command and posts the factory's reply.

  With `to: agent` the chat is focused on one agent: plain text goes straight
  to that agent, and every reply is tagged with it so it shows in that agent's view.
  Before a run starts, what's written to a planner is planned into tasks
  (`Factory.ChatPlanner`), and files attached with it are its spec.
  """
  def handle(%Run{} = run, text, files \\ [], opts \\ []) do
    run = Runs.get_run(run.id)
    text = String.trim(text)
    agent = opts[:to]
    # "/ask Coder …" from the All view also belongs in Coder's own chat.
    recipient = agent || asked_agent(run, text)
    to_meta = if recipient, do: %{"to_agent_id" => recipient.id}, else: %{}
    Runs.post(run, "user", text, attachments: Enum.map(files, &elem(&1, 0)), meta: to_meta)

    tagged(agent, fn ->
      cond do
        ((not is_nil(agent) and not String.starts_with?(text, "/")) or
           String.starts_with?(text, ["/ask", "/compact", "/workflow"])) and
            is_nil(Workflows.for_run(run)) ->
          {:error, reason} = Engine.executable_steps(run)
          say(run, reason)

        planner = planning?(run, agent, text) ->
          run = if files != [], do: Factory.ChatPlanner.keep_files(run, files), else: run
          Factory.ChatPlanner.start(run, planner)

        true ->
          run = if files != [], do: attach(run, files), else: run

          cond do
            text == "" -> :ok
            agent && not String.starts_with?(text, "/") -> ask_agent(run, agent, text)
            true -> command(run, text)
          end
      end
    end)

    if text != "" and Factory.Runs.Titles.chat_message?(run), do: Factory.Runs.Titles.start(run)
    :ok
  end

  # Until the run starts, what's written to its planner (or to Factory itself) is planned
  # into tasks; after that the planner is an agent to talk to. A workflow without a
  # planner agent plans with its first agent when that one reads and works out what to
  # do (a bug's Investigator, say); other agents are just talked to.
  defp planning?(%Run{status: "draft"}, _agent, "/" <> _), do: false

  defp planning?(%Run{status: "draft"} = run, agent, text) do
    case planner_for(run) do
      nil -> false
      planner when agent == nil -> text != "" and planner
      planner -> agent.id == planner.id and planner
    end
  end

  defp planning?(_run, _agent, _text), do: false

  @doc """
  The agent that plans a run's tasks: its workflow's planner, else its first agent if
  that one is a researcher or an orchestrator, else nil.
  """
  def planner_for(%Run{} = run) do
    case Enum.find(agents(run), &(&1.kind == "planner")) do
      nil ->
        first = run |> Engine.steps() |> Enum.find(&(&1.kind != "action"))
        if first && first.kind in ~w(researcher orchestrator), do: first.agent

      planner ->
        planner
    end
  end

  @doc "Runs a button action shown under a factory message."
  def action(%Run{} = run, "start"), do: command(Runs.get_run(run.id), "/run")

  @doc """
  Gives a run exactly these spec files (`[{name, content}]`) and the tasks in them,
  and posts what was found. Used when a spec starts a run (`Factory.Specs.start_run/1`).
  """
  def attach_spec(%Run{} = run, files) do
    {_, tasks} = Spec.tasks_from_files(files)
    {:ok, run} = Runs.attach_spec(run, files, tasks)
    report(run, files)
  end

  # Files dropped into the chat go into the run's spec, which the run then follows.
  defp attach(run, files) do
    {:ok, _spec} = run |> Specs.for_run() |> Specs.add_files(files)
    report(Runs.get_run(run.id), files)
  end

  defp report(run, files) do
    case Spec.tasks_from_files(files) do
      {nil, []} ->
        say(run, """
        I stored #{names(files)} but found no tasks in it. Tasks are top-level lines like \
        `- [ ] 1. Add login page` or `1. Add login page`. Attach a tasks.md to continue.\
        """)

        run

      {from, tasks} ->
        list =
          tasks
          |> Enum.take(12)
          |> Enum.map_join("\n", &"#{if &1.ref, do: &1.ref <> ".", else: "•"} #{&1.title}")

        more = if length(tasks) > 12, do: "\n…and #{length(tasks) - 12} more", else: ""

        say(run, "Found #{length(tasks)} #{plural(tasks, "task")} in #{from}:\n#{list}#{more}",
          actions: ["start"]
        )

        run
    end
  end

  defp command(run, "/" <> rest) do
    [name | args] = String.split(rest, ~r/\s+/, parts: 2)
    run_command(run, String.downcase(name), List.first(args, ""))
  end

  defp command(run, _text) do
    say(
      run,
      "Write to one of the agents, or type /help to see the commands. " <>
        "Attach a spec, or describe the change before the run starts, to plan its tasks."
    )
  end

  defp run_command(run, "help", _) do
    say(run, "Commands:\n" <> Enum.map_join(@commands, "\n", fn {c, d} -> "#{c}  #{d}" end))
  end

  defp run_command(%Run{tasks: []} = run, "run", _) do
    say(
      run,
      "There's nothing to run yet. Drop a tasks.md into the chat, or click the paperclip to attach one."
    )
  end

  defp run_command(%Run{status: "draft"} = run, "run", _) do
    queue(run, "draft")
  end

  defp run_command(run, "run", _),
    do: say(run, "This run is already #{run.status}. Use /status to see progress.")

  defp run_command(run, "status", _) do
    counts =
      run.tasks
      |> Enum.frequencies_by(& &1.status)
      |> Enum.map_join(", ", fn {s, n} -> "#{n} #{s}" end)

    tasks = if run.tasks == [], do: "no tasks yet", else: counts

    spec =
      if run.spec_files == [],
        do: "no spec attached",
        else: "spec: " <> Enum.join(run.spec_files, ", ")

    say(
      run,
      "Run is #{run.status}. #{String.capitalize(tasks)}. #{String.capitalize(spec)}." <>
        progress(run)
    )
  end

  defp run_command(%Run{tasks: []} = run, "tasks", _),
    do: say(run, "No tasks yet. Attach a tasks.md first.")

  defp run_command(run, "tasks", _) do
    say(
      run,
      Enum.map_join(run.tasks, "\n", &"#{&1.ref || &1.position}. #{&1.title} (#{&1.status})")
    )
  end

  defp run_command(%Run{status: s} = run, "pause", _) when s in ["queued", "running"] do
    {:ok, run} = Runs.update_run(run, %{status: "paused"})
    say(run, "Paused. Type /resume to continue.")
  end

  defp run_command(run, "pause", _),
    do: say(run, "Only a queued or running run can be paused. This one is #{run.status}.")

  defp run_command(%Run{status: "paused"} = run, "resume", _) do
    queue(run, "paused")
  end

  # "running" with no worker: the worker died without pausing the run.
  defp run_command(%Run{status: "running"} = run, "resume", _) do
    if Engine.running?(run.id),
      do: say(run, "This run is already running. Use /status to see progress."),
      else: queue(run, "running")
  end

  defp run_command(run, "resume", _),
    do: say(run, "Only a paused run can be resumed. This one is #{run.status}.")

  defp run_command(%Run{status: s} = run, "cancel", _) when s in ["done", "cancelled"] do
    say(run, "This run is already #{s}.")
  end

  defp run_command(run, "cancel", _) do
    {:ok, run} = Runs.update_run(run, %{status: "cancelled"})
    say(run, "Cancelled.")
  end

  defp run_command(run, "rename", ""),
    do: say(run, "Give the new name after the command, e.g. /rename Login page")

  defp run_command(run, "rename", title) do
    case Runs.update_run(run, %{title: title, settings: Map.put(run.settings, "title", "manual")}) do
      {:ok, run} -> say(run, "Renamed to “#{run.title}”.")
      {:error, _} -> say(run, "Names can be up to 80 characters.")
    end
  end

  defp run_command(run, "ask", args) do
    agents = agents(run)

    case match_agent(agents, args) do
      nil ->
        names = Enum.map_join(agents, ", ", & &1.name)

        say(
          run,
          "Name the agent first, e.g. /ask #{List.first(agents, %{name: "Coder"}).name} hello. Agents: #{names}"
        )

      {agent, ""} ->
        say(run, "What should I ask #{agent.name}? e.g. /ask #{agent.name} what can you do?")

      {agent, question} ->
        ask_agent(run, agent, question)
    end
  end

  # The agent named, else the one this chat is focused on.
  defp run_command(run, "compact", args) do
    agent =
      case match_agent(agents(run), args) do
        {agent, _} -> agent
        nil -> (id = Process.get(:chat_reply_agent)) && Agents.get_agent(id)
      end

    case agent && Kiro.compact(agent, run.id) do
      nil ->
        say(
          run,
          "Name the agent, e.g. /compact #{List.first(agents(run), %{name: "Coder"}).name}."
        )

      # The session notes what it kept in this chat.
      :ok ->
        :ok

      {:error, :no_gain} ->
        say(run, "#{agent.name}'s conversation is already small: compacting wouldn't save room.")

      {:error, :busy} ->
        say(run, "#{agent.name} is answering right now. Compact when it's idle.")

      {:error, :starting} ->
        say(run, "#{agent.name}'s Kiro session is still starting. Try again in a moment.")

      {:error, _} ->
        say(run, "Nothing to compact: #{agent.name} has no Kiro session running.")
    end
  end

  defp run_command(run, "workflow", _) do
    case agents(run) do
      [] ->
        say(run, "The workflow has no agents yet. Add them under Workflows.")

      agents ->
        say(
          run,
          "Agents in #{Factory.Workflows.for_run(run).name}:\n" <>
            Enum.map_join(agents, "\n", &agent_line/1)
        )
    end
  end

  defp run_command(run, name, _),
    do: say(run, "There's no /#{name} command. Type /help to see them.")

  defp queue(run, expected_status) do
    result =
      Runs.with_locked_run(run.id, fn run ->
        cond do
          run.status != expected_status ->
            {:error, "This run is already #{run.status}. Use /status to see progress."}

          expected_status == "running" and Engine.running?(run.id) ->
            {:error, "This run is already running. Use /status to see progress."}

          Engine.running?(run.id) ->
            {:error,
             "The previous worker is still finishing its step. Try /resume once it stops."}

          true ->
            with {:ok, steps} <- Engine.executable_steps(run) do
              attrs =
                if expected_status == "draft",
                  do: %{status: "queued", progress: %{}},
                  else: %{status: "queued"}

              {:ok, run} = Runs.update_run(run, attrs)
              {:ok, {run, steps}}
            end
        end
      end)

    case result do
      {:ok, {run, steps}} ->
        if expected_status == "draft" do
          order = "Following the workflow: " <> Enum.map_join(steps, " → ", & &1.name) <> "."
          say(run, "Queued #{length(run.tasks)} #{plural(run.tasks, "task")}. #{order}")
        else
          say(run, "Resumed.")
        end

        Engine.start(run)

      {:error, reason} ->
        say(run, reason)
    end
  end

  # Sends a question to an agent's Kiro session; its reply is posted by the session.
  defp ask_agent(run, agent, question) do
    tagged(agent, fn ->
      case Kiro.prompt(agent, run.id, question) do
        :ok ->
          :ok

        {:error, :busy} ->
          say(run, "#{agent.name} is still answering. Try again when it's idle.")

        {:error, reason} ->
          say(run, "Couldn't start Kiro for #{agent.name}: #{inspect(reason)}")
      end
    end)
  end

  defp agent_line(a), do: "• #{a.name}: #{a.model}, #{a.kiro_mode} mode"

  # The agents this run's chat talks to: its workflow's (see Factory.Workflows.for_run/1).
  # Action cards (commit, open a PR…) aren't agents to talk to.
  defp agents(run) do
    case Workflows.for_run(run) do
      nil ->
        []

      workflow ->
        workflow.id
        |> Agents.list_agents()
        |> Enum.reject(&Factory.Agents.Agent.action?/1)
    end
  end

  defp asked_agent(run, "/ask " <> rest) do
    case match_agent(agents(run), String.trim(rest)) do
      {agent, _question} -> agent
      nil -> nil
    end
  end

  defp asked_agent(_run, _text), do: nil

  # "/ask Agent 2 hello" -> the agent whose name the text starts with (longest name wins).
  defp match_agent(agents, text) do
    lower = String.downcase(text)

    agents
    |> Enum.filter(fn a ->
      name = String.downcase(a.name)
      lower == name or String.starts_with?(lower, name <> " ")
    end)
    |> Enum.max_by(&String.length(&1.name), fn -> nil end)
    |> case do
      nil -> nil
      agent -> {agent, text |> String.slice(String.length(agent.name)..-1//1) |> String.trim()}
    end
  end

  # Replies made while handling a message for one agent carry that agent's id,
  # so the agent's focused chat shows them. Scoped to the current call.
  defp tagged(nil, fun), do: fun.()

  defp tagged(agent, fun) do
    previous = Process.put(:chat_reply_agent, agent.id)

    try do
      fun.()
    after
      if previous,
        do: Process.put(:chat_reply_agent, previous),
        else: Process.delete(:chat_reply_agent)
    end
  end

  defp say(run, body, opts \\ []) do
    opts =
      case Process.get(:chat_reply_agent) do
        nil -> opts
        id -> Keyword.update(opts, :meta, %{"agent_id" => id}, &Map.put(&1, "agent_id", id))
      end

    Runs.post(run, "factory", body, opts)
  end

  # Where the engine is in the workflow (see Factory.Engine).
  defp progress(%Run{progress: %{"done" => done} = p} = run) do
    names = Map.new(Factory.Engine.steps(run), &{&1.id, &1.name})
    done = done |> Enum.map(&names[&1]) |> Enum.reject(&is_nil/1)
    now = names[p["current"]]

    [
      done != [] && " Done: #{Enum.join(done, ", ")}.",
      now && if(p["error"], do: " Stopped at #{now}: #{p["error"]}", else: " Now: #{now}.")
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  defp progress(_run), do: ""

  defp names(files), do: files |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
  defp plural([_], word), do: word
  defp plural(_, word), do: word <> "s"
end
