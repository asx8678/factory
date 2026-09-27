defmodule FactoryWeb.AgentsLive do
  use FactoryWeb, :live_view
  alias Factory.{Agents, Runs}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Agents.subscribe()
    {:ok, socket}
  end

  def handle_info({:graph_changed}, %{assigns: %{agent: nil}} = socket) do
    {:noreply, assign(socket, agents: Agents.list_agents())}
  end

  def handle_info({:graph_changed}, socket) do
    case Agents.get_agent(socket.assigns.agent.id) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/agents")}
      agent -> {:noreply, assign(socket, agent: agent, neighbours: Agents.neighbours(agent.id))}
    end
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Agents.get_agent(id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "That agent no longer exists.") |> push_navigate(to: ~p"/agents")}

      agent ->
        {:noreply,
         assign(socket,
           page_title: agent.name,
           agent: agent,
           neighbours: Agents.neighbours(agent.id),
           runs: Runs.list_runs_for(agent.id)
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, page_title: "Agents", agent: nil, agents: Agents.list_agents())}
  end

  # New agents go below the last one so they don't cover anything in the graph.
  def handle_event("new", _, socket) do
    {x, y} =
      case List.last(socket.assigns.agents) do
        nil -> {0.0, 0.0}
        last -> {last.x, last.y + 140}
      end

    {:ok, agent} = Agents.add_agent(x, y)
    {:noreply, push_navigate(socket, to: ~p"/graph/#{agent.id}")}
  end

  def render(%{agent: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:agents}>
      <Layouts.page_title title="Agents" subtitle="Each agent has a job, a model and the agents it works with.">
        <:actions>
          <button phx-click="new" class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" class="size-4" /> New agent
          </button>
        </:actions>
      </Layouts.page_title>

      <ul :if={@agents != []} class="divide-y divide-base-300 border-y border-base-300">
        <li :for={a <- @agents}>
          <.link
            navigate={~p"/agents/#{a.id}"}
            class="grid gap-x-6 gap-y-1 px-2 py-4 hover:bg-base-200 sm:grid-cols-[12rem_minmax(0,1fr)_auto] sm:items-center"
          >
            <span>
              <span class="block font-semibold">{a.name}</span>
              <Layouts.status_badge status={a.status} />
            </span>
            <span class={["min-w-0 text-[15px]", a.role == "" && "text-base-content/40"]}>
              {if a.role == "", do: "No job described yet", else: a.role}
            </span>
            <span class="font-mono text-[11px] text-base-content/55">{a.model}</span>
          </.link>
        </li>
      </ul>
      <p :if={@agents == []} class="text-base-content/60">No agents yet. Add one to start your graph.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:agents}>
      <Layouts.back_link to={~p"/agents"}>Agents</Layouts.back_link>
      <Layouts.page_title title={@agent.name} subtitle={@agent.role != "" && @agent.role}>
        <:actions>
          <.link navigate={~p"/graph/#{@agent.id}"} class="btn btn-sm">Edit in graph</.link>
        </:actions>
      </Layouts.page_title>

      <div class="grid gap-10 lg:grid-cols-[20rem_minmax(0,1fr)]">
        <section>
          <h2 class="mb-2 font-semibold">Setup</h2>
          <dl class="divide-y divide-base-300 border-y border-base-300 text-sm">
            <div class="flex justify-between gap-4 py-3">
              <dt class="text-base-content/55">Status</dt>
              <dd><Layouts.status_badge status={@agent.status} /></dd>
            </div>
            <div class="flex justify-between gap-4 py-3">
              <dt class="text-base-content/55">Model</dt>
              <dd class="font-mono text-[12px]">{@agent.model}</dd>
            </div>
            <div class="flex justify-between gap-4 py-3">
              <dt class="text-base-content/55">Hands off to</dt>
              <dd class="text-right">{names(@neighbours.hands_off_to)}</dd>
            </div>
            <div class="flex justify-between gap-4 py-3">
              <dt class="text-base-content/55">Receives from</dt>
              <dd class="text-right">{names(@neighbours.receives_from)}</dd>
            </div>
          </dl>
        </section>

        <section>
          <h2 class="mb-2 font-semibold">Runs</h2>
          <FactoryWeb.RunsLive.runs_table runs={@runs} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp names([]), do: "None"
  defp names(agents), do: Enum.map_join(agents, ", ", & &1.name)
end
