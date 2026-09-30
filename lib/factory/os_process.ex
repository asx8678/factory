defmodule Factory.OsProcess do
  @moduledoc """
  Runs a program outside the BEAM with a deadline, and stops it for good. Killing a BEAM
  task or closing a port alone need not stop the program (git waiting on ssh, a shell and
  the tests it started), so a program that overruns is killed with its descendants.
  """

  @doc """
  Runs `executable` with `args` and waits at most `:timeout` ms (default 10 minutes):
  `{:ok, output, exit_status}`, `{:error, :timeout}` or `{:error, reason}`, where
  `reason` says in words why it couldn't start (no such program or folder). stderr goes
  into the output. Options: `:cd`, `:env` (`{name, value}` strings) and `:timeout`.
  A bare executable name is looked up on the PATH.
  """
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 600_000)
    path = find(executable)
    cd = opts[:cd]

    cond do
      path == nil -> {:error, "#{executable} wasn't found"}
      # The port would start anyway and fail with nothing to show for it.
      cd != nil and not File.dir?(cd) -> {:error, "there's no folder #{cd}"}
      timeout <= 0 -> {:error, :timeout}
      true -> spawn_and_wait(path, args, opts, timeout)
    end
  end

  defp find(executable) do
    cond do
      Path.type(executable) != :absolute -> System.find_executable(executable)
      File.regular?(executable) -> executable
      true -> nil
    end
  end

  defp spawn_and_wait(path, args, opts, timeout) do
    caller = self()
    ref = make_ref()

    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env:
          Enum.map(Keyword.get(opts, :env, []), fn {key, value} ->
            # A nil value unsets the variable.
            {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
          end)
      ] ++ if(cd = opts[:cd], do: [cd: cd], else: [])

    task =
      Task.Supervisor.async_nolink(Factory.TaskSupervisor, fn ->
        case open(path, port_opts) do
          {:ok, port} ->
            send(caller, {ref, port})
            collect(port, [])

          {:error, reason} ->
            send(caller, {ref, {:error, reason}})
            :not_started
        end
      end)

    receive do
      {^ref, {:error, reason}} ->
        Task.shutdown(task, :brutal_kill)
        {:error, reason}

      {^ref, port} ->
        case Task.yield(task, timeout) do
          {:ok, {output, status}} ->
            {:ok, output, status}

          {:exit, reason} ->
            {:error, reason}

          nil ->
            try do
              kill_tree(port)
            after
              Task.shutdown(task, :brutal_kill)
            end

            {:error, :timeout}
        end

      {:DOWN, monitor, :process, _pid, reason} when monitor == task.ref ->
        {:error, reason}
    end
  end

  # A program that can't be started (not executable, say) is an answer, not a crash.
  defp open(path, port_opts) do
    {:ok, Port.open({:spawn_executable, path}, port_opts)}
  rescue
    e in ErlangError -> {:error, "#{Path.basename(path)} couldn't start: #{inspect(e.original)}"}
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [data | output])

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end

  @doc """
  Kills a port's OS process (or the OS pid given) and every process it started, children
  first, so none is orphaned. Safe to call on a port that is already closed.
  """
  def kill_tree(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> kill_tree(pid)
      nil -> :ok
    end
  end

  def kill_tree(pid) when is_integer(pid) do
    System.cmd("kill", ["-KILL" | Enum.map(descendants(pid, children()), &to_string/1)],
      stderr_to_stdout: true
    )

    :ok
  rescue
    ErlangError -> :ok
  end

  @doc """
  The processes a port's OS process (or the OS pid given) started, and theirs, each with
  when it started: `[{pid, started}]`. `kill_known/1` kills them later, even once their
  parent is gone and they belong to init, without touching a process that has since
  taken one of their numbers.
  """
  def descendants_with_start(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> descendants_with_start(pid)
      nil -> []
    end
  end

  def descendants_with_start(pid) when is_integer(pid) do
    table = processes()
    children = Enum.group_by(table, fn {_pid, {parent, _}} -> parent end, fn {pid, _} -> pid end)

    for child <- descendants(pid, children),
        child != pid,
        {_, started} = table[child],
        do: {child, started}
  end

  @doc "Kills those of `known` (`descendants_with_start/1`) still running as they were."
  def kill_known([]), do: :ok

  def kill_known(known) do
    table = processes()

    case for({pid, started} <- known, match?({_, ^started}, table[pid]), do: to_string(pid)) do
      [] -> :ok
      pids -> System.cmd("kill", ["-KILL" | pids], stderr_to_stdout: true)
    end

    :ok
  rescue
    ErlangError -> :ok
  end

  # Every process: pid => {parent pid, when it started, as ps writes it}.
  defp processes do
    case System.cmd("ps", ["-axo", "pid=,ppid=,lstart="], stderr_to_stdout: true) do
      {output, 0} ->
        for line <- String.split(output, "\n", trim: true),
            [pid, parent, started] <- [String.split(String.trim(line), ~r/\s+/, parts: 3)],
            into: %{},
            do: {String.to_integer(pid), {String.to_integer(parent), started}}

      _ ->
        %{}
    end
  rescue
    ErlangError -> %{}
  end

  defp children do
    case System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split() |> Enum.map(&String.to_integer/1) end)
        |> Enum.group_by(fn [_pid, parent] -> parent end, fn [pid, _parent] -> pid end)

      _ ->
        %{}
    end
  rescue
    ErlangError -> %{}
  end

  defp descendants(pid, children) do
    Enum.flat_map(Map.get(children, pid, []), &descendants(&1, children)) ++ [pid]
  end
end
