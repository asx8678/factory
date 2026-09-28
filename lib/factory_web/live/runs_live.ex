defmodule FactoryWeb.RunsLive do
  @moduledoc "Every run, newest first: factory runs and plain chats, with what each cost."
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts
  alias Factory.Runs

  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Runs")
     |> stream_configure(:runs, dom_id: &"run-#{&1.id}")
     |> load()}
  end

  defp load(socket) do
    runs = Runs.list_runs_with_usage()

    socket
    |> assign(:runs_empty?, runs == [])
    |> stream(
      :runs,
      Enum.map(runs, fn {run, totals} -> %{id: run.id, run: run, totals: totals} end),
      reset: true
    )
  end

  def handle_info({:runs_changed}, socket), do: {:noreply, load(socket)}

  @doc "Totals follow new calls to Kiro (called by FactoryWeb.UsageMeter)."
  def usage_recorded(_event, socket), do: load(socket)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:runs}>
      <Layouts.page_title
        title="Runs"
        subtitle="Every factory run and chat, newest first, with what it cost."
      >
        <:actions>
          <.link navigate={~p"/chat"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" class="size-4" /> New factory run
          </.link>
        </:actions>
      </Layouts.page_title>

      <p
        :if={@runs_empty?}
        class="rounded-xl border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/55"
      >
        No runs yet. Start one from the home page.
      </p>

      <ol id="runs" phx-update="stream" class="space-y-2">
        <li :for={{id, %{run: r, totals: totals}} <- @streams.runs} id={id}>
          <.link
            navigate={~p"/runs/#{r.id}"}
            class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-3 transition-colors hover:border-base-content/15"
          >
            <.type_badge kind={r.kind} />
            <span class="min-w-0 flex-1">
              <span class="block truncate font-medium">{r.title}</span>
              <span class="mt-0.5 flex flex-wrap items-center gap-x-3 text-xs text-base-content/50">
                <.run_state run={r} />
                <span :if={r.tasks != []} class="tabular-nums">
                  {Enum.count(r.tasks, &(&1.status == "done"))} of {length(r.tasks)} tasks done
                </span>
                <span :if={r.spec_doc}>Spec: {r.spec_doc.name}</span>
                <span>{Layouts.ago(r.updated_at)}</span>
              </span>
            </span>
            <.usage totals={totals} />
            <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/35" />
          </.link>
        </li>
      </ol>
    </Layouts.app>
    """
  end
end
