defmodule FactoryWeb.HomeLive do
  @moduledoc """
  The start screen: pick a job for the factory, or carry on with a recent run, a
  saved setup, or a plain chat.
  """
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts
  alias Factory.{Launch, Runs}
  alias Factory.Runs.Types

  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()
    {:ok, socket |> assign(page_title: "Factory") |> load()}
  end

  defp load(socket) do
    assign(socket,
      runs: Launch.recent_runs(6),
      setups: Launch.list_setups(),
      # Each job's workflow as it is now (it can be changed under Workflows).
      chains: Map.new(Types.all(), &{&1.id, Factory.Workflows.recommended_steps(&1.id)})
    )
  end

  def handle_info({:runs_changed}, socket), do: {:noreply, load(socket)}

  @doc "Run totals follow new calls to Kiro (called by FactoryWeb.UsageMeter)."
  def usage_recorded(_event, socket), do: load(socket)

  def handle_event("delete_setup", %{"id" => id}, socket) do
    if setup = Launch.get_setup(id), do: Launch.delete_setup(setup)
    {:noreply, load(socket)}
  end

  def render(assigns) do
    {main, [other]} = Enum.split(Types.all(), 4)
    assigns = assign(assigns, main_types: main, other: other)

    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:home}>
      <section class="pt-2 sm:pt-6">
        <h1 class="text-3xl font-semibold tracking-tight font-stretch-semi-condensed sm:text-4xl">
          What should the factory do?
        </h1>
        <p class="mt-2 max-w-2xl text-base-content/60">
          Pick a job. The factory plans it as a spec with Kiro, sets up the agents for it and
          gets to work, stopping where you want to check.
        </p>

        <div id="job-types" class="mt-8 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.link
            :for={t <- @main_types}
            id={"new-#{t.id}"}
            navigate={~p"/new?#{[type: t.id]}"}
            class="job-card group flex flex-col rounded-2xl border border-base-300/70 bg-base-200/40 p-5 hover:-translate-y-0.5"
          >
            <span class="grid size-10 place-items-center rounded-xl bg-primary/12 text-primary">
              <.icon name={type_icon(t.id, :outline)} class="size-5" />
            </span>
            <span class="mt-4 text-[17px] font-semibold">{t.label}</span>
            <span class="mt-1 text-sm leading-relaxed text-base-content/60">{t.blurb}</span>
            <.chain steps={@chains[t.id]} class="mt-4 text-[11px]" />
          </.link>
        </div>

        <div class="mt-3 flex flex-wrap items-center gap-3 text-sm">
          <.link
            id={"new-#{@other.id}"}
            navigate={~p"/new?#{[type: @other.id]}"}
            class="inline-flex items-center gap-2 rounded-xl border border-dashed border-base-300 px-4 py-2.5 text-base-content/70 transition-colors hover:border-success/40 hover:bg-success/10 hover:text-base-content"
          >
            <.icon name={type_icon(@other.id, :micro)} class="size-4" /> {@other.label}
          </.link>
          <.link
            id="skip"
            navigate={~p"/chat"}
            class="inline-flex items-center gap-1 rounded-xl px-3 py-2.5 text-base-content/55 transition-colors hover:bg-success/10 hover:text-base-content"
          >
            Skip, just open a chat <.icon name="hero-arrow-right-micro" class="size-4" />
          </.link>
        </div>
      </section>

      <div class="mt-12 grid gap-10 lg:grid-cols-[1fr_20rem]">
        <section>
          <div class="mb-3 flex items-baseline justify-between">
            <h2 class="text-lg font-medium">Recent runs</h2>
            <.link navigate={~p"/runs"} class="text-sm text-base-content/55 hover:text-base-content">
              All runs →
            </.link>
          </div>

          <p
            :if={@runs == []}
            class="rounded-xl border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/55"
          >
            No factory runs yet. Pick a job above to start one.
          </p>

          <ol id="recent-runs" class="space-y-2">
            <li :for={{run, totals} <- @runs} id={"recent-#{run.id}"}>
              <.link
                navigate={~p"/runs/#{run.id}"}
                class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-3 transition-colors hover:border-base-content/15"
              >
                <.type_badge kind={run.kind} />
                <span class="min-w-0 flex-1">
                  <span class="block truncate font-medium">{run.title}</span>
                  <span class="mt-0.5 flex items-center gap-3">
                    <.run_state run={run} />
                    <span class="text-xs text-base-content/45">{Layouts.ago(run.updated_at)}</span>
                  </span>
                </span>
                <.usage totals={totals} />
                <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/35" />
              </.link>
            </li>
          </ol>
        </section>

        <aside>
          <h2 class="mb-3 text-lg font-medium">Saved setups</h2>
          <p :if={@setups == []} class="text-sm text-base-content/55">
            When you start a run you can save its choices here, to start the next one the same way.
          </p>
          <ul id="setups" class="space-y-1.5">
            <li
              :for={s <- @setups}
              id={"setup-#{s.id}"}
              class="group flex items-center gap-2 rounded-lg px-2 py-1.5 transition-colors hover:bg-success/10"
            >
              <.link
                navigate={~p"/new?#{[setup: s.id]}"}
                class="flex min-w-0 flex-1 items-center gap-2"
              >
                <.icon name={type_icon(s.kind, :micro)} class="size-4 shrink-0 text-primary" />
                <span class="truncate text-sm">{s.name}</span>
                <span class="text-xs text-base-content/45">{Types.short(s.kind)}</span>
              </.link>
              <button
                type="button"
                phx-click="delete_setup"
                phx-value-id={s.id}
                data-confirm={"Delete the setup “#{s.name}”?"}
                aria-label={"Delete #{s.name}"}
                class="grid size-6 place-items-center rounded text-base-content/40 opacity-0 hover:text-error group-hover:opacity-100 focus:opacity-100 [@media(hover:none)]:opacity-100"
              >
                <.icon name="hero-trash-micro" class="size-3.5" />
              </button>
            </li>
          </ul>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
