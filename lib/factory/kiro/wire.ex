defmodule Factory.Kiro.Wire do
  @moduledoc """
  JSON-RPC with kiro-cli over its port (`Factory.Kiro.open_port/2`): one message per
  line. Shared by the three that talk to it, each in its own way: a session
  (`Factory.Kiro.Session`), a one-off question (`Factory.Kiro.Ask`) and the catalog
  check (`Factory.Kiro.Catalog`).
  """

  @doc """
  Takes what the port sent (`{:eol | :noeol, text}`) after `buffer`, the start of a line
  so far: `{:partial, buffer}` while the line goes on, `{:message, msg}` once it's a
  complete JSON message, or `:invalid` for a complete line that isn't one. After a
  complete line the buffer starts empty again.
  """
  def read(buffer, {:noeol, part}), do: {:partial, buffer <> part}

  def read(buffer, {:eol, part}) do
    case JSON.decode(buffer <> part) do
      {:ok, msg} -> {:message, msg}
      {:error, _} -> :invalid
    end
  end

  @doc "Sends `msg` as one line."
  def send_json(port, msg) do
    Port.command(port, [JSON.encode!(msg), "\n"])
    :ok
  end

  @doc """
  Stops kiro-cli for good: it and everything it started (MCP servers, shells, their
  commands) are killed, then the port is closed. What it sent before is dropped from
  the mailbox. Safe on a port that's already closed.
  """
  def close(nil), do: :ok

  def close(port) do
    # While kiro-cli still runs: once it has gone its children belong to init, where
    # they can't be told from anyone else's.
    Factory.OsProcess.kill_tree(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
