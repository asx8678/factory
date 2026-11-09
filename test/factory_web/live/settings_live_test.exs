defmodule FactoryWeb.SettingsLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "General shows how Factory is set up, with nothing pretending to save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-facts", "Kiro CLI")
    assert has_element?(view, "#settings-facts", "Loop passes")
    assert has_element?(view, "#settings-facts", "Sandbox")
    refute has_element?(view, "form")
    refute has_element?(view, "input[type=password]")
  end

  test "Runs sets the day's and the chat's limits", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=runs")

    view
    |> form("#budgets-form", budget: %{daily: "25", chat: "5"})
    |> render_submit()

    assert Factory.Engine.Credits.daily_limit() == 25.0
    assert Factory.Engine.Credits.chat_limit() == 5.0
  end

  test "Models lists Kiro's models; an unknown tab opens General", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=models")
    assert has_element?(view, "#kiro-models")
    assert has_element?(view, "#check-models")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=keys")
    assert has_element?(view, "#settings-facts")
  end
end
