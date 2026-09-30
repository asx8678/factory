defmodule FactoryWeb.UsageMeter do
  @moduledoc """
  The usage figure in the header: what Kiro has cost today, or in the run or spec
  the page shows (see `scope/2`). It updates live as calls to Kiro are recorded.
  Every LiveView gets it through `on_mount` and passes `@usage_meter` to the layout.
  The hook takes the `{:usage_recorded, event}` messages; a page that wants them too
  defines `usage_recorded(event, socket)`, which returns the socket.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias Factory.Usage

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Usage.subscribe()

    socket =
      socket
      |> assign(:usage_scope, :today)
      |> refresh()
      |> attach_hook(:usage_meter, :handle_info, fn
        {:usage_recorded, event}, socket -> {:halt, socket |> refresh() |> notify(event)}
        _msg, socket -> {:cont, socket}
      end)

    {:cont, socket}
  end

  # A page that shows usage itself (the Usage page) defines `usage_recorded/2`.
  defp notify(socket, event) do
    if function_exported?(socket.view, :usage_recorded, 2),
      do: socket.view.usage_recorded(event, socket),
      else: socket
  end

  @doc "Shows `{:run, id}`, `{:spec, id}` or `:today` in the header."
  def scope(socket, scope) do
    if socket.assigns[:usage_scope] == scope,
      do: socket,
      else: socket |> assign(:usage_scope, scope) |> refresh()
  end

  defp refresh(socket) do
    scope = socket.assigns[:usage_scope] || :today

    assign(
      socket,
      :usage_meter,
      Usage.totals(scope) |> Map.put(:scope, scope) |> Map.put(:limit, limit(scope))
    )
  end

  # A run's credit limit, where it pauses next (`Factory.Engine.credit_allowance/1`).
  defp limit({:run, id}) do
    case Factory.Runs.get_run(id) do
      nil -> nil
      run -> Factory.Engine.credit_allowance(run)
    end
  end

  defp limit(_scope), do: nil

  @doc "What the header figure covers."
  def label({:run, _}), do: "This run"
  def label({:spec, _}), do: "This spec"
  def label(_), do: "Today"
end
