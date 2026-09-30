defmodule FactoryWeb.KiroStatus do
  @moduledoc """
  Whether Kiro is signed in, for the warning under the header: agents can't run while
  it isn't, and it's better to know before sending than from a failed reply. Every
  LiveView gets it through `on_mount` as `@kiro` and passes it to `Layouts.app`.

  It follows `Factory.Kiro.Catalog`: a check that fails because Kiro is signed out, or
  a Kiro that stopped for it, shows the warning; a check that works hides it. The
  warning's Check again button (`"kiro_check"`) is handled here, for every page. A
  page that wants the check's result too defines `kiro_checked(catalog, socket)`,
  which returns the socket.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias Factory.Kiro.Catalog

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()

    socket =
      socket
      |> assign(:kiro, %{signed_out: Catalog.signed_out?(), checking: false})
      |> attach_hook(:kiro_status, :handle_info, fn
        {:kiro_catalog, catalog}, socket ->
          socket = assign(socket, :kiro, %{signed_out: Catalog.signed_out?(), checking: false})

          if function_exported?(socket.view, :kiro_checked, 2),
            do: {:halt, socket.view.kiro_checked(catalog, socket)},
            else: {:halt, socket}

        _msg, socket ->
          {:cont, socket}
      end)
      |> attach_hook(:kiro_check, :handle_event, fn
        "kiro_check", _params, socket ->
          Catalog.check_later()
          {:halt, assign(socket, :kiro, %{socket.assigns.kiro | checking: true})}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end
