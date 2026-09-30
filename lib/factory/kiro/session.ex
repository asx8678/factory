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

  Run steps come here too (`Factory.Kiro.run_step/4`): a job can name who waits for
  its reply and the run step it's for. Every session gets Factory's MCP server with a
  token for the session, so the agent can use the run tools (`Factory.RunTools`)
  while it answers a run step; MCP permission requests are allowed by server name.

  Text streams to the run's chat as it arrives; a turn ends when Kiro answers the
  prompt request with a `stopReason`. Other RPCs have a 30-second deadline, configurable
  as `:rpc_timeout` in the `:kiro` settings; a timeout fails all waiting jobs.

  Permissions: when Kiro asks to use a tool, the answering agent's kind decides
  (`Factory.Agents.Agent.tools/1`, the same as in a run). A denied request is noted
  in the reply.

  Context: the session keeps a bounded log of recent turns (the message, the tools
  Kiro used and how they went, the reply or error). When Kiro reports the context at
  `Factory.Context.config(:compact_at)` percent or more, before the next message, or
  when asked (`compact/1`), the log is compacted by `Factory.Context.compact/2` (fixed
  rules, no model) and Kiro starts a fresh session with that in front of the next
  message. Agents' prompts go again with their next message. A note in the chat says
  what was kept (see `notice/3`).
  """
  use GenServer, restart: :temporary
  require Logger
  alias Factory.{Agents, Kiro, Runs}
  alias Factory.Agents.Agent

  @doc "`key` is `:shared` or an agent id; `workdir` is the folder Kiro works in."
  def start_link({key, workdir}),
    do: GenServer.start_link(__MODULE__, {key, workdir}, name: via(key, workdir))

  # Registered with the folder it works in, so `Factory.Kiro` can tell which one.
  defp via(key, workdir), do: {:via, Registry, {Factory.Kiro.Registry, key, workdir}}

  @doc "Whether the session is ready with nothing to answer."
  def idle?(pid), do: GenServer.call(pid, :idle?)

  @doc """
  Queues a message from `agent`; the reply is posted to the run. Options, for a run
  step (`Factory.Kiro.run_step/4`):

    * `:reply_to` - `{pid, ref}` that gets `{ref, {:ok, reply} | {:error, reason}}` when
      the job ends, however it ends
    * `:source` - what the call is recorded as in `Factory.Usage` (default "agent_turn")
    * `:model` - the model for this job instead of the agent's
    * `:context` - false when the text already carries the agent's sources and prompt
    * `:activity` - what the agent's card says while it works
    * `:step` - `%{id:, tasks:, verdict:}`, the run step Factory's run tools act on
  """
  def prompt(pid, agent, run_id, text, opts \\ []),
    do: GenServer.call(pid, {:prompt, agent, run_id, text, opts})

  @doc "The run step the session is answering, for `Factory.RunTools`: `%{run_id:, step:}` or nil."
  def current_step(pid), do: GenServer.call(pid, :current_step)

  @doc """
  What the session is answering, for Factory's tools: `%{run_id:, agent:, step:}` (step
  nil for a chat message), or nil between turns.
  """
  def current_turn(pid), do: GenServer.call(pid, :current_turn)

  @doc """
  Compacts this session's conversation now (see the moduledoc). Not while it is
  answering. `{:error, :no_gain}` when the result wouldn't be smaller. The note goes to
  the chat `run_id`, else to the chat of the last turn.
  """
  def compact(pid, run_id \\ nil), do: GenServer.call(pid, {:compact, run_id})

  @doc "Sends the agent's prompt again before its next message (after it was edited)."
  def forget(pid, agent_id), do: GenServer.cast(pid, {:forget, agent_id})

  # State

  defstruct [
    :key,
    :workdir,
    :port,
    :session_id,
    :turn,
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
    usage: %{},
    # recent turns, newest first, as `Factory.Context.Projections` describes events
    log: [],
    log_dropped: 0,
    seq: 0,
    # the compacted conversation, to go in front of the next message
    carry: nil,
    # the chat of the latest turn, where a compaction is noted when no other is given
    last_run: nil
  ]

  # A message waiting to be sent: who, where the reply goes, what they said.
  defmodule Job do
    defstruct [
      :agent,
      :run_id,
      :text,
      :reply_to,
      :model,
      :activity,
      :step,
      source: "agent_turn",
      context: true
    ]
  end

  # A turn in progress: the job, what Kiro has said so far, tools it asked for.
  defmodule Turn do
    defstruct [
      :agent,
      :run_id,
      :started,
      :ask,
      :request_id,
      :reply_to,
      :step,
      source: "agent_turn",
      input_tokens: 0,
      text: "",
      denied: [],
      credits: nil,
      # tools Kiro used, in order: %{call_id:, tool:, title:, paths:, outcome:}
      tools: []
    ]
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
        # Cards show whether a session is running.
        Agents.notify_changed()
        {:noreply, open(state)}
    end
  end

  # Starts kiro-cli and opens a Kiro session in it (answered in handle_message/2).
  defp open(state) do
    log_name = if state.key == :shared, do: "shared.log", else: "agent-#{state.key}.log"
    port = Kiro.open_port(state.workdir, log_name)
    params = %{protocolVersion: 1, clientCapabilities: %{}}
    request(%{state | port: port}, "initialize", params, :initialize)
  end

  @impl true
  def handle_call({:prompt, agent, run_id, text, opts}, _from, state) do
    if Kiro.workdir(Runs.get_run(run_id)) != state.workdir do
      {:reply, {:error, :busy}, state}
    else
      busy = not state.ready or state.turn != nil or state.switching != nil or state.queue != []

      if busy do
        Agents.set_activity(agent.id, "waiting", "Waiting for its turn")
      end

      job = %Job{
        agent: agent,
        run_id: run_id,
        text: text,
        reply_to: opts[:reply_to],
        model: opts[:model],
        activity: opts[:activity],
        step: opts[:step],
        source: opts[:source] || "agent_turn",
        context: Keyword.get(opts, :context, true)
      }

      {:reply, :ok, next(%{state | queue: state.queue ++ [job]})}
    end
  end

  def handle_call(:current_step, _from, %{turn: %Turn{step: %{} = step} = turn} = state),
    do: {:reply, %{run_id: turn.run_id, step: step}, state}

  def handle_call(:current_step, _from, state), do: {:reply, nil, state}

  def handle_call(:current_turn, _from, %{turn: %Turn{} = turn} = state),
    do: {:reply, %{run_id: turn.run_id, agent: turn.agent, step: turn.step}, state}

  def handle_call(:current_turn, _from, state), do: {:reply, nil, state}

  def handle_call(:idle?, _from, state),
    do:
      {:reply, state.ready and state.turn == nil and state.switching == nil and state.queue == [],
       state}

  def handle_call({:compact, run_id}, _from, state) do
    cond do
      not state.ready ->
        {:reply, {:error, :starting}, state}

      state.turn || state.switching || state.queue != [] ->
        {:reply, {:error, :busy}, state}

      true ->
        case compact_now(state, run_id || state.last_run, :manual) do
          {:ok, state} -> {:reply, :ok, state}
          error -> {:reply, error, state}
        end
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

  def handle_info({:request_timeout, id}, state) do
    case state.pending[id] do
      %{kind: {:prompt, ^id}} when state.turn != nil and state.turn.request_id == id ->
        notify(state, "session/cancel", %{sessionId: state.session_id})
        minutes = div(Kiro.config(:prompt_timeout), 60_000)
        state = finish_turn(state, "Stopped after waiting #{minutes} minutes for Kiro.")

        carry =
          case Factory.Context.compact(Enum.reverse(state.log),
                 omitted_entries: state.log_dropped
               ) do
            {:ok, c} -> c.text
            _ -> nil
          end

        # ACP chunks have no prompt id. Close the old transport before another turn
        # starts, so even an uncooperative cancellation cannot leak into that turn.
        {:noreply, restart(%{state | carry: carry, context: %{}})}

      %{method: method} ->
        fail(state, "Kiro didn't answer #{method} before its deadline.")

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_requests(state)
    close_port(state.port)
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
    {request, pending} = Map.pop(state.pending, id)
    if request, do: Process.cancel_timer(request.timer)
    kind = request && request.kind
    state = %{state | pending: pending}

    case {kind, msg} do
      {_, %{"error" => error}} ->
        error_response(kind, error, state)

      {:initialize, %{"result" => _}} ->
        request(
          state,
          "session/new",
          %{cwd: state.workdir, mcpServers: mcp_servers(state)},
          :new_session
        )

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

      {{:prompt, ^id}, %{"result" => result}}
      when state.turn != nil and state.turn.request_id == id ->
        state |> finish_turn(nil, result["stopReason"]) |> next()

      {nil, _} ->
        state

      _ ->
        {:fail, "Kiro returned an invalid response.", state}
    end
  end

  # A request from Kiro that needs an answer
  defp handle_message(
         %{"id" => id, "method" => "session/request_permission", "params" => params},
         state
       ) do
    options = params["options"] || []

    # What the answering agent may do (Factory.Agents.Agent.tools/1), as in a run:
    # the ones that only look read and search; the rest may also edit and run commands.
    # Factory's own tools come over MCP, whose requests name their server and carry no
    # kind; they check for themselves what the current step may do (`Factory.RunTools`).
    allowed = if state.turn, do: Agent.tools(state.turn.agent), else: []
    server = get_in(params, ["_meta", "kiro", "mcpTool", "identity", "serverName"])

    # Kiro 2.26 gives the kind on the tool call, not the request (`Kiro.Permission`).
    known =
      if state.turn,
        do:
          for(
            t <- state.turn.tools,
            t.call_id && t.tool != "other",
            into: %{},
            do: {t.call_id, t.tool}
          ),
        else: %{}

    wanted =
      if Kiro.Permission.kind(params, known) in allowed or
           (state.turn != nil and server == Factory.PlanTools.server_name()),
         do: "allow",
         else: "reject"

    outcome = Kiro.Permission.outcome(options, wanted)
    reply(state, id, %{outcome: outcome})

    if wanted == "allow" and outcome.outcome == "selected" do
      state
    else
      title = get_in(params, ["toolCall", "title"]) || "a tool"

      state
      |> update_turn(fn turn -> %{turn | denied: turn.denied ++ [title]} end)
      |> track_tool(Map.put(params["toolCall"] || %{}, "status", "denied"))
    end
  end

  defp handle_message(%{"id" => id, "method" => method}, state) do
    reply_error(state, id, -32601, "#{method} is not supported by Factory")
    state
  end

  # Notifications
  defp handle_message(
         %{"method" => "session/update", "params" => %{"sessionId" => sid}},
         %{session_id: current} = state
       )
       when sid != current,
       do: state

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
        track_tool(state, update)

      %{"sessionUpdate" => "tool_call_update"} ->
        track_tool(state, update)

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

  defp error_response({:prompt, id}, error, %{turn: %Turn{request_id: id}} = state),
    do: state |> finish_turn("Kiro returned an error: #{error["message"]}") |> next()

  defp error_response({:config, id, value, _rest}, error, state) do
    state
    |> reject_switch("Kiro couldn't set #{id} to #{value}: #{error["message"]}")
    |> next()
  end

  defp error_response(kind, error, state) when kind in [:initialize, :new_session] do
    {:fail, "Kiro couldn't start a session: #{error["message"]}", state}
  end

  defp error_response(_kind, _error, state), do: state

  # A tool call starts, changes status, or is denied. Kept on the turn by its call id
  # (a denial without one is its own entry) for the log.
  defp track_tool(%{turn: nil} = state, _call), do: state

  defp track_tool(state, call) do
    update_turn(state, fn turn ->
      id = call["toolCallId"]
      known = id && Enum.find_index(turn.tools, &(&1.call_id == id))

      fields =
        %{
          title: call["title"],
          tool: call["kind"],
          paths: call["locations"] && for(%{"path" => p} <- call["locations"], do: p),
          outcome: outcome(call["status"])
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      tools =
        if known,
          do: List.update_at(turn.tools, known, &Map.merge(&1, fields)),
          else:
            turn.tools ++
              [
                Map.merge(
                  %{call_id: id, tool: "other", title: "a tool", paths: [], outcome: "pending"},
                  fields
                )
              ]

      %{turn | tools: tools}
    end)
  end

  defp outcome("completed"), do: "ok"
  defp outcome("failed"), do: "failed"
  defp outcome("denied"), do: "denied"
  defp outcome(s) when s in ["pending", "in_progress"], do: "pending"
  defp outcome(_), do: nil

  # The turn as log events: the message, the tools, then the reply or the error.
  defp log_turn(state, turn, error) do
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    who = turn.agent.name

    events =
      [%{kind: :user, who: who, text: turn.ask || ""}] ++
        Enum.map(turn.tools, &(&1 |> Map.delete(:call_id) |> Map.merge(%{kind: :tool, who: who}))) ++
        if(turn.text != "", do: [%{kind: :assistant, who: who, text: turn.text}], else: []) ++
        if(error, do: [%{kind: :error, who: who, text: error}], else: [])

    events
    |> Enum.reduce(state, fn e, state ->
      seq = state.seq + 1
      %{state | seq: seq, log: [Map.merge(e, %{id: "e#{seq}", at: at}) | state.log]}
    end)
    |> bound_log()
  end

  # Keep a contiguous suffix of complete entries, bounded by both count and bytes.
  # Count omissions explicitly so future compactions do not imply a complete history.
  defp bound_log(state) do
    max_entries = Factory.Context.config(:max_log_entries)
    max_bytes = Factory.Context.config(:max_log_bytes)

    {log, _, _} =
      Enum.reduce_while(state.log, {[], 0, 0}, fn event, {log, count, bytes} ->
        size = :erlang.external_size(event) + 8

        if count < max_entries and bytes + size <= max_bytes,
          do: {:cont, {[event | log], count + 1, bytes + size}},
          else: {:halt, {log, count, bytes}}
      end)

    %{state | log: Enum.reverse(log), log_dropped: state.seq - length(log)}
  end

  # Over the threshold with a message waiting: compact first.
  defp compact_due?(state) do
    pct = state.context[:pct]
    state.log != [] and is_number(pct) and pct >= Factory.Context.config(:compact_at)
  end

  # Compacts the log and starts a fresh Kiro session; the result goes in front of the
  # next message. Messages waiting are sent once the new session is ready.
  defp compact_now(state, run_id, how) do
    before =
      if state.context[:window] && state.context[:pct],
        do: state.context.window * state.context.pct / 100

    case Factory.Context.compact(Enum.reverse(state.log),
           tokens_before: before,
           omitted_entries: state.log_dropped
         ) do
      {:ok, c} ->
        Logger.info(
          "Kiro session #{inspect(state.key)} compacted: #{c.summarized} entries summarized, " <>
            "#{c.kept} kept, about #{c.tokens} tokens (sha256 #{String.slice(c.sha256, 0, 12)})"
        )

        notice(state, c, run_id: run_id, how: how)
        state = compacted(state)
        {:ok, restart(%{state | carry: c.text})}

      error ->
        error
    end
  end

  defp restart(state) do
    cancel_requests(state)
    close_port(state.port)

    open(%{
      state
      | port: nil,
        session_id: nil,
        ready: false,
        buffer: "",
        pending: %{},
        config: %{},
        primed: MapSet.new()
    })
  end

  # Says in the chat what the compaction kept, so it's visible when it happened on its own.
  defp notice(_state, _c, run_id: nil, how: _how), do: :ok

  defp notice(state, c, run_id: run_id, how: how) do
    if run = Runs.get_run(run_id) do
      whose =
        if state.key == :shared,
          do: "The shared session's",
          else: "#{(Agents.get_agent(state.key) || %{name: "The agent"}).name}'s"

      why =
        case {how, state.context[:pct]} do
          {:auto, pct} when is_number(pct) ->
            " Its context was #{round(pct)}% full (compacting starts at #{Factory.Context.config(:compact_at)}%)."

          _ ->
            ""
        end

      kept =
        case c.kept do
          0 -> "nothing kept word for word"
          n -> "the last #{n} word for word"
        end

      omitted =
        if state.log_dropped > 0,
          do: " #{state.log_dropped} older log entries were omitted by the retention limit.",
          else: ""

      Runs.post(
        run,
        "factory",
        "#{whose} conversation was compacted: #{c.summarized} earlier entries summarized, " <>
          "#{kept}, about #{approx(c.tokens)} tokens in all.#{why} " <>
          "Kiro gets it with the next message, in a fresh session.#{omitted}",
        meta:
          %{
            "compaction" => %{
              "summarized" => c.summarized,
              "kept" => c.kept,
              "tokens" => c.tokens,
              "sha256" => c.sha256,
              "from_pct" => state.context[:pct],
              "auto" => how == :auto
            }
          }
          |> then(&if state.key == :shared, do: &1, else: Map.put(&1, "agent_id", state.key))
      )
    end
  end

  defp approx(n) when n >= 1000, do: "#{round(n / 1000)}k"
  defp approx(n), do: "#{n}"

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

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

  defp next(%{ready: true, turn: nil, switching: nil, queue: [_ | _]} = state) do
    with true <- compact_due?(state),
         {:ok, state} <- compact_now(state, hd(state.queue).run_id, :auto) do
      state
    else
      _ -> start_next(state)
    end
  end

  defp next(state), do: state

  defp start_next(%{queue: [job | rest]} = state) do
    wanted =
      Enum.reject(
        [{"model", job.model || job.agent.model}, {"mode", job.agent.kiro_mode}],
        fn {id, value} -> state.config[id] == value end
      )

    switch(%{state | queue: rest, switching: job}, wanted)
  end

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
    answer(job.reply_to, {:error, reason})

    if run = Runs.get_run(job.run_id) do
      Runs.post(run, "factory", "#{job.agent.name} couldn't start: #{reason}",
        meta: %{"agent_id" => job.agent.id}
      )
    end

    %{state | switching: nil}
  end

  defp reject_switch(state, _reason), do: state

  defp send_prompt(state, %Job{agent: agent} = job) do
    {text, state} = with_context(state, agent, job.text, job.context)

    # After a compaction the conversation so far goes first.
    {text, state} =
      if state.carry,
        do: {state.carry <> "\n\n" <> text, %{state | carry: nil}},
        else: {text, state}

    Agents.set_activity(
      agent.id,
      "running",
      job.activity || "Answering: " <> String.slice(job.text, 0, 60)
    )

    turn = %Turn{
      agent: agent,
      run_id: job.run_id,
      reply_to: job.reply_to,
      step: job.step,
      source: job.source,
      ask: job.text,
      request_id: state.next_id,
      started: System.monotonic_time(:millisecond),
      input_tokens: Factory.Usage.estimate_tokens(text)
    }

    state = %{
      state
      | turn: turn,
        members: MapSet.put(state.members, agent.id),
        usage: Map.put_new(state.usage, agent.id, fresh_usage(agent))
    }

    params = %{sessionId: state.session_id, prompt: [%{type: "text", text: text}]}
    request(state, "session/prompt", params, {:prompt, turn.request_id})
  end

  # An agent's usage starts from its saved totals, without context from an earlier session.
  defp fresh_usage(agent), do: Map.drop(agent.usage || %{}, ["context_pct", "context_tokens"])

  # The agent's prompt goes in front of its first message in this session; the session
  # keeps it for the rest of the conversation. In the shared session every message is
  # labelled with who is speaking.
  # A run step's text already carries them (`context?` false): the agent counts as primed.
  defp with_context(state, agent, text, context?) do
    # The data sources attached to the agent, then its own prompt.
    context =
      if context?,
        do:
          [Factory.Sources.context_for_agent(agent), String.trim(agent.prompt || "")]
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n\n"),
        else: ""

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
    {request, pending} = Map.pop(state.pending, turn.request_id)
    if request, do: Process.cancel_timer(request.timer)
    state = %{state | pending: pending}
    agent = turn.agent

    why =
      if Agent.read_only?(agent),
        do: "#{agent.name} only reads and checks; it can't change the project.",
        else: "#{agent.name} can't use that tool."

    denied = Enum.map_join(turn.denied, "", &"\n(Denied: #{&1}. #{why})")

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
      source: turn.source,
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

    answer(
      turn.reply_to,
      cond do
        error -> {:error, error}
        String.trim(turn.text) == "" -> {:error, "Kiro ended the turn without a reply."}
        true -> {:ok, turn.text <> denied}
      end
    )

    log_turn(%{state | turn: nil, last_run: turn.run_id}, turn, error)
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

    for %Job{agent: agent, run_id: run_id} = job <- waiting do
      Agents.set_activity(agent.id, "error", reason)
      answer(job.reply_to, {:error, reason})

      if run = Runs.get_run(run_id) do
        Runs.post(run, "factory", "#{agent.name} couldn't start: #{reason}",
          meta: %{"agent_id" => agent.id}
        )
      end
    end

    {:stop, :normal, %{state | queue: [], switching: nil}}
  end

  # Whoever waits for a job (a run step) hears how it ended.
  defp answer(nil, _result), do: :ok
  defp answer({pid, ref}, result), do: send(pid, {ref, result})

  # Factory's run tools, with a token for this session (see `Factory.RunTools`).
  defp mcp_servers(state),
    do: [Factory.RunTools.mcp_server(Factory.RunTools.grant_session(state.key))]

  # JSON-RPC out

  defp request(state, method, params, kind) do
    send_json(state, %{jsonrpc: "2.0", id: state.next_id, method: method, params: params})

    timeout =
      if method == "session/prompt",
        do: Kiro.config(:prompt_timeout),
        else: Application.fetch_env!(:factory, :kiro) |> Keyword.get(:rpc_timeout, 30_000)

    timer = Process.send_after(self(), {:request_timeout, state.next_id}, timeout)
    request = %{kind: kind, method: method, timer: timer}
    %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, state.next_id, request)}
  end

  defp cancel_requests(state) do
    for {_id, request} <- state.pending, do: Process.cancel_timer(request.timer)
  end

  defp notify(state, method, params),
    do: send_json(state, %{jsonrpc: "2.0", method: method, params: params})

  defp reply(state, id, result), do: send_json(state, %{jsonrpc: "2.0", id: id, result: result})

  defp reply_error(state, id, code, message),
    do: send_json(state, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp send_json(%{port: nil}, _msg), do: :ok
  defp send_json(%{port: port}, msg), do: Port.command(port, [JSON.encode!(msg), "\n"])
end
