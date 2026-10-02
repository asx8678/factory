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
    {"/run", "Start the run, or run a finished one again for tasks added since"},
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

  Returns `:ok`, or `{:error, :gone}` when the run no longer exists (pruned while the
  chat was open, or deleted): nothing is posted then.
  """
  def handle(%Run{} = run, text, files \\ [], opts \\ []) do
    case Runs.get_run(run.id) do
      nil -> {:error, :gone}
      run -> handle_message(run, text, files, opts)
    end
  end

  defp handle_message(run, text, files, opts) do
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
          run = keep(run, files, &Factory.ChatPlanner.keep_files/2)
          Factory.ChatPlanner.start(run, planner)

        true ->
          run = keep(run, files, &attach/2)

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

  @doc """
  Runs a button action shown under a factory message: `:ok`, or `{:error, :gone}` when
  the run no longer exists.
  """
  def action(%Run{} = run, "start"), do: act(run, "/run")
  # Under a run paused at its credit limit (`Factory.Engine.credit_limit/0`).
  def action(%Run{} = run, "continue"), do: act(run, "/resume")

  defp act(run, text) do
    case Runs.get_run(run.id) do
      nil ->
        {:error, :gone}

      run ->
        command(run, text)
        :ok
    end
  end

  @doc """
  Fix it, under a finished troubleshooting run: a new chat on the Fix a bug workflow,
  in the same repository, asked to fix what the report found. With a repository its
  planner starts on it; without one, the chat says to choose the project folder first.
  Returns `{:ok, run}` with the new chat's run.
  """
  def fix_it(%Run{} = run) do
    run = Runs.get_run(run.id)
    report = report(run)
    dir = String.trim(run.settings["project_dir"] || "")
    # Made with its settings in one go: a chat without its workflow would plan nothing.
    bug = Workflows.standard("bug")

    {:ok, fix} =
      Runs.transact(fn ->
        with {:ok, fix} <- Runs.create_run("Fix: " <> run.title) do
          Runs.update_run(fix, %{
            settings: %{
              "workflow_id" => bug.id,
              "base_spec_ids" => bug.base_spec_ids,
              "project_dir" => if(dir == "", do: nil, else: dir)
            }
          })
        end
      end)

    request = "Fix this, following the troubleshooting report below.\n\n" <> report

    if dir == "" do
      Runs.post(fix, "user", request)

      say(
        fix,
        "Choose the project folder above, where the code to fix is, then send a message " <>
          "(\"plan it\") and the planner plans the fix from the report."
      )
    else
      handle(fix, request)
    end

    {:ok, Runs.get_run(fix.id)}
  end

  # The troubleshooting report: what the workflow's last step handed over, or, when the
  # workflow's agents were made again since the run, what the agent of that name wrote
  # last in it.
  defp report(run) do
    last = run |> Engine.steps() |> Enum.reject(&(&1.kind == "action")) |> List.last()

    (last && (run.progress["outputs"][last.id] || last_reply(run, last.name))) ||
      run.description || run.title
  end

  defp last_reply(run, author) do
    run.id
    |> Runs.list_messages(author: author, newest_first: true, limit: 50)
    |> Enum.find_value(fn m ->
      m.author == author and not Map.has_key?(m.meta || %{}, "elicitation") and m.body
    end)
  end

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
  # Files dropped into a troubleshooting chat are evidence (logs, exports), kept whole
  # for the agents to search (`Factory.Evidence`); elsewhere they go into the spec.
  defp keep(run, [], _into_spec), do: run

  defp keep(run, files, into_spec) do
    workflow = Workflows.for_run(run)

    if workflow && Workflows.kind(workflow) == "incident" do
      names = Factory.Evidence.save(run, files)

      # The user names they show, learned once for what the agents that search the web
      # are given (`Factory.Engine`), rather than from the files for each prompt. In the
      # background: reading 100 MB of logs takes seconds the chat shouldn't wait, and
      # until it's done the engine learns them from the files' starts itself.
      learn_users(run.id, Enum.map(files, &elem(&1, 1)))
      run = Runs.get_run(run.id)

      say(
        run,
        "Kept #{Enum.join(names, ", ")} for the agents to search, whole, however big."
      )

      run
    else
      into_spec.(run, files)
    end
  end

  defp learn_users(run_id, texts) do
    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      users = Factory.Redact.users_in(texts)

      Runs.with_locked_run(run_id, fn run ->
        Runs.update_run(run, %{
          settings:
            Map.update(run.settings || %{}, "evidence_users", users, &Enum.uniq(&1 ++ users))
        })
      end)
    end)
  end

  defp attach(run, files) do
    with {:ok, spec} <- Specs.ensure_for_run(run),
         {:ok, _spec} <- Specs.add_files(spec, files) do
      report(Runs.get_run(run.id) || run, files)
    else
      {:error, _} ->
        say(run, "I couldn't store #{names(files)}. Try attaching it again.")
        run
    end
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

  # Tasks added after the run finished: it runs again, for the ones still open.
  defp run_command(%Run{status: "done"} = run, "run", _) do
    if Enum.any?(run.tasks, &(&1.status != "done")),
      do: queue(run, "done"),
      else:
        say(run, "Every task of this run is done. Add tasks first, e.g. by asking the planner.")
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

  # Under the row lock: the run may have finished since it was read.
  defp run_command(%Run{status: s} = run, "pause", _) when s in ["queued", "running"] do
    {:ok, run} =
      Runs.with_locked_run(run.id, fn run ->
        if run.status in ["queued", "running"],
          do: Runs.update_run(run, %{status: "paused"}),
          else: {:ok, run}
      end)

    if run.status == "paused",
      do: say(run, "Paused. Type /resume to continue."),
      else: say(run, "Only a queued or running run can be paused. This one is #{run.status}.")
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

  # Under the row lock, as it may have finished meanwhile. Then the agent at work stops
  # too: its turn would otherwise go on changing files until it ends, and the run, no
  # longer running, isn't paused by its failing (`Factory.Engine`).
  defp run_command(run, "cancel", _) do
    {:ok, run} =
      Runs.with_locked_run(run.id, fn run ->
        if run.status in ["done", "cancelled"],
          do: {:ok, run},
          else: Runs.update_run(run, %{status: "cancelled"})
      end)

    if run.status == "cancelled" do
      Kiro.cancel_run(run.id)
      say(run, "Cancelled.")
    else
      say(run, "This run is already #{run.status}.")
    end
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
              # From the start: a new run, or one run again for tasks added after it.
              # A paused one goes on from where it stopped, without the error that
              # paused it (a failed step, or a restart: `Engine.recover/0`).
              progress = Map.delete(run.progress || %{}, "error")

              attrs =
                if expected_status in ["draft", "done"],
                  do: %{status: "queued", progress: %{}},
                  else: %{status: "queued", progress: progress}

              with {:ok, run} <- Runs.update_run(run, attrs), do: {:ok, {run, steps}}
            end
        end
      end)

    case result do
      {:ok, {run, steps}} ->
        order = "Following the workflow: " <> Enum.map_join(steps, " → ", & &1.name) <> "."

        case expected_status do
          "draft" ->
            say(run, "Queued #{length(run.tasks)} #{plural(run.tasks, "task")}. #{order}")

          "done" ->
            open = Enum.reject(run.tasks, &(&1.status == "done"))
            say(run, "Running again for #{length(open)} open #{plural(open, "task")}. #{order}")

          _ ->
            say(run, "Resumed.")
        end

        Engine.start(run)

      {:error, reason} when is_binary(reason) ->
        say(run, reason)

      {:error, _} ->
        say(run, "Factory couldn't start the run. Try again.")
    end
  end

  # Sends a question to an agent's Kiro session; its reply is posted by the session.
  # The run's planner is reminded that the plan changes only through its tools.
  defp ask_agent(run, agent, question) do
    text =
      case planner_for(run) do
        %{id: id} when id == agent.id ->
          question <>
            "\n\n(You plan this run. If this asks for tasks to be added or changed, change the " <>
            "plan with the factory tools: get_plan to see it, then add_tasks, update_task or " <>
            "remove_tasks. Writing a plan in your reply doesn't change it.)"

        _ ->
          question
      end

    prompt_agent(run, agent, text)
  end

  defp prompt_agent(run, agent, text) do
    tagged(agent, fn ->
      case Kiro.prompt(agent, run.id, text) do
        {:ok, _ref} ->
          :ok

        {:error, :busy} ->
          say(run, "#{agent.name} is still answering. Try again when it's idle.")

        {:error, reason} ->
          say(run, "Couldn't start Kiro for #{agent.name}: #{reason_text(reason)}")
      end
    end)
  end

  @doc """
  The Try again under a failure (`Factory.ChatPlanner`, `Factory.Kiro.Session`): what
  Kiro couldn't take goes again, once whatever stopped it is fixed (signed out, say).
  The plan is planned again the same way; a message goes to its agent again. Once per
  failure: the button goes when it's used.
  """
  def retry(%Run{} = run, %{meta: %{"retry" => %{} = retry}} = message) do
    if message.run_id == run.id and "retry" in message.actions and !message.meta["retried"] do
      Runs.update_message_meta(message.id, &Map.put(&1, "retried", true))

      case retry do
        %{"kind" => "plan"} ->
          case planner_for(run) do
            nil -> say(run, "This chat has no planner to plan it.")
            planner -> Factory.ChatPlanner.start(run, planner, plan_again(retry["action"]))
          end

        %{"kind" => "ask", "agent_id" => id, "text" => text} when is_binary(text) ->
          case Agents.get_agent(id) do
            nil -> say(run, "That agent is gone, so there's nobody to send it to.")
            agent -> prompt_agent(run, agent, text)
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  def retry(_run, _message), do: :ok

  defp plan_again("scope"), do: [action: :scope]
  defp plan_again("grill"), do: [action: :grill]
  defp plan_again("refine"), do: [action: :refine]
  defp plan_again(_), do: []

  # Reasons come as sentences; anything else as Elixir writes it.
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

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
      stopped(now, p["error"])
    ]
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  # A run paused before it started (Factory restarted while it was queued).
  defp progress(%Run{progress: %{"error" => error}}) when is_binary(error),
    do: stopped(nil, error)

  defp progress(_run), do: ""

  defp stopped(nil, nil), do: nil
  defp stopped(nil, error), do: " Stopped: #{error}"
  defp stopped(now, nil), do: " Now: #{now}."
  defp stopped(now, error), do: " Stopped at #{now}: #{error}"

  defp names(files), do: files |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
  defp plural([_], word), do: word
  defp plural(_, word), do: word <> "s"
end
