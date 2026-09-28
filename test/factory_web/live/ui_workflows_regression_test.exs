defmodule FactoryWeb.UIWorkflowsRegressionTest do
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Factory.{Agents, Workflows}

  test "running an action blocks dry runs and duplicate runs after reopening its panel", %{
    conn: conn
  } do
    {:ok, workflow} = Workflows.create("Actions")
    {:ok, card} = Agents.add_action(workflow.id, "api_request", 0.0, 0.0)

    {:ok, card} =
      Agents.update_agent(card, %{
        action: %{
          "type" => "api_request",
          "config" => %{"url" => "https://example.com/action", "method" => "get"}
        }
      })

    parent = self()

    Req.Test.stub(Factory.Actions, fn conn ->
      send(parent, {:action_started, self()})

      receive do
        :finish -> Req.Test.json(conn, %{"ok" => true})
      end
    end)

    {:ok, view, _} = live(conn, ~p"/workflows/#{workflow.id}/agents/#{card.id}")
    Req.Test.allow(Factory.Actions, self(), view.pid)
    view |> element("#action-run") |> render_click()
    assert_receive {:action_started, worker}, 2_000
    on_exit(fn -> Task.Supervisor.terminate_child(Factory.TaskSupervisor, worker) end)
    ref = Process.monitor(worker)

    assert has_element?(view, "#action-plan[disabled]")
    assert has_element?(view, "#action-run[disabled]")
    render_click(view, "action_plan")
    assert has_element?(view, "#action-result", "Running")

    view |> element("#action-cancel") |> render_click()
    render_hook(view, "select", %{id: to_string(card.id)})
    assert has_element?(view, "#action-run[disabled]")
    render_click(view, "action_run")
    render_click(view, "action_plan")
    refute_receive {:action_started, _}

    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    refute has_element?(view, "#action-run[disabled]")
    assert has_element?(view, "#action-result", "HTTP 200")
  end

  test "adding a second action removes the previous unconfirmed draft", %{conn: conn} do
    {:ok, workflow} = Workflows.create("Drafts")
    {:ok, view, _} = live(conn, ~p"/workflows/#{workflow.id}")
    render_hook(view, "add_action", %{type: "email", x: 0, y: 0})
    [first] = Agents.list_agents(workflow.id)
    render_hook(view, "add_action", %{type: "api_request", x: 300, y: 0})
    [second] = Agents.list_agents(workflow.id)
    assert second.id != first.id
    assert Agents.get_agent(first.id) == nil
    assert has_element?(view, "#action-panel-#{second.id}")
    view |> element("#action-cancel") |> render_click()
    assert Agents.list_agents(workflow.id) == []
  end

  test "malformed and cross-type reconnections leave the original arrow intact", %{conn: conn} do
    {:ok, workflow} = Workflows.create("Connections")
    {:ok, from} = Agents.add_agent(workflow.id, 0, 0)
    {:ok, to} = Agents.add_agent(workflow.id, 0, 100)
    {:ok, next} = Agents.add_agent(workflow.id, 0, 200)
    {:ok, _} = Agents.link(from.id, to.id)
    {:ok, view, _} = live(conn, ~p"/workflows/#{workflow.id}")
    old = %{source: to_string(from.id), target: to_string(to.id)}

    for invalid <- ["source-123", "garbage", "1oops", nil, %{}, -1, "999999999999999999999999"] do
      render_hook(view, "reconnect", %{
        old: old,
        new: %{source: invalid, target: to_string(next.id)}
      })

      assert [%{source: source, target: target}] = Agents.graph(workflow.id).edges
      assert source == old.source and target == old.target
    end

    render_hook(view, "reconnect", %{old: old, new: %{source: from.id, target: next.id}})
    assert [%{target: target}] = Agents.graph(workflow.id).edges
    assert target == to_string(next.id)
  end

  test "the sources modal wraps focus and restores it on removal", %{conn: conn} do
    {:ok, workflow} = Workflows.create("Sources")
    {:ok, view, _} = live(conn, ~p"/workflows/#{workflow.id}")
    render_hook(view, "sources_open", %{})
    assert has_element?(view, "#sources-dialog[phx-hook='Phoenix.FocusWrap']")
    assert has_element?(view, "#sources-window[phx-remove*='pop_focus']")
    assert has_element?(view, "#sources-window[phx-mounted*='push_focus']")
    render_click(view, "sources_close")
    refute has_element?(view, "#sources-window")
  end
end
