defmodule FactoryWeb.ChatLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.{Agents, Runs}

  setup do
    {:ok, coder} = Agents.create_agent(%{name: "Coder"})
    {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer"})
    %{coder: coder, reviewer: reviewer}
  end

  test "a new chat starts centered, then shows the conversation", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/chat")
    assert html =~ "What should the factory build?"

    view |> form("#chat-form", chat: %{body: "/help"}) |> render_submit()
    assert assert_patch(view) =~ ~r{^/chat/\d+$}

    html = render(view)
    refute html =~ "What should the factory build?"
    assert html =~ "Commands:"
  end

  test "an agent's chat shows only that agent's messages", %{
    conn: conn,
    coder: coder,
    reviewer: reviewer
  } do
    {:ok, run} = Runs.create_run()
    Runs.post(run, "user", "to coder", meta: %{"to_agent_id" => coder.id})
    Runs.post(run, "user", "to reviewer", meta: %{"to_agent_id" => reviewer.id})
    Runs.post(run, "factory", "for everyone")

    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")
    assert render(view) =~ "to reviewer"
    assert render(view) =~ "for everyone"

    view |> element("#agent-chip-#{coder.id}") |> render_click()
    assert_patch(view, ~p"/chat/#{run.id}?agent=#{coder.id}")
    html = render(view)
    assert html =~ "to coder"
    refute html =~ "to reviewer"
    refute html =~ "for everyone"
    assert has_element?(view, "#chat-input[placeholder='Message Coder…']")

    view |> element("#agent-all") |> render_click()
    assert render(view) =~ "to reviewer"
  end

  test "sending from an agent's chat posts to that agent", %{conn: conn, coder: coder} do
    {:ok, view, _} = live(conn, ~p"/chat?agent=#{coder.id}")
    assert render(view) =~ "Chat with Coder"

    view |> form("#chat-form", chat: %{body: "hello coder"}) |> render_submit()
    assert assert_patch(view) =~ ~r{^/chat/\d+\?agent=#{coder.id}$}
    html = render(view)
    assert html =~ "hello coder"
    assert html =~ "isn&#39;t connected to Kiro"
  end
end
