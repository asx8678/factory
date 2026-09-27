defmodule FactoryWeb.SettingsLive do
  use FactoryWeb, :live_view

  @tabs [{"general", "General"}, {"models", "Models"}, {"keys", "API keys"}]

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Settings", tabs: @tabs)}

  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: Map.get(params, "tab", "general"))}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:settings}>
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
              <.field label="Default model" hint="New agents start with this model.">
                <select class="select w-full">
                  <option>claude-opus-5-5</option>
                  <option>claude-sonnet-5</option>
                  <option>claude-haiku-4-5</option>
                </select>
              </.field>
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

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :info, "Settings aren't stored yet. Nothing was saved.")}
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
