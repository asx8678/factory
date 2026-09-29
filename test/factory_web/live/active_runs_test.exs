defmodule FactoryWeb.ActiveRunsTest do
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Factory.Runs

  test "the header counts active runs and follows status changes", %{conn: conn} do
    {:ok, run} = Runs.create_run("Fix login")
    {:ok, view, _html} = live(conn, ~p"/runs")
    refute has_element?(view, "#active-runs")

    {:ok, run} = Runs.update_run(run, %{status: "running"})
    assert has_element?(view, "#active-runs", "1 active run")

    # A progress write that keeps the status doesn't recount.
    {:ok, run} = Runs.update_run(run, %{progress: %{"current" => "agent-1"}})
    assert has_element?(view, "#active-runs", "1 active run")

    {:ok, _} = Runs.update_run(run, %{status: "paused"})
    refute has_element?(view, "#active-runs")
  end
end
