defmodule Factory.Kiro.RPC do
  @moduledoc """
  JSON-RPC 2.0 framing over a `kiro-cli acp` port, shared by `Factory.Kiro.Session`,
  `Factory.Kiro.Ask` and `Factory.Kiro.Catalog`: one JSON object per line out, and
  the port's lines decoded coming in. Who waits for what differs between the three, so
  each keeps its own receive loop.
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
  Decodes one line from the port: `{:ok, msg}` for a JSON object, `:skip` for anything
  else (kiro-cli's own output on stdout).
  """
  def decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = msg} -> {:ok, msg}
      _ -> :skip
    end
  end

  @doc """
  Closes the port, then ends the process behind it (`os_pid`, from
  `Port.info(port, :os_pid)` while it was open) with SIGTERM, in case closing stdin
  didn't stop it. Either may be gone already.
  """
  def close_port(port, os_pid \\ nil)
  def close_port(nil, _os_pid), do: :ok

  def close_port(port, os_pid) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    terminate(os_pid)
  end

  defp terminate(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp terminate(_os_pid), do: :ok
end
