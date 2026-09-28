defmodule FactoryWeb.WorkflowsPageTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.{Agents, Workflows}

  test "pick a workflow, make a new one, clone, restore and delete", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows")
    bug = Workflows.standard("bug")

    # The menu lists the standard workflows; picking one opens it.
    assert has_element?(view, "#workflow-picker", "Select workflow")
    view |> element("#pick-workflow-#{bug.id}") |> render_click()
    assert_patch(view, ~p"/workflows/#{bug.id}")
    assert has_element?(view, "#workflow-name", "Fix a bug")
    assert has_element?(view, "#wf-restore[disabled]")
    refute has_element?(view, "#wf-delete")

    # Changing it enables Restore default, which puts it back.
    [investigator | _] = Workflows.ordered_agents(bug.id)
    {:ok, _} = Agents.update_agent(investigator, %{name: "Detective"})
    {:ok, view, _html} = live(conn, ~p"/workflows/#{bug.id}")
    assert has_element?(view, "#workflow-modified")
    view |> element("#wf-restore") |> render_click()
    refute has_element?(view, "#workflow-modified")
    assert ["Investigator" | _] = Enum.map(Workflows.steps(bug), & &1["name"])

    # Clone opens the copy, which can be used in chat and deleted.
    view |> element("#wf-clone") |> render_click()
    copy = Enum.find(Workflows.list(), &(&1.name == "Fix a bug (copy)"))
    assert_patch(view, ~p"/workflows/#{copy.id}")
    view |> element("#wf-use") |> render_click()
    assert Workflows.current().id == copy.id
    view |> element("#wf-delete") |> render_click()
    assert_redirect(view, ~p"/workflows")
    assert Workflows.get(copy.id) == nil

    # Add new workflow asks for a name and opens it, empty.
    {:ok, view, _html} = live(conn, ~p"/workflows/#{bug.id}")
    view |> element("#wf-new") |> render_click()
    view |> form("#workflow-name-form", %{name: "Docs pass"}) |> render_submit()
    docs = Enum.find(Workflows.list(), &(&1.name == "Docs pass"))
    assert_patch(view, ~p"/workflows/#{docs.id}")
    assert Agents.list_agents(docs.id) == []

    # New agents land in the open workflow.
    render_hook(view, "add_agent", %{"x" => 0, "y" => 0})
    assert [_] = Agents.list_agents(docs.id)
  end

  test "the start screen shows each job's workflow as it is now", %{conn: conn} do
    bug = Workflows.standard("bug")
    [investigator | _] = Workflows.ordered_agents(bug.id)
    {:ok, _} = Agents.update_agent(investigator, %{name: "Detective"})

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Detective"
  end

  test "actions are added from the palette and set up in their own panel", %{conn: conn} do
    {:ok, w} = Workflows.create("Ship")
    {:ok, view, html} = live(conn, ~p"/workflows/#{w.id}")
    # The canvas gets the kinds of action for its palette.
    assert html =~ "Create GitHub PR" and html =~ "API request"

    render_hook(view, "add_action", %{"type" => "email", "x" => 300, "y" => 0})
    [card] = Agents.list_agents(w.id)
    assert_patch(view, ~p"/workflows/#{w.id}/agents/#{card.id}")
    assert has_element?(view, "#action-panel-#{card.id}", "Send email")
    refute has_element?(view, "#agent-form")
    assert has_element?(view, "#action-run[disabled]")

    # Changes are a draft: a dry run uses them, Add saves them.
    view |> form("#action-form", action: %{config: %{to: "me@example.com"}}) |> render_change()
    assert Agents.get_agent(card.id).action["config"]["to"] == nil
    refute has_element?(view, "#action-run[disabled]")
    view |> element("#action-plan") |> render_click()
    assert has_element?(view, "#action-result", "Email me@example.com")

    assert has_element?(view, "#action-save", "Add")
    view |> form("#action-form") |> render_submit()
    assert Agents.get_agent(card.id).action["config"]["to"] == "me@example.com"
    assert has_element?(view, "#action-save[disabled]", "Save")

    # A new action you cancel is gone.
    render_hook(view, "add_action", %{"type" => "webhook", "x" => 300, "y" => 200})
    assert [_, new] = Agents.list_agents(w.id)
    view |> element("#action-cancel") |> render_click()
    assert Agents.get_agent(new.id) == nil
    assert [_] = Agents.list_agents(w.id)
  end
end
