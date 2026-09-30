defmodule FactoryWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use FactoryWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the active menu item"

  attr :full, :boolean,
    default: false,
    doc: "fill the window below the header, without page padding"

  attr :usage, :map, default: nil, doc: "Kiro usage for the header, from FactoryWeb.UsageMeter"

  attr :active_runs, :integer,
    default: 0,
    doc: "queued and running runs for the header, from FactoryWeb.ActiveRuns"

  attr :kiro, :map,
    default: nil,
    doc:
      "whether Kiro is signed in and under its usage limit (`signed_out`, `limited`, `checking`), from FactoryWeb.KiroStatus"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  @menu [
    {:chat, "Chat", "/chat"},
    {:specs, "Specs", "/specs"},
    {:workflows, "Workflows", "/workflows"},
    {:runs, "Runs", "/runs"},
    {:usage, "Usage", "/usage"},
    {:settings, "Settings", "/settings"}
  ]

  def app(assigns) do
    assigns = assign(assigns, menu: @menu)

    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/85 backdrop-blur">
      <div class="mx-auto flex h-11 max-w-7xl items-stretch gap-3 px-4 sm:gap-5 sm:px-6">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 text-[14px] font-semibold tracking-tight"
        >
          <svg viewBox="0 0 20 20" class="size-5" aria-hidden="true">
            <path
              d="M10 4 L4 15 M10 4 L16 15 M4 15 L16 15"
              class="stroke-primary"
              stroke-width="1.5"
              fill="none"
            />
            <circle cx="10" cy="4" r="2.6" class="fill-primary" />
            <circle cx="4" cy="15" r="2.6" class="fill-primary" />
            <circle cx="16" cy="15" r="2.6" class="fill-primary" />
          </svg>
          Factory
        </.link>

        <nav class="-mb-px flex min-w-0 flex-1 items-stretch overflow-x-auto">
          <.link
            :for={{key, label, path} <- @menu}
            navigate={path}
            aria-current={@active == key && "page"}
            class={[
              "flex items-center whitespace-nowrap border-b-2 px-2.5 text-[13px] transition-colors",
              if(@active == key,
                do: "border-primary text-base-content font-medium",
                else: "border-transparent text-base-content/55 hover:text-base-content"
              )
            ]}
          >
            {label}
          </.link>
        </nav>

        <div class="flex items-center gap-4 text-sm">
          <.kiro_signed_out :if={@kiro && @kiro.signed_out} checking={@kiro.checking} />
          <.kiro_limited
            :if={@kiro && @kiro[:limited] && !@kiro.signed_out}
            checking={@kiro.checking}
          />
          <.link
            :if={@active_runs > 0}
            id="active-runs"
            navigate={~p"/runs"}
            class="hidden items-center gap-2 text-base-content/70 hover:text-base-content md:flex"
          >
            <span class="size-2 rounded-full bg-info"></span>
            {@active_runs} active {if @active_runs == 1, do: "run", else: "runs"}
          </.link>
          <.usage_meter :if={@usage} usage={@usage} />
          <.theme_toggle />
        </div>
      </div>
    </header>

    <main :if={@full} class="h-[calc(100dvh-2.75rem)] overflow-hidden">
      {render_slot(@inner_block)}
    </main>
    <main :if={!@full} class="mx-auto max-w-7xl px-4 py-6 sm:px-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :checking, :boolean, default: false

  # Agents can't run while Kiro is signed out: said before anything is sent, with how
  # to fix it and a way to check again (FactoryWeb.KiroStatus handles "kiro_check").
  defp kiro_signed_out(assigns) do
    ~H"""
    <div
      id="kiro-signed-out"
      role="status"
      class="flex items-center gap-2 rounded-full border border-warning/40 bg-warning/10 py-0.5 pr-1 pl-2.5 text-xs text-base-content/80"
    >
      <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0 text-warning" />
      <span class="whitespace-nowrap">
        Kiro isn't signed in<span class="hidden lg:inline">: run
        <code class="font-mono">kiro-cli login</code>
        in a terminal</span>
      </span>
      <button
        id="kiro-check"
        type="button"
        phx-click="kiro_check"
        disabled={@checking}
        class="rounded-full bg-base-100 px-2 py-0.5 font-medium text-base-content/75 shadow-sm transition-colors hover:text-base-content disabled:opacity-60"
      >
        {if @checking, do: "Checking…", else: "Check again"}
      </button>
    </div>
    """
  end

  attr :checking, :boolean, default: false

  # Kiro refused a prompt for its usage limit: nothing gets an answer until it resets.
  # Check again asks Kiro one word (FactoryWeb.KiroStatus handles "kiro_limit_check").
  defp kiro_limited(assigns) do
    ~H"""
    <div
      id="kiro-limited"
      role="status"
      class="flex items-center gap-2 rounded-full border border-warning/40 bg-warning/10 py-0.5 pr-1 pl-2.5 text-xs text-base-content/80"
    >
      <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0 text-warning" />
      <span class="whitespace-nowrap">
        Kiro's usage limit is reached<span class="hidden lg:inline">: agents can't answer until it resets</span>
      </span>
      <button
        id="kiro-limit-check"
        type="button"
        phx-click="kiro_limit_check"
        disabled={@checking}
        title="Asks Kiro for one word: free if it's still refused, a fraction of a credit if not"
        class="rounded-full bg-base-100 px-2 py-0.5 font-medium text-base-content/75 shadow-sm transition-colors hover:text-base-content disabled:opacity-60"
      >
        {if @checking, do: "Checking…", else: "Check again"}
      </button>
    </div>
    """
  end

  attr :usage, :map, required: true

  # Credits (exact, from Kiro) and tokens (estimated) for today or the page's run/spec.
  defp usage_meter(assigns) do
    ~H"""
    <.link
      id="usage-meter"
      navigate={~p"/usage"}
      title={"#{FactoryWeb.UsageMeter.label(@usage.scope)}: #{@usage.calls} #{if @usage.calls == 1, do: "call", else: "calls"} to Kiro, #{FactoryWeb.Usage.credits(@usage.credits)} credits, about #{FactoryWeb.Usage.tokens(@usage.tokens)} tokens (estimated)#{if @usage[:limit], do: ". It pauses at #{FactoryWeb.Usage.credits(@usage.limit)} credits to ask whether to go on."}"}
      class="hidden items-center gap-2 rounded-full border border-base-content/10 px-3 py-1 text-xs tabular-nums text-base-content/70 transition-colors hover:border-base-content/25 hover:text-base-content sm:flex"
    >
      <span class="text-base-content/45">{FactoryWeb.UsageMeter.label(@usage.scope)}</span>
      <span class="flex items-center gap-1">
        <.icon name="hero-bolt-micro" class="size-3.5 text-warning/80" />
        {FactoryWeb.Usage.credits(@usage.credits)}
        <span :if={@usage[:limit]} id="usage-limit" class="text-base-content/40">
          / {FactoryWeb.Usage.credits(@usage.limit)}
        </span>
      </span>
      <span class="text-base-content/50">≈{FactoryWeb.Usage.tokens(@usage.tokens)} tok</span>
    </.link>
    """
  end

  attr :status, :string, required: true
  attr :dot, :boolean, default: true

  def status_badge(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5 text-[13px]", status_text(@status)]}>
      <span :if={@dot} class="size-1.5 rounded-full bg-current"></span>
      {status_label(@status)}
    </span>
    """
  end

  # Covers agent statuses (idle, running, waiting, error, done), run statuses
  # (draft, queued, running, paused, done, cancelled) and task statuses (pending, ...).
  @labels %{
    "running" => "Running",
    "done" => "Done",
    "waiting" => "Waiting",
    "error" => "Failed",
    "draft" => "Draft",
    "queued" => "Queued",
    "paused" => "Paused",
    "cancelled" => "Cancelled",
    "pending" => "Pending",
    "verified" => "Verified"
  }

  def status_label(status), do: Map.get(@labels, status, "Idle")

  def status_text(s) when s in ["running", "queued"], do: "text-info"
  def status_text(s) when s in ["done", "verified"], do: "text-success"
  def status_text(s) when s in ["waiting", "paused"], do: "text-warning"
  def status_text("error"), do: "text-error"
  def status_text(_), do: "text-base-content/50"

  def status_dot(s) when s in ["running", "queued"], do: "bg-info"
  def status_dot(s) when s in ["done", "verified"], do: "bg-success"
  def status_dot(s) when s in ["waiting", "paused"], do: "bg-warning"
  def status_dot("error"), do: "bg-error"
  def status_dot(_), do: "bg-base-content/30"

  @doc "How long ago a time was. The server doesn't know the viewer's time zone, so no clock times."
  def ago(time) do
    case DateTime.diff(DateTime.utc_now(), time) do
      s when s < 60 -> "just now"
      s when s < 3600 -> "#{div(s, 60)} min ago"
      s when s < 86_400 -> "#{div(s, 3600)} h ago"
      s -> "#{div(s, 86_400)} d ago"
    end
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def page_title(assigns) do
    ~H"""
    <div class="mb-5 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 class="text-xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-0.5 text-[13px] text-base-content/60">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr :to, :string, required: true
  slot :inner_block, required: true

  def back_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="mb-2 inline-flex items-center gap-1 text-[13px] text-base-content/55 hover:text-base-content"
    >
      <.icon name="hero-chevron-left-mini" class="size-4" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      class="hidden size-7 place-items-center rounded-md text-base-content/60 hover:bg-base-300/60 hover:text-base-content dark:grid"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme="light"
      aria-label="Switch to light theme"
    >
      <.icon name="hero-sun-micro" class="size-4" />
    </button>
    <button
      class="grid size-7 place-items-center rounded-md text-base-content/60 hover:bg-base-300/60 hover:text-base-content dark:hidden"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme="dark"
      aria-label="Switch to dark theme"
    >
      <.icon name="hero-moon-micro" class="size-4" />
    </button>
    """
  end
end
