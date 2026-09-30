defmodule FactoryWeb.UsageLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.{Runs, Specs, Usage}

  test "shows the month, the day's sessions and each session's calls", %{conn: conn} do
    {:ok, run} = Runs.create_run("Fix login")
    {:ok, spec} = Specs.create_spec("CSV export")

    {:ok, _} =
      Usage.record(%{source: "agent_turn", run_id: run.id, credits: 0.5, input_tokens: 2000})

    {:ok, _} = Usage.record(%{source: "review", spec_id: spec.id, credits: 1.25})

    {:ok, view, _html} = live(conn, ~p"/usage")
    assert has_element?(view, "#usage-chart")
    assert has_element?(view, "#usage-meter", "1.75")
    assert has_element?(view, "#usage-sessions li:first-child", "CSV export")

    # A session opens to its calls.
    view |> element("#session-run-#{run.id} a") |> render_click()
    assert has_element?(view, "#session-run-#{run.id} table", "Agent chat")

    # Filter by the kind of work; the other session goes.
    view |> form("#usage-filters", %{source: "review", sort: "most"}) |> render_change()
    assert has_element?(view, "#session-spec-#{spec.id}")
    refute has_element?(view, "#session-run-#{run.id}")

    # New calls show up live, in the header too.
    {:ok, _} = Usage.record(%{source: "review", spec_id: spec.id, credits: 1.0})
    assert has_element?(view, "#usage-meter", "2.75")

    # The same days as a table.
    {:ok, view, _html} = live(conn, ~p"/usage?view=table")
    assert has_element?(view, "#usage-days")
  end
end
