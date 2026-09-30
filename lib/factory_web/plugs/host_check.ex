defmodule FactoryWeb.Plugs.HostCheck do
  @moduledoc """
  Answers only requests for Factory's own names. Factory has no sign-in and listens on
  this machine, so a page elsewhere could point its own name at 127.0.0.1 (DNS
  rebinding) and read Factory from the browser as if it were local. Its requests
  carry that other name as `Host`, so they're refused with 403.

  Allowed: `localhost`, `127.0.0.1` and `::1`, the endpoint's configured host
  (`PHX_HOST` in production), and `www.example.com`, which is the host
  `Phoenix.ConnTest` gives every test request. `config :factory, :skip_host_check`
  set to true turns the check off.
  """
  @behaviour Plug
  import Plug.Conn

  @loopback ["localhost", "127.0.0.1", "::1", "[::1]"]
  # Phoenix.ConnTest's default host: tests can't say otherwise without an endpoint change.
  @test_host "www.example.com"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if Application.get_env(:factory, :skip_host_check) == true or allowed?(conn.host) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Factory doesn't answer for the host #{conn.host}.")
      |> halt()
    end
  end

  @doc "Whether `host` (without a port) is one Factory answers for."
  def allowed?(host) when is_binary(host), do: String.downcase(host) in allowed_hosts()
  def allowed?(_host), do: false

  defp allowed_hosts do
    configured =
      case Application.get_env(:factory, FactoryWeb.Endpoint)[:url][:host] do
        host when is_binary(host) and host != "" -> [String.downcase(host)]
        _ -> []
      end

    @loopback ++ [@test_host] ++ configured
  end
end
