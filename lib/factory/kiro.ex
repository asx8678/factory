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

  @doc "Queues a message for the agent's session, starting it if needed. The reply is posted to the run."
  def prompt(agent, run_id, text) do
    dir = workdir(Factory.Runs.get_run(run_id))
    key = session_key(agent)

    locked(key, fn ->
      with {:ok, pid} <- ensure_session(key, dir), do: Session.prompt(pid, agent, run_id, text)
    end)
  end

  @doc """
  The agent's session, working in `dir`, started if needed. A session working in another
  folder (a chat on another project) starts again in `dir` once it's idle; until then
  `{:error, :busy}`.
  """
  def ensure_started(agent, dir) do
    key = session_key(agent)
    locked(key, fn -> ensure_session(key, dir) end)
  end

  defp ensure_session(key, dir) do
    case Registry.lookup(Factory.Kiro.Registry, key) do
      [] ->
        start(key, dir)

      [{pid, ^dir}] ->
        {:ok, pid}

      [{pid, _elsewhere}] ->
        if Session.idle?(pid) do
          stop_session(key)
          start(key, dir)
        else
          {:error, :busy}
        end
    end
  end

  defp start(key, dir) do
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
      pid -> Session.compact(pid, run_id)
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
end
