defmodule FactoryWeb.ChatLiveTest do
  # Not async: messages to agents start (fake) Kiro sessions, which need the shared sandbox.
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Factory.{Agents, Runs}

  setup do
    {:ok, coder} = Agents.create_agent(%{name: "Coder"})
    {:ok, reviewer} = Agents.create_agent(%{name: "Reviewer"})
    %{coder: coder, reviewer: reviewer}
  end

  test "a new chat starts centered, then shows the conversation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chat")
    assert has_element?(view, "#chat-start", "What should we build?")

    view |> form("#chat-form", chat: %{body: "/help"}) |> render_submit()
    assert assert_patch(view) =~ ~r{^/chat/\d+$}

    refute has_element?(view, "#chat-start")
    assert has_element?(view, "#messages", "Commands:")
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
    assert has_element?(view, "#messages", "to reviewer")
    assert has_element?(view, "#messages", "for everyone")

    view |> element("#chat-map-agent-#{coder.id}") |> render_click()
    assert_patch(view, ~p"/chat/#{run.id}?agent=#{coder.id}")
    assert has_element?(view, "#messages", "to coder")
    refute has_element?(view, "#messages", "to reviewer")
    refute has_element?(view, "#messages", "for everyone")
    assert has_element?(view, "#chat-input[placeholder='Message Coder…']")

    view |> element("#agent-all") |> render_click()
    assert has_element?(view, "#messages", "to reviewer")
  end

  test "sending from an agent's chat posts to that agent", %{conn: conn, coder: coder} do
    {:ok, view, _} = live(conn, ~p"/chat?agent=#{coder.id}")
    assert has_element?(view, "#chat-page h1", "Chat with Coder")

    # Agents need the folder they work in before anything is sent to them.
    view |> form("#chat-form", chat: %{body: "hello coder"}) |> render_submit()
    assert has_element?(view, "#folder-button.text-error")
    render_click(view, "browse_pick", %{"path" => File.cwd!()})

    on_exit(fn -> Factory.Kiro.stop(coder.id) end)
    view |> form("#chat-form", chat: %{body: "hello coder"}) |> render_submit()
    path = assert_patch(view)
    assert path =~ ~r{^/chat/\d+\?agent=#{coder.id}$}
    [_, run_id] = Regex.run(~r{/chat/(\d+)}, path)
    Runs.subscribe(String.to_integer(run_id))
    assert_receive {:message, %{author: "Coder"}}, 5_000

    assert has_element?(view, "#messages", "hello coder")
    assert has_element?(view, "#messages", "echo: hello coder")
  end

  test "an agent's context shows on its card and beside the message box", %{
    conn: conn,
    coder: coder
  } do
    Agents.record_usage(coder.id, %{
      "context_pct" => 72.4,
      "window" => 200_000,
      "context_tokens" => 144_800
    })

    {:ok, run} = Runs.create_run()
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}?agent=#{coder.id}")

    assert has_element?(view, "#chat-map-agent-#{coder.id} .wf-ctx.is-high")

    assert has_element?(
             view,
             "#chat-map-agent-#{coder.id}[title*='Context 72% (compacts at 70%)']"
           )

    assert has_element?(view, "#context-chip.is-high", "72%")

    # No Kiro session runs in this test, so the chat says there's nothing to compact.
    view |> element("#compact-chip") |> render_click()

    assert has_element?(
             view,
             "#messages",
             "Nothing to compact: Coder has no Kiro session running."
           )
  end

  test "an agent's activity updates its card in place", %{conn: conn, coder: coder} do
    {:ok, run} = Runs.create_run()
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}?agent=#{coder.id}")
    refute has_element?(view, "#context-chip")

    # Kiro reports context: the card and the chip follow without a reload.
    Agents.record_usage(coder.id, %{"context_pct" => 72.4, "window" => 200_000})
    assert has_element?(view, "#chat-map-agent-#{coder.id} .wf-ctx.is-high")
    assert has_element?(view, "#context-chip.is-high", "72%")

    # An agent of another workflow doesn't touch this chat.
    {:ok, other} = Factory.Workflows.create("Elsewhere")
    {:ok, stranger} = Agents.create_agent(%{name: "Stranger", workflow_id: other.id})
    graph = Agents.graph(Factory.Workflows.current().id)
    assert Agents.put_node(graph, stranger) == :unchanged
    assert %{nodes: nodes} = Agents.put_node(graph, %{coder | status: "running"})
    assert Enum.find(nodes, &(&1.id == to_string(coder.id))).status == "running"
  end

  test "no chip without context in use", %{conn: conn, coder: coder} do
    {:ok, view, _} = live(conn, ~p"/chat?agent=#{coder.id}")
    refute has_element?(view, "#context-chip")
    refute has_element?(view, "#chat-map-agent-#{coder.id} .wf-ctx")
  end

  test "Spec, and the P shortcut to its tasks, open the chat's own spec", %{conn: conn} do
    {:ok, run} = Runs.create_run()
    {:ok, run} = Runs.update_run(run, %{settings: %{"project_dir" => File.cwd!()}})
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")

    {:error, {:live_redirect, %{to: to}}} = view |> element("#specs-button") |> render_click()
    spec_id = Runs.get_run(run.id).spec_id
    assert to == "/specs/#{spec_id}"

    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")
    # The P shortcut (ChatKeys) sends "tasks".
    {:error, {:live_redirect, %{to: to}}} = render_hook(view, "tasks", %{})
    assert to == "/specs/#{spec_id}?step=tasks"
  end
end
