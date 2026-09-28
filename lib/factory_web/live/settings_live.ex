defmodule FactoryWeb.SettingsLive do
  use FactoryWeb, :live_view

  @tabs [{"general", "General"}, {"models", "Models"}, {"keys", "API keys"}]

  alias Factory.Kiro.Catalog

  def mount(_params, _session, socket) do
    if connected?(socket), do: Catalog.subscribe()
    {:ok, socket |> assign(page_title: "Settings", tabs: @tabs, checking: false) |> catalog()}
  end

  defp catalog(socket) do
    assign(socket,
      models: Catalog.models() || [],
      modes: Catalog.modes() || [],
      checked_at: Catalog.checked_at(),
      check_error: Catalog.error()
    )
  end

  # Asks Kiro which models it has; the answer comes back as {:kiro_catalog, _}.
  def handle_event("check_models", _, socket) do
    Catalog.check_later()
    {:noreply, assign(socket, checking: true)}
  end

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :info, "Settings aren't stored yet. Nothing was saved.")}
  end

  def handle_info({:kiro_catalog, _}, socket),
    do: {:noreply, socket |> assign(checking: false) |> catalog()}

  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: Map.get(params, "tab", "general"))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:settings}>
      <Layouts.page_title title="Settings" />

      <div class="grid gap-10 md:grid-cols-[12rem_minmax(0,1fr)]">
        <nav class="flex gap-1 md:flex-col">
          <.link
            :for={{key, label} <- @tabs}
            patch={~p"/settings?tab=#{key}"}
            class={[
              "rounded-md px-3 py-2 text-sm",
              if(@tab == key,
                do: "bg-base-200 font-medium",
                else: "text-base-content/60 hover:text-base-content"
              )
            ]}
          >
            {label}
          </.link>
        </nav>

        <form class="max-w-xl" phx-submit="save">
          <%= case @tab do %>
            <% "models" -> %>
              <section id="kiro-models" class="mb-8">
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <h2 class="font-medium">Models Kiro offers</h2>
                    <p class="mt-0.5 text-sm text-base-content/55">
                      Checked automatically when Factory starts. Every model picker uses this list.
                    </p>
                  </div>
                  <button
                    id="check-models"
                    type="button"
                    phx-click="check_models"
                    disabled={@checking}
                    class="btn btn-sm shrink-0"
                  >
                    <span :if={@checking} class="loading loading-spinner loading-xs"></span>
                    <.icon :if={!@checking} name="hero-arrow-path-mini" class="size-4" />
                    {if @checking, do: "Checking…", else: "Check now"}
                  </button>
                </div>

                <p class="mt-3 flex items-center gap-2 text-xs text-base-content/55">
                  <span class={[
                    "size-1.5 rounded-full",
                    cond do
                      @check_error -> "bg-warning"
                      @checked_at -> "bg-success"
                      true -> "bg-base-content/30"
                    end
                  ]}></span>
                  {cond do
                    @checked_at ->
                      "#{length(@models)} models · checked #{Layouts.ago(elem(DateTime.from_iso8601(@checked_at), 1))}"

                    true ->
                      "Not checked yet: using the list Factory ships with."
                  end}
                  <span :if={@check_error} class="text-warning">Last check failed: {@check_error}</span>
                </p>

                <ul
                  :if={@models != []}
                  class="mt-3 divide-y divide-base-300/70 rounded-xl border border-base-300/70"
                >
                  <li :for={m <- @models} class="flex items-baseline gap-3 px-3.5 py-2 text-sm">
                    <span class="w-40 shrink-0 truncate font-mono text-[12.5px]">{m["value"]}</span>
                    <span class="min-w-0 flex-1 truncate text-base-content/55">
                      {if m["description"] != "", do: m["description"], else: m["name"]}
                    </span>
                  </li>
                </ul>

                <details :if={@modes != []} class="mt-3 text-sm">
                  <summary class="cursor-pointer text-base-content/60 hover:text-base-content">
                    {length(@modes)} modes
                  </summary>
                  <ul class="mt-2 space-y-1 pl-4">
                    <li :for={m <- @modes}>
                      <span class="font-mono text-[12.5px]">{m["value"]}</span>
                      <span class="text-base-content/55"> · {m["description"]}</span>
                    </li>
                  </ul>
                </details>
              </section>
              <.field
                label="Daily spending limit"
                hint="Agents pause when today's cost reaches this amount."
              >
                <label class="input w-full"><span class="text-base-content/50">$</span><input
                  type="number"
                  value="25"
                /></label>
              </.field>
            <% "keys" -> %>
              <.field label="Anthropic API key" hint="Used by every agent to call Claude.">
                <input
                  type="password"
                  placeholder="sk-ant-…"
                  class="input w-full font-mono text-sm"
                />
              </.field>
              <.field label="GitHub token" hint="Lets agents read issues and open pull requests.">
                <input type="password" placeholder="ghp_…" class="input w-full font-mono text-sm" />
              </.field>
            <% _ -> %>
              <.field label="Workspace name">
                <input type="text" value="Factory" class="input w-full" />
              </.field>
              <.field label="Merging" hint="Agents open pull requests but a person merges them.">
                <label class="flex items-center gap-3 text-sm">
                  <input type="checkbox" class="toggle toggle-primary toggle-sm" checked />
                  Ask me before merging
                </label>
              </.field>
          <% end %>
          <button class="btn btn-primary btn-sm mt-2">Save changes</button>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div class="mb-6">
      <p class="mb-1.5 text-sm font-medium">{@label}</p>
      {render_slot(@inner_block)}
      <p :if={@hint} class="mt-1.5 text-[13px] text-base-content/55">{@hint}</p>
    </div>
    """
  end
end
