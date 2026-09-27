defmodule FactoryWeb.DashboardLive do
  use FactoryWeb, :live_view
  alias Factory.{Agents, Runs}

  def mount(_params, _session, socket) do
    if connected?(socket), do: Agents.subscribe()
    {:ok, socket |> assign(page_title: "Dashboard") |> load()}
  end

  def handle_info({:graph_changed}, socket) do
    socket = load(socket)
    {:noreply, push_event(socket, "flow:graph", socket.assigns.graph)}
  end

  defp load(socket) do
    agents = Agents.list_agents()
    runs = Runs.list_runs()
    working = Enum.filter(agents, &(&1.status == "running"))
    failed = Enum.filter(agents, &(&1.status == "error"))
    attention = Enum.filter(agents, &(&1.status in ["error", "waiting"])) |> Enum.sort_by(&(&1.status != "error"))

    totals = [
      {"Runs today", length(runs)},
      {"Tokens", runs |> Enum.map(& &1.tokens) |> Enum.sum() |> format_int()},
      {"Spent", "$" <> :erlang.float_to_binary(Enum.sum(Enum.map(runs, & &1.cost)) / 1, decimals: 2)}
    ]

    assign(socket,
      graph: Agents.graph(),
      agents: agents,
      runs: runs,
      working: working,
      attention: attention,
      headline: headline(agents, working, failed),
      totals: totals
    )
  end

  def handle_event("select", %{"id" => id}, socket), do: {:noreply, push_navigate(socket, to: ~p"/graph/#{id}")}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:dashboard}>
      <section class="mb-10 flex flex-wrap items-end justify-between gap-x-12 gap-y-6">
        <h1 class="max-w-3xl text-4xl font-semibold leading-[1.05] tracking-tight font-stretch-condensed sm:text-[3.4rem]">
          {@headline}
        </h1>
        <dl class="flex gap-8">
          <div :for={{label, value} <- @totals}>
            <dt class="text-[13px] text-base-content/55">{label}</dt>
            <dd class="mt-0.5 text-xl font-medium tabular-nums">{value}</dd>
          </div>
        </dl>
      </section>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)]">
        <section class="overflow-hidden rounded-box border border-base-300 bg-base-200">
          <div class="flex items-center justify-between px-5 pt-4">
            <h2 class="font-semibold">Agents</h2>
            <.link navigate={~p"/graph"} class="text-sm text-base-content/60 hover:text-base-content">
              Edit graph
            </.link>
          </div>
          <div
            id="dashboard-flow"
            phx-hook="Flow"
            phx-update="ignore"
            data-readonly="true"
            data-graph={JSON.encode!(@graph)}
            class="h-[360px]"
          >
          </div>
        </section>

        <div class="space-y-8">
          <section :if={@attention != []}>
            <h2 class="mb-2 font-semibold">Needs you</h2>
            <.agent_line :for={a <- @attention} agent={a} />
          </section>
          <section>
            <h2 class="mb-2 font-semibold">Working now</h2>
            <.agent_line :for={a <- @working} agent={a} />
            <p :if={@working == []} class="py-3 text-sm text-base-content/55">
              No agents are running right now.
            </p>
          </section>
        </div>
      </div>

      <section class="mt-12">
        <div class="mb-3 flex items-center justify-between">
          <h2 class="font-semibold">Recent runs</h2>
          <.link navigate={~p"/runs"} class="text-sm text-base-content/60 hover:text-base-content">All runs</.link>
        </div>
        <FactoryWeb.RunsLive.runs_table runs={@runs} />
      </section>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true

  defp agent_line(assigns) do
    ~H"""
    <.link navigate={~p"/graph/#{@agent.id}"} class="-mx-3 flex gap-3 rounded-lg px-3 py-2.5 hover:bg-base-200">
      <span class={["mt-2 size-2 shrink-0 rounded-full", Layouts.status_dot(@agent.status)]}></span>
      <span class="min-w-0">
        <span class="flex items-baseline gap-2">
          <span class="font-medium">{@agent.name}</span>
          <Layouts.status_badge status={@agent.status} dot={false} />
        </span>
        <span :if={@agent.role != ""} class="block text-sm text-base-content/60">{@agent.role}</span>
      </span>
    </.link>
    """
  end

  defp headline([], _, _), do: "No agents yet. Add your first one in the graph."
  defp headline(_, [], []), do: "All agents are idle."

  defp headline(_, working, failed) do
    [working_sentence(working), failed_sentence(failed)] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp working_sentence([]), do: nil
  defp working_sentence([a]), do: "#{a.name} is working."
  defp working_sentence(list) when length(list) <= 3, do: "#{names(list)} are working."
  defp working_sentence(list), do: "#{length(list)} agents are working."

  defp failed_sentence([]), do: nil
  defp failed_sentence([a]), do: "#{a.name} needs you."
  defp failed_sentence(list), do: "#{names(list)} need you."

  defp names(list) do
    {init, [last]} = list |> Enum.map(& &1.name) |> Enum.split(-1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp format_int(n), do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
end
