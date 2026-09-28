defmodule FactoryWeb.WorkflowsLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.Agents

  test "the side panel edits an agent and its Kiro settings", %{conn: conn} do
    {:ok, agent} = Agents.create_agent(%{name: "Coder"})
    {:ok, view, _} = live(conn, ~p"/workflows/#{agent.workflow_id}/agents/#{agent.id}")

    assert has_element?(view, "#agent-form")
    assert has_element?(view, ~s(a[href="/chat?agent=#{agent.id}"]), "Chat")
    assert has_element?(view, "#agent-form select[name='agent[kiro_mode]']")
    refute has_element?(view, "#agent-form select[name='agent[runtime]']")

    view |> form("#agent-form", agent: %{name: "Builder"}) |> render_change()
    assert %{name: "Builder", model: "auto"} = Agents.get_agent(agent.id)
  end

  test "Chat on an agent card opens the chat with that agent", %{conn: conn} do
    {:ok, agent} = Agents.create_agent(%{name: "Coder"})
    {:ok, view, _} = live(conn, ~p"/workflows")

    render_hook(view, "chat", %{"id" => to_string(agent.id)})
    assert_redirect(view, ~p"/chat?agent=#{agent.id}")
  end

  test "an arrow drawn between side circles remembers which circles it joins", %{conn: conn} do
    {:ok, a} = Agents.create_agent(%{name: "A"})
    {:ok, b} = Agents.create_agent(%{name: "B"})
    {:ok, view, _} = live(conn, ~p"/workflows")

    render_hook(view, "connect", %{
      "source" => "#{a.id}",
      "target" => "#{b.id}",
      "sourceHandle" => "right",
      "targetHandle" => "left"
    })

    assert [%{source_handle: "right", target_handle: "left"}] =
             Enum.filter(Agents.list_links(), &(&1.source_id == a.id))

    assert [%{source_handle: "right", target_handle: "left"}] =
             Enum.filter(Agents.graph(a.workflow_id).edges, &(&1.source == "#{a.id}"))
  end

  test "moving agents saves their positions", %{conn: conn} do
    {:ok, a} = Agents.create_agent(%{name: "A"})
    {:ok, view, _} = live(conn, ~p"/workflows")

    render_hook(view, "move", %{"nodes" => [%{"id" => "#{a.id}", "x" => 310.5, "y" => -40}]})
    assert %{x: 310.5, y: -40.0} = Agents.get_agent(a.id)
  end

  test "picking a role saves it and shows its icon", %{conn: conn} do
    {:ok, a} = Agents.create_agent(%{name: "A"})
    {:ok, view, _} = live(conn, ~p"/workflows/#{a.workflow_id}/agents/#{a.id}")
    assert has_element?(view, ~s(select[name="agent[kind]"] option[value="general"][selected]))

    view |> form("#agent-form", agent: %{kind: "tester"}) |> render_change()
    assert %{kind: "tester"} = Agents.get_agent(a.id)
    assert has_element?(view, ~s(select[name="agent[kind]"] option[value="tester"][selected]))

    assert [%{kind: "tester"}] =
             Enum.filter(Agents.graph(a.workflow_id).nodes, &(&1.id == "#{a.id}"))
  end

  test "the context button opens the editor and saving stores the prompt", %{conn: conn} do
    {:ok, a} = Agents.create_agent(%{name: "Coder"})
    {:ok, view, _} = live(conn, ~p"/workflows")

    render_hook(view, "context", %{"id" => "#{a.id}"})
    assert_patch(view, ~p"/workflows/#{a.workflow_id}/agents/#{a.id}?prompt")
    assert has_element?(view, "#context-form")

    view
    |> form("#context-form", context: %{prompt: "Always add tests."})
    |> render_submit()

    assert_patch(view, ~p"/workflows/#{a.workflow_id}/agents/#{a.id}")
    refute has_element?(view, "#context-form")
    assert %{prompt: "Always add tests."} = Agents.get_agent(a.id)
    assert has_element?(view, "#edit-context", "1 line")

    assert [%{has_context: true}] =
             Enum.filter(Agents.graph(a.workflow_id).nodes, &(&1.id == "#{a.id}"))
  end

  test "the role menu on a card changes the agent's role", %{conn: conn} do
    {:ok, a} = Agents.create_agent(%{name: "A"})
    {:ok, view, _} = live(conn, ~p"/workflows")

    render_hook(view, "kind", %{"id" => "#{a.id}", "kind" => "reviewer"})
    assert %{kind: "reviewer"} = Agents.get_agent(a.id)

    render_hook(view, "kind", %{"id" => "#{a.id}", "kind" => "not-a-role"})
    assert %{kind: "reviewer"} = Agents.get_agent(a.id)
  end
end
