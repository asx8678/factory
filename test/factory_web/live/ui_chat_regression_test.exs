defmodule FactoryWeb.UIChatRegressionTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.{Agents, Runs, Workflows}

  test "a locked workflow has no picker controls and rejects forged changes", %{conn: conn} do
    workflow = Workflows.picked()
    {:ok, other} = Workflows.create("Other")
    {:ok, run} = Runs.create_run()

    {:ok, run} =
      Runs.update_run(run, %{status: "running", settings: %{"workflow_id" => workflow.id}})

    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")
    assert has_element?(view, "#workflow-picker[aria-disabled=true]")
    refute has_element?(view, "#workflow-picker summary")
    refute has_element?(view, "#workflow-picker button")
    picked = Workflows.picked().id

    render_click(view, "pick_workflow", %{id: to_string(other.id)})
    assert Runs.get_run(run.id).settings["workflow_id"] == workflow.id
    assert Workflows.picked().id == picked
  end

  test "a draft workflow remains settable", %{conn: conn} do
    {:ok, workflow} = Workflows.create("New workflow")
    {:ok, run} = Runs.create_run()
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")
    assert has_element?(view, "#workflow-picker summary")
    render_click(view, "pick_workflow", %{id: to_string(workflow.id)})
    assert Runs.get_run(run.id).settings["workflow_id"] == workflow.id
  end

  test "history starts with 200 messages and pages backwards within that limit", %{conn: conn} do
    {:ok, run} = Runs.create_run()
    messages = for n <- 1..251, do: Runs.post(run, "user", "Message #{n}")
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}")
    assert message_count(view) == 200
    refute has_element?(view, "#messages-#{hd(messages).id}")
    assert has_element?(view, "#messages-#{List.last(messages).id}")
    assert has_element?(view, "#load-earlier")
    assert has_element?(view, "#jump-to-latest")

    view |> element("#load-earlier") |> render_click()
    assert message_count(view) == 200
    assert has_element?(view, "#messages-#{Enum.at(messages, 1).id}")
    refute has_element?(view, "#messages-#{List.last(messages).id}")
    assert has_element?(view, "#messages[data-history=true]")

    {:ok, run} = Runs.update_run(run, %{status: "running"})
    send(view.pid, {:run_updated, run})
    assert has_element?(view, "#messages-#{Enum.at(messages, 1).id}")
    assert has_element?(view, "#messages[data-history=true]")

    # Live replies don't evict the history being read.
    newest = Runs.post(run, "user", "Newest")
    send(view.pid, {:message, newest})
    refute has_element?(view, "#messages-#{newest.id}")
    view |> element("#load-earlier") |> render_click()
    assert has_element?(view, "#messages-#{hd(messages).id}")
    refute has_element?(view, "#load-earlier")

    render_hook(view, "latest", %{})
    assert message_count(view) == 200
    assert has_element?(view, "#messages-#{newest.id}")
    assert has_element?(view, "#messages[data-history=false]")
    assert_push_event(view, "chat:latest", %{})

    another = Runs.post(run, "user", "Another")
    send(view.pid, {:message, another})
    assert has_element?(view, "#messages-#{another.id}")
    assert message_count(view) == 200
  end

  test "agent history is filtered before pagination", %{conn: conn} do
    {:ok, agent} = Agents.create_agent(%{name: "History agent"})
    {:ok, run} = Runs.create_run()
    first = Runs.post(run, "user", "Older for agent", meta: %{"to_agent_id" => agent.id})
    for n <- 1..205, do: Runs.post(run, "user", "Other #{n}")
    last = Runs.post(run, "factory", "Agent reply", meta: %{"agent_id" => agent.id})
    {:ok, view, _} = live(conn, ~p"/chat/#{run.id}?agent=#{agent.id}")
    assert message_count(view) == 2
    assert has_element?(view, "#messages-#{first.id}")
    assert has_element?(view, "#messages-#{last.id}")
    refute has_element?(view, "#load-earlier")
  end

  test "the folder browser wraps focus and restores the folder button", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/chat")
    view |> element("#folder-button") |> render_click()
    assert has_element?(view, "#folder-dialog[phx-hook='Phoenix.FocusWrap']")

    assert has_element?(
             view,
             "#folder-picker[phx-mounted*='push_focus'][phx-mounted*='folder-button']"
           )

    assert has_element?(view, "#folder-picker[phx-remove*='pop_focus']")
    render_click(view, "browse_cancel")
    refute has_element?(view, "#folder-picker")
  end

  defp message_count(view) do
    view
    |> element("#messages")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#messages > [id]")
    |> Enum.count()
  end
end
