defmodule Factory.TestHelpers do
  @moduledoc """
  Setup that several test files share. Imported by `Factory.DataCase` and
  `FactoryWeb.ConnCase`, so every test can call these without aliasing.
  """
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  @doc """
  A spec whose overview, requirements and design are approved, so its tasks step is
  open: `approved_spec(spec)`, or `approved_spec(name, attrs)` to create it first.
  """
  def approved_spec(%Factory.Specs.Spec{} = spec) do
    Enum.reduce(~w(overview requirements design), spec, fn step, spec ->
      {:ok, spec} = Factory.Specs.approve(spec, step)
      spec
    end)
  end

  def approved_spec(name, attrs) when is_binary(name) do
    {:ok, spec} = Factory.Specs.create_spec(name, attrs)
    approved_spec(spec)
  end

  @doc """
  Serves Factory's MCP tools over HTTP on a free port, as Kiro reaches them
  (`FactoryWeb.MCP`), and points `config :factory, :mcp_url` at it for the test.
  """
  def start_mcp do
    server =
      start_supervised!(
        {Bandit, plug: FactoryWeb.Endpoint, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    put_app_env(:mcp_url, "http://127.0.0.1:#{port}/mcp")
  end

  @doc """
  Sets `config :factory, key` for the test and puts the previous value back (or
  removes the key, when there was none) when it ends. Returns the value set.
  """
  def put_app_env(key, value) do
    previous = Application.fetch_env(:factory, key)
    Application.put_env(:factory, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:factory, key, old)
        :error -> Application.delete_env(:factory, key)
      end
    end)

    value
  end
end
