defmodule FactoryWeb.ActiveRuns do
  @moduledoc """
  How many runs are queued or running, for the header. Every LiveView gets it
  through `on_mount` as `@active_runs` and passes it to `Layouts.app`. It is counted
  once when the page mounts and again only when a run's status changes
  (`Factory.Runs.subscribe_active/0`), never on each render.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias Factory.Runs

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Runs.subscribe_active()

    socket =
      socket
      |> assign(:active_runs, Runs.count_active())
      |> attach_hook(:active_runs, :handle_info, fn
        {:active_runs_changed}, socket ->
          {:halt, assign(socket, :active_runs, Runs.count_active())}

        _msg, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
