defmodule FactoryWeb.SettingsLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "General shows how Factory is set up, with nothing pretending to save", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-facts", "Kiro CLI")
    assert has_element?(view, "#settings-facts", "Loop passes")
    refute has_element?(view, "form")
    refute has_element?(view, "input[type=password]")
  end

  test "Models lists Kiro's models; an unknown tab opens General", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings?tab=models")
    assert has_element?(view, "#kiro-models")
    assert has_element?(view, "#check-models")

    {:ok, view, _html} = live(conn, ~p"/settings?tab=keys")
    assert has_element?(view, "#settings-facts")
  end
end
