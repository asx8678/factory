defmodule FactoryWeb.RunLive do
  @moduledoc """
  One run and everything in it: what was asked for, its spec's progress, the
  workflow and folder, what happened, and what it cost.
  """
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts
  alias Factory.{Agents, Engine, Runs, Specs, Usage}
  alias FactoryWeb.UsageMeter, as: Fmt
  alias FactoryWeb.WorkflowMap

  def mount(%{"id" => id}, _session, socket) do
    case Runs.get_run(id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "That run doesn't exist.") |> push_navigate(to: ~p"/runs")}

      run ->
        if connected?(socket) do
          Runs.subscribe(run.id)
          if run.spec_id, do: Specs.subscribe(run.spec_id)
          # Agents say when they start and finish, for the workflow map.
          Agents.subscribe()
        end

        {:ok,
         socket
         |> FactoryWeb.UsageMeter.scope({:run, run.id})
         |> assign(page_title: run.title)
         |> load(run)}
    end
  end

  defp load(socket, run) do
    spec = run.spec_id && Specs.get_spec(run.spec_id)

    assign(socket,
      run: run,
      spec: spec,
      steps: Engine.steps(run),
      workflow: Factory.Workflows.for_run(run),
      totals: Usage.totals({:run, run.id}),
      by_source: by_source(run.id),
      messages: run.id |> Runs.list_messages() |> Enum.take(-12) |> Enum.reverse()
    )
  end

  # Credits by kind of work over the run's whole life, most first.
  defp by_source(run_id) do
    run_id
    |> then(&Usage.calls({:run, &1}, :all))
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, calls} ->
      {source, calls |> Enum.map(& &1.credits) |> Enum.sum(), length(calls)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  def handle_info({:run_updated, run}, socket), do: {:noreply, load(socket, run)}

  def handle_info({:message, _}, socket),
    do: {:noreply, load(socket, Runs.get_run(socket.assigns.run.id))}

  def handle_info({:spec_updated, _}, socket),
    do: {:noreply, load(socket, Runs.get_run(socket.assigns.run.id))}

  def handle_info({:graph_changed}, socket),
    do: {:noreply, assign(socket, steps: Engine.steps(socket.assigns.run))}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Usage figures follow new calls to Kiro (called by FactoryWeb.UsageMeter)."
  def usage_recorded(%{run_id: id}, %{assigns: %{run: %{id: id}}} = socket),
    do: load(socket, socket.assigns.run)

  def usage_recorded(_event, socket), do: socket

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active_runs={@active_runs} active={:runs}>
      <Layouts.back_link to={~p"/runs"}>Runs</Layouts.back_link>

      <div class="mb-8 flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex items-center gap-3">
            <.type_badge kind={@run.kind} />
            <.run_state run={@run} />
            <span class="text-xs text-base-content/45">Started {Layouts.ago(@run.inserted_at)}</span>
          </div>
          <h1 class="mt-2 text-3xl font-semibold tracking-tight font-stretch-semi-condensed sm:text-4xl">
            {@run.title}
          </h1>
        </div>
        <div class="flex items-center gap-2 pt-1">
          <.link :if={@spec} navigate={~p"/specs/#{@spec.id}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-document-text-mini" class="size-4" /> Spec
          </.link>
          <.link navigate={~p"/chat/#{@run.id}"} class="btn btn-primary btn-sm">
            <.icon name="hero-chat-bubble-left-right-mini" class="size-4" /> Open chat
          </.link>
        </div>
      </div>

      <div id="run-usage" class="mb-8 grid grid-cols-3 gap-3 sm:max-w-xl">
        <.stat label="Credits" value={Fmt.credits(@totals.credits)} />
        <.stat label="Tokens" value={"≈" <> Fmt.tokens(@totals.tokens)} />
        <.stat label="Calls to Kiro" value={to_string(@totals.calls)} />
      </div>

      <div class="grid gap-10 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="min-w-0 space-y-8">
          <section :if={@steps != []} id="run-workflow">
            <div class="mb-3 flex items-baseline justify-between gap-3">
              <h2 class="text-lg font-medium">Workflow</h2>
              <span :if={@workflow} class="text-sm text-base-content/55">{@workflow.name}</span>
            </div>
            <div class="overflow-x-auto rounded-xl border border-base-300/70 bg-base-200/30 px-5 py-5">
              <WorkflowMap.map
                id="run-map"
                steps={@steps}
                states={WorkflowMap.states(@steps, @run)}
                size={:md}
                link={&agent_chat(&1, @run)}
              />
            </div>
          </section>

          <section :if={@spec} id="run-plan">
            <div class="mb-3 flex items-baseline justify-between">
              <h2 class="text-lg font-medium">Plan</h2>
              <.link
                navigate={~p"/specs/#{@spec.id}"}
                class="text-sm text-base-content/55 hover:text-base-content"
              >
                Open spec →
              </.link>
            </div>
            <div class="rounded-xl border border-base-300/70 bg-base-200/40 px-4 py-4">
              <.spec_progress spec={@spec} />
            </div>
          </section>

          <section :if={@run.description != ""}>
            <h2 class="mb-3 text-lg font-medium">What you asked for</h2>
            <div
              id={"run-ask-#{@run.id}"}
              phx-hook="Markdown"
              phx-update="ignore"
              class="md rounded-xl border border-base-300/70 px-5 py-4 text-sm"
            >
              {FactoryWeb.Markdown.render(without_title(@run.description))}
            </div>
          </section>

          <section>
            <div class="mb-3 flex items-baseline justify-between">
              <h2 class="text-lg font-medium">What happened</h2>
              <.link
                navigate={~p"/chat/#{@run.id}"}
                class="text-sm text-base-content/55 hover:text-base-content"
              >
                Open chat →
              </.link>
            </div>
            <p :if={@messages == []} class="text-sm text-base-content/55">
              Nothing yet. The run's chat shows here as the factory works.
            </p>
            <ol id="run-activity" class="space-y-3 border-l border-base-300 pl-4">
              <li :for={m <- @messages} class="relative">
                <span class="absolute -left-[21px] top-1.5 size-2 rounded-full bg-base-300"></span>
                <div class="flex items-baseline gap-2 text-xs text-base-content/50">
                  <span class="font-medium text-base-content/75">
                    {m.author || if(m.role == "user", do: "You", else: "Factory")}
                  </span>
                  {Layouts.ago(m.inserted_at)}
                </div>
                <p class="mt-0.5 line-clamp-3 whitespace-pre-line text-sm text-base-content/75">
                  {m.body}
                </p>
              </li>
            </ol>
          </section>
        </div>

        <aside class="space-y-8 text-sm">
          <section>
            <h2 class="mb-2 font-medium">Setup</h2>
            <dl class="space-y-1.5">
              <div class="flex justify-between gap-3">
                <dt class="text-base-content/55">Workflow</dt>
                <dd class="truncate">
                  <.link
                    :if={@workflow}
                    navigate={~p"/workflows/#{@workflow.id}"}
                    class="hover:underline"
                  >
                    {@workflow.name}
                  </.link>
                  <span :if={!@workflow} class="text-base-content/55">Deleted</span>
                </dd>
              </div>
              <div class="flex flex-col gap-0.5">
                <dt class="text-base-content/55">Project folder</dt>
                <dd class="truncate font-mono text-xs" title={@run.settings["project_dir"]}>
                  {@run.settings["project_dir"]}
                </dd>
              </div>
            </dl>
          </section>

          <section id="run-usage-by-kind">
            <h2 class="mb-2 font-medium">Where the credits went</h2>
            <p :if={@by_source == []} class="text-base-content/55">No calls to Kiro yet.</p>
            <ul class="space-y-2">
              <li :for={{source, credits, calls} <- @by_source}>
                <div class="flex items-baseline justify-between gap-2">
                  <span>{Usage.source_label(source)}</span>
                  <span class="tabular-nums">
                    <span class="text-xs text-base-content/45">{calls}×</span>
                    <span class="font-medium">{Fmt.credits(credits)}</span>
                  </span>
                </div>
                <div class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-content/[0.06]">
                  <div
                    class="h-full rounded-full bg-primary"
                    style={"width: #{if @totals.credits > 0, do: max(credits / @totals.credits * 100, 2), else: 0}%"}
                  >
                  </div>
                </div>
              </li>
            </ul>
            <.link
              :if={@by_source != []}
              navigate={
                ~p"/usage?#{[month: Calendar.strftime(@run.inserted_at, "%Y-%m"), day: "all", open: "run-#{@run.id}"]}"
              }
              class="mt-3 inline-block text-xs text-base-content/55 hover:text-base-content"
            >
              Every call →
            </.link>
          </section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp stat(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/70 bg-base-200/30 px-3.5 py-2.5">
      <div class="text-[11px] text-base-content/55">{@label}</div>
      <div class="text-xl font-semibold tabular-nums tracking-tight">{@value}</div>
    </div>
    """
  end

  attr :spec, :map, required: true

  # The spec's four steps, each approved or not, linking to the spec.
  defp spec_progress(assigns) do
    ~H"""
    <ol class="mt-4 flex flex-wrap items-center gap-2 text-sm">
      <%= for {step, i} <- Enum.with_index(Specs.Spec.steps()) do %>
        <span :if={i > 0} class="h-px w-4 bg-base-300" aria-hidden="true"></span>
        <li>
          <.link
            navigate={~p"/specs/#{@spec.id}?step=#{step}"}
            class="flex items-center gap-1.5 rounded-md px-2 py-1 hover:bg-base-content/[0.06]"
          >
            <span
              :if={Specs.Spec.approved?(@spec, step)}
              class="grid size-4 place-items-center rounded-full bg-success text-success-content"
            >
              <.icon name="hero-check-micro" class="size-3" />
            </span>
            <span
              :if={!Specs.Spec.approved?(@spec, step)}
              class="size-4 rounded-full border border-base-content/30"
            ></span>
            {FactoryWeb.SpecLive.step_label(step)}
          </.link>
        </li>
      <% end %>
      <li class="ml-auto text-xs text-base-content/50">
        {length(Specs.tasks(@spec))} tasks
      </li>
    </ol>
    """
  end

  # The overview starts with "# Fix a bug: <title>"; the page already shows both.
  defp without_title(text), do: String.replace(text, ~r/\A#\s[^\n]*\n+/, "")

  # An agent's card opens the run's chat with that agent.
  defp agent_chat(%{kind: kind, agent: %{id: id}}, run) when kind != "action",
    do: ~p"/chat/#{run.id}?#{[agent: id]}"

  defp agent_chat(_step, _run), do: nil
end
