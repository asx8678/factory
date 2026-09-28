defmodule FactoryWeb.FactoryRunTest do
  # Not async: Kiro plans in a background task that needs the shared sandbox.
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Factory.{Launch, Runs, Specs, Usage}

  test "the start screen leads to a new run, which Kiro plans for review", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "What should the factory do?"
    assert has_element?(view, "#skip[href='/chat']")

    {:ok, view, _html} = view |> element("#new-bug") |> render_click() |> follow_redirect(conn)
    assert has_element?(view, "h1", "Fix a bug")
    assert has_element?(view, "#start-run[disabled]")
    # Recommended choices are already picked.
    assert render(view) =~ "Investigator"

    view
    |> form("#new-run", %{
      answers: %{happens: "Login sends me to the home page", expected: "Back to where I was"},
      settings: %{project_dir: File.cwd!()}
    })
    |> render_change()

    refute has_element?(view, "#start-run[disabled]")

    {:ok, view, _html} =
      view |> form("#new-run") |> render_submit() |> follow_redirect(conn)

    [run] = Enum.filter(Runs.list_runs(), & &1.kind)
    Runs.subscribe(run.id)
    assert run.kind == "bug"
    assert run.title == "Login sends me to the home page"
    assert run.description =~ "## What should happen instead?\n\nBack to where I was"

    assert_receive {:run_updated, %{plan: %{"status" => "done"}}}, 5_000
    assert has_element?(view, "#run-plan", "The redirect lives in session_controller.ex.")
    assert has_element?(view, "#run-next", "Review requirements")

    spec = Specs.get_spec(run.spec_id)
    assert spec.overview =~ "Login sends me to the home page"
    assert Specs.Spec.approved?(spec, "overview")
    refute Specs.Spec.approved?(spec, "requirements")
    assert spec.design =~ "session_controller.ex"
    assert [%{title: "Add a failing test for the redirect"}, _] = Specs.tasks(spec)

    # Kiro's planning, and later work on the spec, count as the run's usage.
    assert %{calls: 1, credits: 0.4} = Usage.totals({:run, run.id})
    {:ok, _} = Usage.record(%{source: "improve_task", spec_id: spec.id, credits: 0.1})
    assert %{calls: 2} = Usage.totals({:run, run.id})

    # Approving the spec makes the run the one that starts.
    {:ok, spec} = Specs.approve(spec, "requirements")
    {:ok, spec} = Specs.approve(spec, "design")
    {:ok, _spec} = Specs.approve(spec, "tasks")
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    view |> element("#run-next") |> render_click()
    assert_redirect(view, ~p"/chat/#{run.id}")
    assert [_, _] = Runs.get_run(run.id).tasks

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Login sends me to the home page"
  end

  test "without plan review, Kiro's choices apply and the run is queued", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/new?type=bug")

    view
    |> form("#new-run", %{
      answers: %{happens: "Crash on save"},
      settings: %{workflow_mode: "kiro", setup_mode: "kiro", approve_plan: "false"},
      save: %{on: "true"}
    })
    |> render_change()

    view |> form("#new-run", %{save: %{on: "true", name: "Hands-off bug"}}) |> render_submit()

    [run] = Enum.filter(Runs.list_runs(), & &1.kind)
    Runs.subscribe(run.id)
    assert_receive {:run_updated, %{status: "queued"}}, 5_000

    run = Runs.get_run(run.id)
    assert Enum.map(run.settings["workflow"], & &1["name"]) == ["Sleuth", "Fixer"]
    assert run.settings["model"] == "claude-haiku-4.5"
    assert length(run.tasks) == 2
    assert Specs.Spec.current_step(Specs.get_spec(run.spec_id)) == "ready"

    # The choices were saved, and start the next run.
    [setup] = Launch.list_setups()
    assert setup.name == "Hands-off bug"
    assert setup.settings["approve_plan"] == false

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#setup-#{setup.id}", "Hands-off bug")
    {:ok, view, _html} = live(conn, ~p"/new?setup=#{setup.id}")
    assert render(view) =~ "From your saved setup"
    refute has_element?(view, "input[name='settings[approve_plan]'][type=checkbox][checked]")
  end

  test "a manual workflow is edited step by step", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/new?type=feature")
    view |> form("#new-run", %{settings: %{workflow_mode: "manual"}}) |> render_change()
    assert has_element?(view, "#workflow-steps")

    view |> element("#workflow-steps button[phx-value-kind=writer]") |> render_click()
    assert has_element?(view, "input[name='wf[4][name]'][value=Writer]")

    view
    |> element("#workflow-steps li:first-child button[phx-click=wf_remove]")
    |> render_click()

    refute has_element?(view, "input[name='wf[4][name]']")
  end

  test "a plan without tasks can be tried again", %{conn: conn} do
    {:ok, run} =
      Launch.start("other", %{"what" => "no plan please"}, %{"project_dir" => File.cwd!()})

    Runs.subscribe(run.id)
    assert_receive {:run_updated, %{plan: %{"status" => "error"}}}, 5_000

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
    assert has_element?(view, "#run-plan", "Kiro's plan had no tasks.")
    view |> element("#run-plan button", "Try again") |> render_click()
    assert_receive {:run_updated, %{plan: %{"status" => "writing"}}}, 5_000
  end
end
