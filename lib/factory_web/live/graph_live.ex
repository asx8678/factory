defmodule FactoryWeb.GraphLive do
  use FactoryWeb, :live_view
  alias Factory.Agents
  alias Factory.Agents.Agent

  def mount(_params, _session, socket) do
    if connected?(socket), do: Agents.subscribe()
    {:ok, assign(socket, page_title: "Graph", graph: Agents.graph(), selected: nil, form: nil)}
  end

  # Another tab changed the graph. Close the panel if its agent was deleted there.
  def handle_info({:graph_changed}, socket) do
    case socket.assigns.selected && Agents.get_agent(socket.assigns.selected.id) do
      nil when socket.assigns.selected != nil -> {:noreply, socket |> refresh() |> push_patch(to: ~p"/graph")}
      _ -> {:noreply, refresh(socket)}
    end
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Agents.get_agent(id) do
      nil -> {:noreply, push_patch(socket, to: ~p"/graph")}
      agent -> {:noreply, select(socket, agent)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(selected: nil, form: nil) |> push_event("flow:select", %{id: nil})}
  end

  # Events from the Svelte Flow canvas

  def handle_event("select", %{"id" => id}, socket), do: {:noreply, push_patch(socket, to: ~p"/graph/#{id}")}

  def handle_event("deselect", _, socket) do
    {:noreply, if(socket.assigns.selected, do: push_patch(socket, to: ~p"/graph"), else: socket)}
  end

  def handle_event("move", %{"nodes" => positions}, socket) do
    Agents.move_agents(positions)
    {:noreply, assign(socket, graph: Agents.graph())}
  end

  def handle_event("connect", %{"source" => source, "target" => target}, socket) do
    Agents.link(int(source), int(target))
    {:noreply, refresh(socket)}
  end

  def handle_event("reconnect", %{"old" => old, "new" => new}, socket) do
    Agents.relink({int(old["source"]), int(old["target"])}, {int(new["source"]), int(new["target"])})
    {:noreply, refresh(socket)}
  end

  def handle_event("delete", %{"nodes" => nodes, "edges" => edges}, socket) do
    for %{"source" => s, "target" => t} <- edges, do: Agents.unlink(int(s), int(t))
    ids = Enum.map(nodes, &int/1)
    Agents.delete_agents(ids)
    {:noreply, socket |> refresh() |> close_if_deleted(ids)}
  end

  def handle_event("add_agent", %{"x" => x, "y" => y} = params, socket) do
    opts = [from: params["from"] && int(params["from"]), to: params["to"] && int(params["to"])]

    case Agents.add_agent(x, y, opts) do
      {:ok, agent} -> {:noreply, socket |> refresh() |> push_patch(to: ~p"/graph/#{agent.id}")}
      {:error, _} -> {:noreply, socket |> refresh() |> put_flash(:error, "Couldn't add the agent. Try again.")}
    end
  end

  # Events from the side panel

  def handle_event("save", %{"agent" => params}, socket) do
    case Agents.update_agent(socket.assigns.selected, params) do
      {:ok, agent} ->
        {:noreply, socket |> assign(selected: agent) |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
    end
  end

  def handle_event("delete_agent", _, socket) do
    Agents.delete_agents([socket.assigns.selected.id])
    {:noreply, socket |> refresh() |> push_patch(to: ~p"/graph")}
  end

  def handle_event("close", _, socket), do: {:noreply, push_patch(socket, to: ~p"/graph")}

  defp select(socket, agent) do
    socket
    |> assign(selected: agent, form: to_form(Agents.change_agent(agent)), neighbours: Agents.neighbours(agent.id))
    |> push_event("flow:select", %{id: to_string(agent.id)})
  end

  # Sends the saved graph back to the canvas so it always matches the database.
  defp refresh(socket) do
    graph = Agents.graph(socket.assigns.selected && socket.assigns.selected.id)
    socket = socket |> assign(graph: graph) |> push_event("flow:graph", graph)

    if agent = socket.assigns.selected && Agents.get_agent(socket.assigns.selected.id),
      do: assign(socket, selected: agent, neighbours: Agents.neighbours(agent.id)),
      else: socket
  end

  defp close_if_deleted(%{assigns: %{selected: %Agent{id: id}}} = socket, ids) do
    if id in ids, do: push_patch(socket, to: ~p"/graph"), else: socket
  end

  defp close_if_deleted(socket, _ids), do: socket

  defp int(id) when is_integer(id), do: id
  defp int(id) when is_binary(id), do: String.to_integer(id)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:graph}>
      <div class="mb-4 flex flex-wrap items-end justify-between gap-3">
        <h1 class="text-2xl font-semibold tracking-tight font-stretch-semi-condensed">Graph</h1>
        <p class="max-w-2xl text-sm text-base-content/60">
          Drag from the dot under an agent to another agent to draw an arrow. Drop it on empty space to
          create a new agent there. Select an agent or arrow and press Backspace to delete it.
        </p>
      </div>

      <div class="flex flex-col gap-4 lg:flex-row" phx-window-keydown={@selected && "close"} phx-key="Escape">
        <div class="min-w-0 flex-1 overflow-hidden rounded-box border border-base-300 bg-base-200">
          <div
            id="agent-flow"
            phx-hook="Flow"
            phx-update="ignore"
            data-graph={JSON.encode!(%{@graph | selected: @selected && to_string(@selected.id)})}
            class="h-[65vh] lg:h-[calc(100vh-12rem)]"
          >
          </div>
        </div>

        <aside
          :if={@selected}
          id={"panel-#{@selected.id}"}
          class="drawer-in rounded-box border border-base-300 bg-base-200 p-5 lg:w-[340px] lg:shrink-0"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h2 class="truncate text-xl font-semibold tracking-tight">{@selected.name}</h2>
              <Layouts.status_badge status={@selected.status} />
            </div>
            <.link
              patch={~p"/graph"}
              class="grid size-8 place-items-center rounded-md text-base-content/55 hover:bg-base-300 hover:text-base-content"
              aria-label="Close"
            >
              <.icon name="hero-x-mark-mini" class="size-5" />
            </.link>
          </div>

          <.form for={@form} id="agent-form" phx-change="save" phx-submit="save" class="mt-5">
            <.input field={@form[:name]} label="Name" phx-debounce="300" />
            <.input field={@form[:role]} label="Job" placeholder="What this agent does" phx-debounce="300" />
            <.input field={@form[:model]} type="select" label="Model" options={Agent.models()} />
            <p class="-mt-1 text-xs text-base-content/50">Changes save automatically.</p>
          </.form>

          <dl class="mt-5 divide-y divide-base-300 border-t border-base-300 text-sm">
            <div class="flex justify-between gap-4 py-2.5">
              <dt class="text-base-content/55">Hands off to</dt>
              <dd class="flex flex-wrap justify-end gap-x-2"><.agent_links agents={@neighbours.hands_off_to} /></dd>
            </div>
            <div class="flex justify-between gap-4 py-2.5">
              <dt class="text-base-content/55">Receives from</dt>
              <dd class="flex flex-wrap justify-end gap-x-2"><.agent_links agents={@neighbours.receives_from} /></dd>
            </div>
          </dl>

          <div class="mt-5 flex gap-2">
            <.link navigate={~p"/agents/#{@selected.id}"} class="btn btn-sm flex-1">Open agent page</.link>
            <button
              phx-click="delete_agent"
              data-confirm={"Delete #{@selected.name} and its arrows?"}
              class="btn btn-sm btn-ghost text-error"
            >
              Delete agent
            </button>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :agents, :list, required: true

  defp agent_links(assigns) do
    ~H"""
    <span :if={@agents == []} class="text-base-content/40">None</span>
    <.link :for={a <- @agents} patch={~p"/graph/#{a.id}"} class="text-primary hover:underline">{a.name}</.link>
    """
  end
end
