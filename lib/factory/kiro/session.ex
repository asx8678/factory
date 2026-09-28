defmodule Factory.Kiro.Session do
  @moduledoc """
  One Kiro session in its own `kiro-cli acp --agent-engine v3` process, spoken to
  over JSON-RPC on stdio (Agent Client Protocol).

  A session is either an agent's own, or the shared one: a single conversation
  that every agent set to "Shared session" takes part in. Either way, messages
  are handled one at a time in the order they arrive. Before each turn the
  session switches to the speaking agent's model and mode, and the first time an
  agent speaks its prompt (context) goes in front of its message. In the shared
  session every message is also labelled with the agent's name, so Kiro knows who
  is talking.

  Text streams to the run's chat as it arrives; a turn ends when Kiro answers the
  prompt request with a `stopReason`.

  Permission policy for now: every request to write files or run commands is
  denied and noted in the reply.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Factory.{Agents, Kiro, Runs}

  @doc "`key` is `:shared` or an agent id; `workdir` is the folder Kiro works in."
  def start_link({key, workdir}),
    do: GenServer.start_link(__MODULE__, {key, workdir}, name: via(key))

  defp via(key), do: {:via, Registry, {Factory.Kiro.Registry, key}}

  @doc "Queues a message from `agent`; the reply is posted to the run."
  def prompt(pid, agent, run_id, text), do: GenServer.call(pid, {:prompt, agent, run_id, text})

  @doc "Asks Kiro to compact (summarize) this session's context. Not while it is answering."
  def compact(pid), do: GenServer.call(pid, :compact)

  @doc "Sends the agent's prompt again before its next message (after it was edited)."
  def forget(pid, agent_id), do: GenServer.cast(pid, {:forget, agent_id})

  # State

  defstruct [
    :key,
    :workdir,
    :port,
    :session_id,
    :turn,
    :timer,
    # a job whose model/mode is being switched before its prompt is sent
    :switching,
    buffer: "",
    next_id: 1,
    pending: %{},
    queue: [],
    ready: false,
    # the session's current settings, e.g. %{"model" => "auto", "mode" => "vibe"}
    config: %{},
    # agents whose prompt (context) has been sent in this session
    primed: MapSet.new(),
    # agents that have used this session
    members: MapSet.new(),
    # latest context use in this session: %{pct:, window:}
    context: %{},
    # running totals per agent id, saved to the agent's usage after each turn
    usage: %{}
  ]

  # A message waiting to be sent: who, where the reply goes, what they said.
  defmodule Job do
    defstruct [:agent, :run_id, :text]
  end

  # A turn in progress: the job, what Kiro has said so far, tools it asked for.
  defmodule Turn do
    defstruct [:agent, :run_id, :started, input_tokens: 0, text: "", denied: [], credits: nil]
  end

  @impl true
  def init({key, workdir}) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{key: key, workdir: workdir}, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state) do
    File.mkdir_p!(Kiro.config(:log_dir))
    if state.workdir == Kiro.config(:workspace), do: File.mkdir_p!(state.workdir)

    cond do
      not File.dir?(state.workdir) ->
        fail(state, "The workspace folder #{state.workdir} doesn't exist.")

      not File.exists?(Kiro.config(:cli)) ->
        fail(state, "kiro-cli wasn't found at #{Kiro.config(:cli)}.")

      true ->
        log_name = if state.key == :shared, do: "shared.log", else: "agent-#{state.key}.log"
        port = Kiro.open_port(state.workdir, log_name)

        state = %{state | port: port}
        # Cards show whether a session is running.
        Agents.notify_changed()
        params = %{protocolVersion: 1, clientCapabilities: %{}}
        {:noreply, request(state, "initialize", params, :initialize)}
    end
  end

  @impl true
  def handle_call({:prompt, agent, run_id, text}, _from, state) do
    busy = not state.ready or state.turn != nil or state.switching != nil or state.queue != []

    if busy do
      Agents.set_activity(agent.id, "waiting", "Waiting for its turn")
    end

    job = %Job{agent: agent, run_id: run_id, text: text}
    {:reply, :ok, next(%{state | queue: state.queue ++ [job]})}
  end

  def handle_call(:compact, _from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :starting}, state}

      state.turn || state.switching || state.queue != [] ->
        {:reply, {:error, :busy}, state}

      true ->
        for id <- state.members, do: Agents.set_activity(id, "running", "Compacting context")

        {:reply, :ok,
         request(state, "_kiro/session/compact", %{sessionId: state.session_id}, :compact)}
    end
  end

  @impl true
  def handle_cast({:forget, agent_id}, state),
    do: {:noreply, %{state | primed: MapSet.delete(state.primed, agent_id)}}

  @impl true
  def handle_info({port, {:data, {:noeol, part}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> part}}
  end

  def handle_info({port, {:data, {:eol, part}}}, %{port: port} = state) do
    line = state.buffer <> part
    state = %{state | buffer: ""}

    with {:ok, msg} <- JSON.decode(line),
         {:fail, reason, state} <- handle_message(msg, state) do
      fail(state, reason)
    else
      {:error, _not_json} -> {:noreply, state}
      %__MODULE__{} = state -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    fail(
      %{state | port: nil},
      "Kiro stopped unexpectedly (exit code #{code}). Details are in tmp/kiro-logs."
    )
  end

  def handle_info(:turn_timeout, %{turn: %Turn{}} = state) do
    notify(state, "session/cancel", %{sessionId: state.session_id})
    minutes = div(Kiro.config(:prompt_timeout), 60_000)

    {:noreply,
     state |> finish_turn("Stopped after waiting #{minutes} minutes for Kiro.") |> next()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if state.port, do: Port.close(state.port)
    Agents.notify_changed()

    # Stopped on purpose (settings changed, Stop Kiro): agents go back to idle and lose
    # the session's context; turns and credits stay. After a failure, keep "error".
    if reason in [:shutdown] or match?({:shutdown, _}, reason) do
      for id <- state.members, agent = Agents.get_agent(id) do
        Agents.set_activity(id, "idle", nil)
        Agents.record_usage(id, Map.drop(agent.usage, ["context_pct", "context_tokens"]))
      end
    end
  catch
    _, _ -> :ok
  end

  # JSON-RPC messages from Kiro. Each returns the new state, or {:fail, reason, state} to stop.

  # A response to one of our requests
  defp handle_message(%{"id" => id} = msg, state) when not is_map_key(msg, "method") do
    {kind, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case {kind, msg} do
      {_, %{"error" => error}} ->
        error_response(kind, error, state)

      {:initialize, _} ->
        request(state, "session/new", %{cwd: state.workdir, mcpServers: []}, :new_session)

      {:new_session, %{"result" => %{"sessionId" => sid} = result}} ->
        next(%{
          state
          | session_id: sid,
            config: current_values(result["configOptions"]),
            ready: true
        })

      {{:config, id, value, rest}, %{"result" => result}} ->
        # Kiro answers with its settings. It's a refusal only if it reports a different
        # value; a missing value (e.g. model list still loading) isn't one.
        case current_values(result["configOptions"])[id] do
          reported when reported in [nil, value] ->
            switch(%{state | config: Map.put(state.config, id, value)}, rest)

          reported ->
            state
            |> reject_switch("Kiro didn't accept #{id} #{value} (it reports #{reported}).")
            |> next()
        end

      {:compact, %{"result" => _}} ->
        next(compacted(state))

      {:prompt, %{"result" => result}} ->
        state |> finish_turn(nil, result["stopReason"]) |> next()

      _ ->
        state
    end
  end

  # A request from Kiro that needs an answer
  defp handle_message(
         %{"id" => id, "method" => "session/request_permission", "params" => params},
         state
       ) do
    options = params["options"] || []

    # Reading and searching are allowed (the project and the workflow's data sources);
    # writing files and running commands aren't yet.
    if get_in(params, ["toolCall", "kind"]) in ["read", "search"] do
      allow =
        Enum.find(options, &String.starts_with?(&1["kind"] || "", "allow")) ||
          List.first(options)

      reply(state, id, %{outcome: %{outcome: "selected", optionId: allow["optionId"]}})
      state
    else
      reject =
        Enum.find(options, &String.starts_with?(&1["kind"] || "", "reject")) ||
          List.first(options)

      title = get_in(params, ["toolCall", "title"]) || "a tool"
      reply(state, id, %{outcome: %{outcome: "selected", optionId: reject["optionId"]}})

      update_turn(state, fn turn -> %{turn | denied: turn.denied ++ [title]} end)
    end
  end

  defp handle_message(%{"id" => id, "method" => method}, state) do
    reply_error(state, id, -32601, "#{method} is not supported by Factory")
    state
  end

  # Notifications
  defp handle_message(%{"method" => "session/update", "params" => %{"update" => update}}, state) do
    case update do
      %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      } ->
        state = update_turn(state, fn turn -> %{turn | text: turn.text <> text} end)
        if state.turn, do: stream(state)
        state

      %{"sessionUpdate" => "tool_call", "title" => title} ->
        if state.turn, do: Agents.set_activity(state.turn.agent.id, "running", "Using #{title}")
        state

      %{"_meta" => %{"kiro" => %{"contextUsage" => %{"usagePercentage" => pct}} = kiro}} ->
        %{state | context: read_context(state.context, pct, kiro["breakdown"])}

      %{"_meta" => %{"kiro" => %{"promptTurnSummaries" => summaries}}} ->
        credits = summaries |> Enum.map(&(&1["usage"] || 0)) |> Enum.sum()
        update_turn(state, fn turn -> %{turn | credits: credits} end)

      _ ->
        state
    end
  end

  defp handle_message(_msg, state), do: state

  defp error_response(:prompt, error, state),
    do: state |> finish_turn("Kiro returned an error: #{error["message"]}") |> next()

  defp error_response({:config, id, value, _rest}, error, state) do
    state
    |> reject_switch("Kiro couldn't set #{id} to #{value}: #{error["message"]}")
    |> next()
  end

  defp error_response(:compact, error, state) do
    for id <- state.members,
        do: Agents.set_activity(id, "error", "Couldn't compact: #{error["message"]}")

    next(state)
  end

  defp error_response(kind, error, state) when kind in [:initialize, :new_session] do
    {:fail, "Kiro couldn't start a session: #{error["message"]}", state}
  end

  defp error_response(_kind, _error, state), do: state

  # Kiro only reports the smaller context with the next turn. Until then each agent shows
  # "Context compacted" and remembers the size it had, so the next reply can show both.
  defp compacted(state) do
    before = state.context[:pct]

    usage =
      Map.new(state.usage, fn {id, u} ->
        u =
          u
          |> Map.drop(["context_pct", "context_tokens"])
          |> then(
            &if before, do: Map.put(&1, "compacted_from", Float.round(before / 1, 1)), else: &1
          )

        Agents.record_usage(id, u)
        {id, u}
      end)

    for id <- state.members, do: Agents.set_activity(id, "done", "Context compacted")
    %{state | usage: usage, context: Map.delete(state.context, :pct)}
  end

  defp current_values(options) when is_list(options),
    do: Map.new(options, &{&1["id"], &1["currentValue"]})

  defp current_values(_), do: %{}

  # The queue: one job at a time, after switching to its agent's model and mode.

  defp next(%{ready: true, turn: nil, switching: nil, queue: [job | rest]} = state) do
    wanted =
      Enum.reject(
        [{"model", job.agent.model}, {"mode", job.agent.kiro_mode}],
        fn {id, value} -> state.config[id] == value end
      )

    switch(%{state | queue: rest, switching: job}, wanted)
  end

  defp next(state), do: state

  defp switch(state, []) do
    job = state.switching
    send_prompt(%{state | switching: nil}, job)
  end

  defp switch(state, [{id, value} | rest]) do
    params = %{sessionId: state.session_id, configId: id, value: value}
    request(state, "session/set_config_option", params, {:config, id, value, rest})
  end

  # Kiro refused the model or mode for this job: tell its chat, drop the job, carry on.
  defp reject_switch(%{switching: %Job{} = job} = state, reason) do
    Agents.set_activity(job.agent.id, "error", reason)

    if run = Runs.get_run(job.run_id) do
      Runs.post(run, "factory", "#{job.agent.name} couldn't start: #{reason}",
        meta: %{"agent_id" => job.agent.id}
      )
    end

    %{state | switching: nil}
  end

  defp reject_switch(state, _reason), do: state

  defp send_prompt(state, %Job{agent: agent} = job) do
    {text, state} = with_context(state, agent, job.text)
    Agents.set_activity(agent.id, "running", "Answering: " <> String.slice(job.text, 0, 60))
    timer = Process.send_after(self(), :turn_timeout, Kiro.config(:prompt_timeout))

    turn = %Turn{
      agent: agent,
      run_id: job.run_id,
      started: System.monotonic_time(:millisecond),
      input_tokens: Factory.Usage.estimate_tokens(text)
    }

    state = %{
      state
      | turn: turn,
        timer: timer,
        members: MapSet.put(state.members, agent.id),
        usage: Map.put_new(state.usage, agent.id, fresh_usage(agent))
    }

    params = %{sessionId: state.session_id, prompt: [%{type: "text", text: text}]}
    request(state, "session/prompt", params, :prompt)
  end

  # An agent's usage starts from its saved totals, without context from an earlier session.
  defp fresh_usage(agent), do: Map.drop(agent.usage || %{}, ["context_pct", "context_tokens"])

  # The agent's prompt goes in front of its first message in this session; the session
  # keeps it for the rest of the conversation. In the shared session every message is
  # labelled with who is speaking.
  defp with_context(state, agent, text) do
    # The data sources attached to the agent, then its own prompt.
    context =
      [Factory.Sources.context_for_agent(agent), String.trim(agent.prompt || "")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    first = not MapSet.member?(state.primed, agent.id)
    state = %{state | primed: MapSet.put(state.primed, agent.id)}

    text =
      case {state.key, first and context != ""} do
        {:shared, true} ->
          ~s(<context agent="#{agent.name}">\n#{context}\n</context>\n\n[#{agent.name}] #{text})

        {:shared, false} ->
          "[#{agent.name}] #{text}"

        {_own, true} ->
          "<context>\n#{context}\n</context>\n\n#{text}"

        {_own, false} ->
          text
      end

    {text, state}
  end

  defp finish_turn(state, error, stop_reason \\ nil)
  defp finish_turn(%{turn: nil} = state, _error, _stop_reason), do: state

  defp finish_turn(%{turn: turn} = state, error, stop_reason) do
    if state.timer, do: Process.cancel_timer(state.timer)
    agent = turn.agent

    denied =
      Enum.map_join(
        turn.denied,
        "",
        &"\n(Denied: #{&1}. Agents can't write files or run commands yet.)"
      )

    text =
      if turn.text == "", do: error || "(Kiro ended the turn without a reply.)", else: turn.text

    context = context_fields(state.context)

    meta =
      Map.merge(context, %{
        "agent_id" => agent.id,
        "stop_reason" => stop_reason,
        "credits" => turn.credits,
        "ms" => System.monotonic_time(:millisecond) - turn.started,
        "session" => if(state.key == :shared, do: "shared", else: "own")
      })

    compacted_from = get_in(state.usage, [agent.id, "compacted_from"])
    meta = if compacted_from, do: Map.put(meta, "compacted_from", compacted_from), else: meta
    state = save_usage(state, agent.id, turn.credits || 0, context)

    Factory.Usage.record(%{
      source: "agent_turn",
      run_id: turn.run_id,
      agent_id: agent.id,
      model: state.config["model"],
      credits: turn.credits || 0,
      input_tokens: turn.input_tokens,
      output_tokens: Factory.Usage.estimate_tokens(turn.text),
      ms: meta["ms"],
      ok: is_nil(error)
    })

    # Mark the agent first, so anyone reacting to the chat message sees the new status.
    Agents.set_activity(agent.id, if(error, do: "error", else: "idle"), error)

    if run = Runs.get_run(turn.run_id) do
      Runs.post(run, "factory", text <> denied, author: agent.name, meta: meta)
    end

    %{state | turn: nil, timer: nil}
  end

  # Kiro reports how full the context is as a percentage, plus a token breakdown by
  # source (rules files, tools, prompts, replies). It doesn't state the window size,
  # so estimate it from the largest source: tokens / its percentage.
  defp read_context(context, pct, breakdown) do
    estimate =
      (breakdown || %{})
      |> Map.values()
      |> Enum.filter(&(is_map(&1) and is_number(&1["tokens"]) and is_number(&1["percent"])))
      |> Enum.filter(&(&1["tokens"] >= 500 and &1["percent"] >= 0.3))
      |> Enum.max_by(& &1["tokens"], fn -> nil end)

    window =
      if estimate,
        do: round_window(estimate["tokens"] * 100 / estimate["percent"]),
        else: context[:window]

    %{pct: pct, window: window}
  end

  # To two significant figures: 966_000 -> 970_000, 1_080_000 -> 1_100_000.
  defp round_window(n) do
    magnitude = :math.pow(10, max(trunc(:math.log10(n)) - 1, 0))
    round(Float.round(n / magnitude) * magnitude)
  end

  defp context_fields(%{pct: pct} = context) do
    tokens = if context[:window], do: round(context.window * pct / 100)

    %{
      "context_pct" => Float.round(pct / 1, 1),
      "window" => context[:window],
      "context_tokens" => tokens
    }
  end

  defp context_fields(_), do: %{}

  # Totals across all of the agent's sessions; context is this session's.
  defp save_usage(state, agent_id, credits, context) do
    usage =
      state.usage
      |> Map.get(agent_id, %{})
      |> Map.update("turns", 1, &(&1 + 1))
      |> Map.update("credits", credits, &(&1 + credits))
      |> Map.delete("compacted_from")
      |> Map.merge(context)

    Agents.record_usage(agent_id, usage)
    %{state | usage: Map.put(state.usage, agent_id, usage)}
  end

  defp update_turn(%{turn: nil} = state, _fun), do: state
  defp update_turn(state, fun), do: %{state | turn: fun.(state.turn)}

  defp stream(%{turn: turn}) do
    Phoenix.PubSub.broadcast(
      Factory.PubSub,
      "run:#{turn.run_id}",
      {:agent_stream, %{agent_id: turn.agent.id, name: turn.agent.name, text: turn.text}}
    )
  end

  # The Kiro process is gone or unusable: answer every waiting message and stop.
  defp fail(state, reason) do
    Logger.warning("Kiro session #{inspect(state.key)} failed: #{reason}")
    state = finish_turn(state, reason)

    waiting = if state.switching, do: [state.switching | state.queue], else: state.queue

    for %Job{agent: agent, run_id: run_id} <- waiting do
      Agents.set_activity(agent.id, "error", reason)

      if run = Runs.get_run(run_id) do
        Runs.post(run, "factory", "#{agent.name} couldn't start: #{reason}",
          meta: %{"agent_id" => agent.id}
        )
      end
    end

    {:stop, :normal, %{state | queue: [], switching: nil}}
  end

  # JSON-RPC out

  defp request(state, method, params, kind) do
    send_json(state, %{jsonrpc: "2.0", id: state.next_id, method: method, params: params})
    %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, state.next_id, kind)}
  end

  defp notify(state, method, params),
    do: send_json(state, %{jsonrpc: "2.0", method: method, params: params})

  defp reply(state, id, result), do: send_json(state, %{jsonrpc: "2.0", id: id, result: result})

  defp reply_error(state, id, code, message),
    do: send_json(state, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp send_json(%{port: nil}, _msg), do: :ok
  defp send_json(%{port: port}, msg), do: Port.command(port, [JSON.encode!(msg), "\n"])
end
