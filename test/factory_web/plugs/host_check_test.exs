defmodule FactoryWeb.Plugs.HostCheckTest do
  # Not async: one test turns the check off for the whole application.
  use FactoryWeb.ConnCase, async: false
  alias FactoryWeb.Plugs.HostCheck

  test "Factory's own names are allowed, others aren't" do
    for host <- ~w(localhost LOCALHOST 127.0.0.1 ::1 [::1] www.example.com) do
      assert HostCheck.allowed?(host), host
    end

    for host <- ["evil.example", "factory.attacker.net", "localhost.attacker.net", "", nil] do
      refute HostCheck.allowed?(host), inspect(host)
    end
  end

  test "a request for another host is refused with 403 before it reaches a page", %{conn: conn} do
    conn = get(conn, "http://evil.example/")
    assert conn.status == 403
    assert conn.halted
    assert response(conn, 403) =~ "evil.example"
  end

  test "a request for Factory's own host goes through", %{conn: conn} do
    conn = %{conn | host: "localhost"} |> HostCheck.call([])
    refute conn.halted
  end

  test "the check can be turned off" do
    Application.put_env(:factory, :skip_host_check, true)
    on_exit(fn -> Application.delete_env(:factory, :skip_host_check) end)

    conn = %{build_conn() | host: "evil.example"} |> HostCheck.call([])
    refute conn.halted
  end
end
