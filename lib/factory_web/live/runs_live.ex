defmodule FactoryWeb.RunsLive do
  @moduledoc "Every run, newest first: factory runs and plain chats, with what each cost."
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts
  alias Factory.Runs

  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Runs", runs_reload: nil)
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

  # The list changes with every progress write of every run, and the totals with every
  # call to Kiro; reload it once per short while rather than once per change.
  def handle_info({:runs_changed}, socket), do: {:noreply, reload_soon(socket)}

  def handle_info(:reload_runs, socket),
    do: {:noreply, socket |> assign(runs_reload: nil) |> load()}

  @doc "Totals follow new calls to Kiro (called by FactoryWeb.UsageMeter)."
  def usage_recorded(_event, socket), do: reload_soon(socket)

  defp reload_soon(socket) do
    if socket.assigns.runs_reload,
      do: socket,
      else: assign(socket, runs_reload: Process.send_after(self(), :reload_runs, 250))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      usage={@usage_meter}
      active_runs={@active_runs}
      kiro={@kiro}
      active={:runs}
    >
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

      <ol
        id="runs"
        phx-update="stream"
        class="divide-y divide-base-300/70 overflow-hidden rounded-lg border border-base-300/70 empty:hidden"
      >
        <li :for={{id, %{run: r, totals: totals}} <- @streams.runs} id={id}>
          <.link
            navigate={~p"/runs/#{r.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2 transition-colors hover:bg-base-content/[0.03]"
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
