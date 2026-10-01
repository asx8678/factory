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

  Kiro's usage limit gets a warning of its own (`limited`), from a prompt it refused,
  until one is answered; its Check again (`"kiro_limit_check"`) asks Kiro one word.
  With pi installed, both warnings offer to run on pi instead (`"use_pi"`,
  `Factory.Runtime`); while Factory runs on pi there are no warnings about Kiro, and
  the header says it's on pi.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias Factory.Kiro.Catalog

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Catalog.subscribe()
      Factory.Runtime.subscribe()
    end

    socket =
      socket
      |> assign(:kiro, status())
      |> attach_hook(:kiro_status, :handle_info, fn
        {:kiro_catalog, catalog}, socket ->
          socket = assign(socket, :kiro, status())

          if function_exported?(socket.view, :kiro_checked, 2),
            do: {:halt, socket.view.kiro_checked(catalog, socket)},
            else: {:halt, socket}

        # The CLI the agents run on changed (`Factory.Runtime`): Kiro's warnings are
        # only for Kiro.
        {:runtime, _runtime}, socket ->
          {:cont, assign(socket, :kiro, status())}

        _msg, socket ->
          {:cont, socket}
      end)
      |> attach_hook(:kiro_check, :handle_event, fn
        "kiro_check", _params, socket ->
          Catalog.check_later()
          {:halt, assign(socket, :kiro, %{socket.assigns.kiro | checking: true})}

        "kiro_limit_check", _params, socket ->
          Catalog.check_limit_later()
          {:halt, assign(socket, :kiro, %{socket.assigns.kiro | checking: true})}

        # Under Kiro's usage limit warning, when pi is installed: carry on there.
        "use_pi", _params, socket ->
          Factory.Runtime.choose(:pi)
          {:halt, assign(socket, :kiro, status())}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  defp status do
    runtime = Factory.Runtime.current()

    %{
      signed_out: runtime == :kiro and Catalog.signed_out?(),
      limited: runtime == :kiro and Catalog.limited?(),
      checking: false,
      runtime: runtime,
      pi_model: Factory.Runtime.pi_model(),
      # whether the warnings can offer pi instead
      pi: runtime == :kiro and Factory.Runtime.available?(:pi)
    }
  end
end
