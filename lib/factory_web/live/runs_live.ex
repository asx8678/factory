defmodule FactoryWeb.RunsLive do
  use FactoryWeb, :live_view
  alias Factory.Runs

  def mount(_params, _session, socket), do: {:ok, assign(socket, runs: Runs.list_runs())}

  def handle_params(%{"id" => id}, _uri, socket) do
    case Runs.get_run(id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Run #{id} doesn't exist.") |> push_navigate(to: ~p"/runs")}

      run ->
        {:noreply, assign(socket, page_title: run.title, run: run, trace: Runs.trace(id))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, page_title: "Runs", run: nil)}

  attr :runs, :list, required: true

  def runs_table(assigns) do
    assigns = assign(assigns, :max, assigns.runs |> Enum.map(& &1.tokens) |> Enum.max(fn -> 1 end))

    ~H"""
    <p :if={@runs == []} class="border-y border-base-300 py-6 text-sm text-base-content/55">
      No runs yet. Runs show up here when an agent starts working on a task.
    </p>
    <div :if={@runs != []} class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="text-left text-[13px] text-base-content/55">
          <tr class="border-b border-base-300">
            <th class="py-2 pr-4 font-normal">Run</th>
            <th class="py-2 pr-4 font-normal">Agent</th>
            <th class="py-2 pr-4 font-normal">Status</th>
            <th class="py-2 pr-4 font-normal">Tokens</th>
            <th class="py-2 text-right font-normal">Started</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={r <- @runs}
            phx-click={JS.navigate(~p"/runs/#{r.id}")}
            class="cursor-pointer border-b border-base-300 hover:bg-base-200"
          >
            <td class="py-3 pr-4">
              <.link navigate={~p"/runs/#{r.id}"} class="font-medium">{r.title}</.link>
              <span class="ml-2 font-mono text-[10px] text-base-content/45">{r.id}</span>
            </td>
            <td class="py-3 pr-4 text-base-content/75">{r.agent_name}</td>
            <td class="py-3 pr-4"><Layouts.status_badge status={r.status} /></td>
            <td class="py-3 pr-4">
              <span class="flex items-center gap-3">
                <span class="h-1 w-20 overflow-hidden rounded-full bg-base-300">
                  <span class="block h-full bg-base-content/45" style={"width: #{round(r.tokens / @max * 100)}%"}></span>
                </span>
                <span class="tabular-nums text-base-content/75">{Float.round(r.tokens / 1000, 1)}k</span>
              </span>
            </td>
            <td class="whitespace-nowrap py-3 text-right text-base-content/55">{r.started}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def render(%{run: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <Layouts.page_title title="Runs" subtitle="Every time an agent takes on a task, newest first." />
      <.runs_table runs={@runs} />
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <Layouts.back_link to={~p"/runs"}>Runs</Layouts.back_link>
      <Layouts.page_title title={@run.title}>
        <:actions>
          <button :if={@run.status in ["running", "waiting"]} class="btn btn-sm">Stop run</button>
          <button :if={@run.status == "error"} class="btn btn-primary btn-sm">Retry run</button>
        </:actions>
      </Layouts.page_title>

      <dl class="-mt-4 mb-10 flex flex-wrap gap-x-10 gap-y-3 text-sm">
        <div><dt class="text-base-content/55">Status</dt><dd><Layouts.status_badge status={@run.status} /></dd></div>
        <div>
          <dt class="text-base-content/55">Started by</dt>
          <dd><.link navigate={~p"/graph/#{@run.agent_id}"} class="text-primary hover:underline">{@run.agent_name}</.link></dd>
        </div>
        <div><dt class="text-base-content/55">Started</dt><dd>{@run.started}</dd></div>
        <div><dt class="text-base-content/55">Tokens</dt><dd class="tabular-nums">{Float.round(@run.tokens / 1000, 1)}k</dd></div>
        <div><dt class="text-base-content/55">Cost</dt><dd class="tabular-nums">${@run.cost}</dd></div>
        <div><dt class="text-base-content/55">Run ID</dt><dd class="font-mono text-[12px]">{@run.id}</dd></div>
      </dl>

      <h2 class="mb-4 font-semibold">Trace</h2>
      <ol class="max-w-3xl">
        <li :for={s <- @trace} class="grid grid-cols-[2rem_minmax(0,1fr)] gap-4">
          <div class="flex flex-col items-center">
            <span class="grid size-7 place-items-center rounded-full border border-base-300 bg-base-200 text-xs tabular-nums text-base-content/70">
              {s.step}
            </span>
            <span class="w-px flex-1 bg-base-300"></span>
          </div>
          <div class="pb-6">
            <p class="text-sm">
              <span class="font-semibold">{s.agent_name}</span>
              <span class="text-base-content/55">{kind_label(s.kind)}</span>
            </p>
            <p class={[
              "mt-1.5 text-sm",
              s.kind == "tool" && "rounded-md bg-base-200 px-3 py-2 font-mono text-[11.5px]"
            ]}>
              {s.text}
            </p>
          </div>
        </li>
      </ol>
    </Layouts.app>
    """
  end

  defp kind_label("plan"), do: "made a plan"
  defp kind_label("message"), do: "replied"
  defp kind_label("tool"), do: "used a tool"
  defp kind_label(k), do: k
end
