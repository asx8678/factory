defmodule Factory.Sources.Git do
  @moduledoc false

  # Keep the port's OS pid available to the supervisor while the task collects
  # output. Killing a BEAM task or closing its port alone need not stop git.
  def run(_args, _env, timeout) when timeout <= 0, do: {:error, :timeout}

  def run(args, env, timeout) do
    caller = self()
    ref = make_ref()

    executable =
      Application.get_env(:factory, :sources_git_executable) || System.find_executable("git")

    task =
      Task.Supervisor.async_nolink(Factory.TaskSupervisor, fn ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            env:
              Enum.map(env, fn {key, value} ->
                {String.to_charlist(key), String.to_charlist(value)}
              end)
          ])

        send(caller, {ref, port})
        collect(port, [])
      end)

    receive do
      {^ref, port} ->
        case Task.yield(task, timeout) do
          {:ok, {output, status}} ->
            {:ok, output, status}

          {:exit, reason} ->
            {:error, reason}

          nil ->
            try do
              kill(port)
            after
              Task.shutdown(task, :brutal_kill)
            end

            {:error, :timeout}
        end

      {:DOWN, monitor, :process, _pid, reason} when monitor == task.ref ->
        {:error, reason}
    end
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [data | output])

      {^port, {:exit_status, status}} ->
        {output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        # git can be waiting on ssh or a remote helper. Kill its descendants too,
        # before they can be orphaned by killing the parent.
        System.cmd("kill", ["-KILL" | Enum.map(descendants(pid, children()), &to_string/1)],
          stderr_to_stdout: true
        )

      nil ->
        :ok
    end
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
