defmodule FactoryWeb.UISpecRegressionTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.Specs

  defp open_spec do
    {:ok, spec} =
      Specs.create_spec("Tasks", %{
        requirements: "# R",
        design: "# D",
        tasks: "- [ ] 1. First\n- [ ] 2. Second"
      })

    {:ok, spec} = Specs.approve(spec, "overview")
    {:ok, spec} = Specs.approve(spec, "requirements")
    {:ok, spec} = Specs.approve(spec, "design")
    spec
  end

  test "remote task reorder clears selection, expansion and stale edits", %{conn: conn} do
    spec = open_spec()
    {:ok, view, _} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    view |> element("#task-0 input[type=checkbox]") |> render_click()
    view |> element("#task-0 button[phx-click=task_toggle]") |> render_click()
    view |> element("#task-0 button[phx-click=task_edit]") |> render_click()
    assert has_element?(view, "#task-edit-0")
    assert has_element?(view, "#task-0 input[checked]")

    {:ok, updated} = Specs.move_task(spec, 0, 1)
    send(view.pid, {:spec_updated, updated})
    refute has_element?(view, "#task-edit-0")
    refute has_element?(view, "#task-0 input[checked]")
    assert has_element?(view, "#task-0 button[aria-expanded=false]")

    render_submit(view, "task_save", %{i: "0", title: "Stale edit"})
    assert Enum.map(Specs.task_list(Specs.get_spec(spec.id)), & &1.title) == ["Second", "First"]
  end

  test "nonstructural remote changes keep task selection and editing", %{conn: conn} do
    spec = open_spec()
    {:ok, view, _} = live(conn, ~p"/specs/#{spec.id}?step=tasks")
    view |> element("#task-0 input[type=checkbox]") |> render_click()
    view |> element("#task-0 button[phx-click=task_edit]") |> render_click()
    {:ok, updated} = Specs.update_spec(spec, %{name: "Renamed"})
    send(view.pid, {:spec_updated, updated})
    assert has_element?(view, "#task-edit-0")
    assert has_element?(view, "#task-0 input[checked]")
  end

  test "Next saves the submitted answer even without a debounced change", %{conn: conn} do
    spec = open_spec()

    questions = [
      %{"question" => "Which route?", "why" => "", "options" => ["/a", "/b"]},
      %{"question" => "Which name?", "why" => "", "options" => ["x", "y"]}
    ]

    spec
    |> Ecto.Changeset.change(plan: %{"status" => "questions", "questions" => questions})
    |> Factory.Repo.update!()

    {:ok, view, _} = live(conn, ~p"/specs/#{spec.id}?step=tasks&suggest")

    view
    |> form("#plan-answers", %{answer: %{"0" => "/a"}, other: %{"0" => "/typed"}})
    |> render_submit()

    assert has_element?(view, "#plan-answers input[name='answer[1]']")
    render_click(view, "plan_question", %{i: "0"})
    assert has_element?(view, "#plan-answers input[name='answer[0]'][value='__other'][checked]")
    assert has_element?(view, "#plan-answers input[name='other[0]'][value='/typed']")
  end

  test "the last submitted answer reaches task generation before debounce", %{conn: conn} do
    spec = open_spec()
    {:ok, view, _} = live(conn, ~p"/specs/#{spec.id}?step=tasks&suggest")
    Specs.subscribe(spec.id)
    view |> form("#plan-read", %{dir: File.cwd!()}) |> render_submit()
    assert_receive {:spec_updated, %{plan: %{"status" => "questions"}}}, 5_000
    render(view)

    view
    |> form("#plan-answers", %{answer: %{"0" => "/reset"}, other: %{"0" => "/account/reset"}})
    |> render_submit()

    assert_receive {:spec_updated, %{plan: %{"status" => "tasks"}}}, 5_000
    assert has_element?(view, "#plan-pick", "Add the reset route (account)")
  end
end
