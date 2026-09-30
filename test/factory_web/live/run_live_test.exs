defmodule FactoryWeb.RunLiveTest do
  use FactoryWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Factory.Runs

  test "a run's page shows its title and what it cost", %{conn: conn} do
    {:ok, run} = Runs.create_run("Add dark mode")
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "h1", "Add dark mode")
    assert has_element?(view, "#run-usage")
    assert has_element?(view, "a[href='/chat/#{run.id}']", "Open chat")
  end

  test "a run that doesn't exist sends you back to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/runs"}}} = live(conn, ~p"/runs/999999999")
  end

  test "an id that isn't a number doesn't crash the run or the chat page", %{conn: conn} do
    for path <- ["/runs/abc", "/chat/abc"] do
      case live(conn, path) do
        {:error, {:live_redirect, _}} -> :ok
        {:error, {:redirect, _}} -> :ok
        {:ok, _view, _html} -> :ok
      end
    end
  end
end
