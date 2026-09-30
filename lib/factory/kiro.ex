defmodule Factory.Kiro do
  @moduledoc """
  Runs agents on Kiro. Every session is its own `kiro-cli acp --agent-engine v3`
  process (a `Factory.Kiro.Session`): either an agent's own session, or the one
  shared session that all agents set to "Shared session" talk in.
  """
  alias Factory.Kiro.Session

  # As offered by kiro-cli 2.24 (v3 engine) in session/new.
  @models ~w(auto claude-sonnet-4.5 claude-sonnet-4 claude-haiku-4.5 deepseek-3.2 minimax-m2.5 minimax-m2.1 glm-5 qwen3-coder-next)
  @modes ~w(vibe spec quick-spec bug-fix plan autonomous semantic_reviewer kiro-fabric)

  @doc "The models this Kiro offers (see `Factory.Kiro.Catalog`), else the ones it shipped with."
  def models, do: values(Factory.Kiro.Catalog.models()) || @models

  @doc """
  The model Factory plans with: the one chosen in Settings, else the strongest this
  Kiro offers that Factory picks on its own (`strongest/0`).
  """
  def planning_model, do: chosen("planning_model") || strongest()

  @doc """
  The model that checks each finished task against its checks: the one chosen in
  Settings, else the newest Claude Haiku this Kiro offers, which is quick and cheap
  and isn't the model that built it.
  """
  def verify_model, do: chosen("verify_model") || quick()

  @doc "The newest Claude Haiku this Kiro offers, else \"auto\": verifying's default."
  def quick do
    models() |> Enum.filter(&String.contains?(&1, "haiku")) |> Enum.sort(:desc) |> List.first() ||
      "auto"
  end

  @doc """
  The strongest model Factory picks on its own: the newest Claude Opus when this Kiro
  offers one, else "auto". Sonnet isn't among them (`avoided?/1`).
  """
  def strongest do
    models() |> Enum.filter(&String.contains?(&1, "opus")) |> Enum.sort(:desc) |> List.first() ||
      "auto"
  end

  # Models Factory never picks on its own, for a plan or a task: Sonnet, the person's
  # call. One chosen by hand, in Settings or on an agent's card, is still used.
  @avoid ~w(sonnet)

  @doc "Whether Factory leaves `model` alone unless someone chooses it by hand (Sonnet)."
  def avoided?(model) when is_binary(model), do: Enum.any?(@avoid, &String.contains?(model, &1))
  def avoided?(_model), do: false

  @doc "The models a plan may give a task: the ones this Kiro offers, less `avoided?/1`."
  def task_models, do: Enum.reject(models(), &avoided?/1)

  # A model chosen in Settings, while this Kiro still offers it.
  defp chosen(key) do
    case Factory.Prefs.get(key) do
      model when is_binary(model) -> if model in models(), do: model
      _ -> nil
    end
  end

  @doc "The name Kiro gives model `value`, e.g. \"Claude Sonnet 4.5\"; the value when it gives none."
  def model_name(value) do
    case Enum.find(Factory.Kiro.Catalog.models() || [], &(&1["value"] == value)) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> value
    end
  end

  @doc "The modes this Kiro offers, like `models/0`."
  def modes, do: values(Factory.Kiro.Catalog.modes()) || @modes

  defp values([_ | _] = options), do: Enum.map(options, & &1["value"])
  defp values(_), do: nil

  def config(key), do: Application.fetch_env!(:factory, :kiro) |> Keyword.fetch!(key)

  @doc "The session an agent talks in: `:shared`, or its own id."
  def session_key(%{session: "shared"}), do: :shared
  def session_key(agent), do: agent.id

  @doc "Folder Kiro works in for a run's chat: the run's project folder, else the default workspace."
  def workdir(run), do: blank_to_nil(run && run.settings["project_dir"]) || config(:workspace)

  @doc """
  Queues a message for the agent's session, starting it if needed. The reply is posted
  to the run. `{:ok, ref}`, a reference for `cancel/2`; `{:error, :busy}` when the
  session works in another folder; `{:error, reason}` when Kiro couldn't start.
  """
  def prompt(agent, run_id, text) do
    dir = workdir(Factory.Runs.get_run(run_id))
    key = session_key(agent)

    locked(key, fn ->
      with {:ok, pid} <- ensure_session(key, dir),
           do: safe(fn -> Session.prompt(pid, agent, run_id, text) end)
    end)
  end

  @doc """
  Withdraws a message `prompt/3` or `run_step/4` queued for the agent (its `ref`): see
  `Factory.Kiro.Session.cancel/2`. `{:error, :gone}` when it has ended, or the session
  with it.
  """
  def cancel(agent, ref) do
    case whereis(session_key(agent)) do
      nil -> {:error, :gone}
      pid -> safe(fn -> Session.cancel(pid, ref) end, {:error, :gone})
    end
  end

  @doc "Cancels the chat `run_id`'s messages, queued or in progress, in every session."
  def cancel_run(run_id) do
    for pid <- sessions(), do: safe(fn -> Session.cancel_run(pid, run_id) end)
    :ok
  end

  # Every session running: the registry's entries under a session key (`session_key/1`),
  # not the tuple keys other modules lock with (`Factory.Engine`, `FactoryWeb.Mcp`).
  defp sessions do
    Factory.Kiro.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reject(fn {key, _pid} -> is_tuple(key) end)
    |> Enum.map(fn {_key, pid} -> pid end)
  end

  @doc """
  Runs one step of a run on the agent's own Kiro session (or the shared one) and waits
  for the reply: `{:ok, reply}` or `{:error, reason}`. The session posts the reply to
  the run's chat as it does for any message, and keeps the conversation, so a step
  sent back to this agent carries on where it left off. `opts` are
  `Factory.Kiro.Session.prompt/5`'s, without `:reply_to`; `:brief` goes in front of
  `text` only when the session hasn't had it.

  The wait ends when the session answers, when it stops, or after the prompt timeout
  twice over plus a minute (it may first finish another message).
  """
  def run_step(agent, run_id, text, opts \\ []) do
    dir = workdir(Factory.Runs.get_run(run_id))
    key = session_key(agent)
    ref = make_ref()
    # `on_busy: :return` gives `{:error, :busy}` for a session busy in another folder.
    {on_busy, opts} = Keyword.pop(opts, :on_busy)
    opts = Keyword.put(opts, :reply_to, {self(), ref})

    queued =
      locked(key, fn ->
        with {:ok, pid} <- ensure_session(key, dir),
             {:ok, job} <- safe(fn -> Session.prompt(pid, agent, run_id, text, opts) end),
             do: {:ok, pid, job}
      end)

    case queued do
      {:ok, pid, job} ->
        monitor = Process.monitor(pid)
        wait = 2 * config(:prompt_timeout) + 60_000

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            worded(result, agent)

          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            # A last answer may have been sent just before it stopped.
            receive do
              {^ref, result} -> worded(result, agent)
            after
              0 -> {:error, "#{agent.name}'s Kiro session stopped before it answered."}
            end
        after
          wait ->
            Process.demonitor(monitor, [:flush])
            # The job is withdrawn, so the session doesn't answer into the void later.
            safe(fn -> Session.cancel(pid, job) end)
            {:error, "#{agent.name} didn't answer within #{div(wait, 60_000)} minutes."}
        end

      {:error, :busy} when on_busy == :return ->
        {:error, :busy}

      {:error, :busy} ->
        {:error,
         "#{agent.name}'s Kiro session is working in another project folder. " <>
           "Try again when it's idle."}

      {:error, reason} when is_binary(reason) ->
        {:error, "Couldn't start Kiro for #{agent.name}: #{reason}"}

      {:error, reason} ->
        {:error, "Couldn't start Kiro for #{agent.name}: #{inspect(reason)}"}
    end
  end

  defp ensure_session(key, dir) do
    case Registry.lookup(Factory.Kiro.Registry, key) do
      [] ->
        start(key, dir)

      [{pid, ^dir}] ->
        {:ok, pid}

      [{pid, _elsewhere}] ->
        # A session that stopped between the lookup and the call counts as idle.
        if safe(fn -> Session.idle?(pid) end, true) do
          stop_session(key)
          start(key, dir)
        else
          {:error, :busy}
        end
    end
  end

  # Checked before the session starts, so a missing folder or kiro-cli is an error the
  # caller gets, not a session that starts and stops (the same checks as the session's).
  defp start(key, dir) do
    if dir == config(:workspace), do: File.mkdir_p(dir)

    cond do
      not File.dir?(dir) ->
        {:error, "The workspace folder #{dir} doesn't exist."}

      not File.exists?(config(:cli)) ->
        {:error, "kiro-cli wasn't found at #{config(:cli)}."}

      true ->
        start_child(key, dir)
    end
  end

  defp start_child(key, dir) do
    case DynamicSupervisor.start_child(Factory.Kiro.Supervisor, {Session, {key, dir}}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        if Registry.lookup(Factory.Kiro.Registry, key) == [{pid, dir}],
          do: {:ok, pid},
          else: {:error, :busy}

      other ->
        other
    end
  end

  # A call to a session that stops meanwhile mustn't take the caller (a LiveView) down.
  defp safe(fun, on_exit \\ {:error, "The Kiro session stopped."}) do
    fun.()
  catch
    :exit, _ -> on_exit
  end

  def whereis(key) do
    case Registry.lookup(Factory.Kiro.Registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Whether the session this agent talks in is running."
  def running?(agent), do: whereis(session_key(agent)) != nil

  @doc "Stops a session (`:shared` or an agent id). The next message starts a fresh one."
  def stop(key) do
    locked(key, fn -> stop_session(key) end)
  end

  defp stop_session(key) do
    if pid = whereis(key),
      do: DynamicSupervisor.terminate_child(Factory.Kiro.Supervisor, pid)

    :ok
  end

  # Include enqueue in the lock so an idle session cannot be replaced between lookup
  # and accepting its first job. Different session keys can still start independently.
  defp locked(key, fun), do: :global.trans({{__MODULE__, key}, self()}, fun, [node()])

  @doc """
  Compacts the conversation of the session this agent talks in (see
  `Factory.Kiro.Session`), noting it in the chat `run_id` if given.
  `{:error, :no_session}` if none runs.
  """
  def compact(agent, run_id \\ nil) do
    case whereis(session_key(agent)) do
      nil -> {:error, :no_session}
      pid -> safe(fn -> Session.compact(pid, run_id) end, {:error, :no_session})
    end
  end

  @doc """
  The person's answer to a question a tool asked `agent` mid-turn (see
  `Factory.Kiro.Session.answer_elicitation/4`). `{:error, :gone}` when it's closed.
  """
  def answer_elicitation(agent, key, action, content \\ %{}) do
    case whereis(session_key(agent)) do
      nil -> {:error, :gone}
      pid ->
        safe(fn -> Session.answer_elicitation(pid, key, action, content) end, {:error, :gone})
    end
  end

  @doc "Sends the agent's prompt again before its next message, e.g. after it was edited."
  def forget(agent) do
    if pid = whereis(session_key(agent)), do: Session.forget(pid, agent.id)
    :ok
  end

  @doc "Asks Kiro one question in a throwaway session and waits for the reply. See `Factory.Kiro.Ask`."
  defdelegate ask(text, opts \\ []), to: Factory.Kiro.Ask, as: :run

  @doc """
  Starts `kiro-cli acp --agent-engine v3` in `workdir`, with its stderr going to
  `log_name` in the log folder. Messages arrive as `{port, {:data, {:eol | :noeol, text}}}`.
  """
  def open_port(workdir, log_name) do
    log = Path.join(config(:log_dir), log_name)

    # v3 rejects --model; the model and mode are set on the session, per turn.
    args = ["acp", "--agent-engine", "v3", "--auth-method", "cli"]

    # sh only redirects stderr to the log; exec replaces it with kiro-cli.
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      {:line, 1_048_576},
      {:cd, workdir},
      {:env,
       [
         {~c"KIRO_FABRIC_LAUNCH_WORKSPACE", ~c"#{workdir}"},
         {~c"KIRO_LOG", ~c"#{log}"}
       ]},
      {:args, ["-c", ~s(exec "$0" "$@" 2>>"$KIRO_LOG"), config(:cli) | args]}
    ])
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  # A cancelled job's answer, in words the run's chat and the agent's card can show.
  defp worded({:error, :cancelled}, agent), do: {:error, "#{agent.name}'s step was cancelled."}
  defp worded(result, _agent), do: result
end
