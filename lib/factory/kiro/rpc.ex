defmodule Factory.Kiro.RPC do
  @moduledoc """
  JSON-RPC 2.0 framing over a `kiro-cli acp` port (`Factory.Kiro.open_port/2`), shared
  by `Factory.Kiro.Session`, `Factory.Kiro.Ask` and `Factory.Kiro.Catalog`: one JSON
  object per line out, and the port's lines read back coming in. Who waits for what
  differs between the three, so each keeps its own receive loop.
  """

  @doc "Sends `msg` (a map without `jsonrpc`) as one line. Nothing when there's no port."
  def write(nil, _msg), do: :ok

  def write(port, msg) do
    Port.command(port, [JSON.encode!(Map.put(msg, :jsonrpc, "2.0")), "\n"])
    :ok
  end

  @doc "A request `id` for `method`."
  def request(port, id, method, params),
    do: write(port, %{id: id, method: method, params: params})

  @doc "A notification: a request without an id, which gets no answer."
  def notify(port, method, params), do: write(port, %{method: method, params: params})

  @doc "The answer to Kiro's request `id`."
  def reply(port, id, result), do: write(port, %{id: id, result: result})

  @doc "An error answer to Kiro's request `id`."
  def reply_error(port, id, code, message),
    do: write(port, %{id: id, error: %{code: code, message: message}})

  @doc "The message of a JSON-RPC error, which Kiro sometimes sends as a bare string."
  def error_message(%{"message" => message}) when is_binary(message), do: message
  def error_message(other), do: inspect(other)

  @doc """
  Takes what the port sent (`{:eol | :noeol, text}`) after `buffer`, the start of a line
  so far: `{:partial, buffer}` while the line goes on, `{:message, msg}` once it's a
  complete JSON object, or `:invalid` for a complete line that isn't one (kiro-cli's own
  output on stdout). After a complete line the buffer starts empty again.

  A line longer than 64 MB is `:invalid` as soon as it's past that: a CLI writing without
  a line break can't fill the memory of whoever reads it. The rest of it then reads as
  another line that isn't JSON.
  """
  @max_line 64 * 1024 * 1024

  def read(buffer, {:noeol, part}) when byte_size(buffer) + byte_size(part) > @max_line,
    do: :invalid

  def read(buffer, {:noeol, part}), do: {:partial, buffer <> part}

  def read(buffer, {:eol, part}) do
    case JSON.decode(buffer <> part) do
      {:ok, %{} = msg} -> {:message, msg}
      _ -> :invalid
    end
  end

  @doc """
  Whether Kiro's MCP servers named `names` are settled, from a `_kiro/mcp/status`
  notification's params: each one listed and past "connecting" (connected, with its
  tools, or failed). Kiro loads them after `session/new` answers.
  """
  def mcp_settled?(params, names) do
    servers = Map.new(List.wrap(params["servers"]), &{&1["name"], &1["status"]})
    Enum.all?(names, &(Map.has_key?(servers, &1) and servers[&1] not in ["connecting", nil]))
  end

  @doc """
  Stops kiro-cli for good: it and everything it started (MCP servers, shells, their
  commands) are killed while it still runs, then the port is closed and what it sent
  before is dropped from the mailbox. Last, the process behind it (`os_pid`, from
  `Port.info(port, :os_pid)` while it was open) gets SIGTERM, in case the port was
  closed already and closing stdin didn't stop it. Either may be gone already.
  """
  def close_port(port, os_pid \\ nil)
  def close_port(nil, _os_pid), do: :ok

  def close_port(port, os_pid) do
    # While kiro-cli still runs: once it has gone its children belong to init, where
    # they can't be told from anyone else's.
    Factory.OsProcess.kill_tree(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
    terminate(os_pid)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp terminate(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp terminate(_os_pid), do: :ok
end
