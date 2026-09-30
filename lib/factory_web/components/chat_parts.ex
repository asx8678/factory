defmodule FactoryWeb.ChatParts do
  @moduledoc """
  The chat page's pieces (`FactoryWeb.ChatLive`): the header controls (chat switcher,
  folder, workflow, view), the workflow strip, the greeting, messages and agent
  replies, and the message box. Events from them go to the chat LiveView.
  """
  use FactoryWeb, :html
  alias Factory.Workflows
  alias FactoryWeb.WorkflowMap

  # Before the run starts, a message to the agent that plans it (or to Factory, which
  # passes it on) is planned into tasks: the box says so.
  def placeholder(agent, run, planner \\ nil, job \\ nil)

  def placeholder(nil, run, planner, job) do
    cond do
      planner && settable?(run) && job == "review" ->
        "Paste a pull request's link or name a branch for #{planner.name}, or type / for commands"

      planner && settable?(run) ->
        "Describe a change for #{planner.name} to plan, or type / for commands"

      true ->
        "Message the factory, or type / for commands"
    end
  end

  def placeholder(agent, run, planner, job) do
    cond do
      planner && planner.id == agent.id && settable?(run) && job == "review" ->
        "Paste a pull request's link, or name the branch to review…"

      planner && planner.id == agent.id && settable?(run) ->
        "Describe a change, e.g. add an export button to the invoices page…"

      true ->
        "Message #{agent.name}…"
    end
  end

  # The agent a message goes to, or nil for the factory.
  def recipient(focus, _to) when focus != nil, do: focus
  def recipient(_focus, :factory), do: nil
  def recipient(_focus, to), do: to

  # The workflow and folder can change until the run starts.
  def settable?(nil), do: true
  def settable?(run), do: run.status == "draft"

  def chat_path(nil, nil), do: ~p"/chat"
  def chat_path(nil, agent), do: ~p"/chat?#{[agent: agent.id]}"
  def chat_path(run, nil), do: ~p"/chat/#{run.id}"
  def chat_path(run, agent), do: ~p"/chat/#{run.id}?#{[agent: agent.id]}"

  attr :dir, :string, required: true
  attr :ok, :boolean, required: true
  attr :warn, :boolean, required: true
  attr :locked, :boolean, required: true

  # Where the agents work: red until a folder is chosen, green once it is.
  def folder_button(assigns) do
    ~H"""
    <button
      id="folder-button"
      type="button"
      phx-click={!@locked && "browse"}
      disabled={@locked}
      title={if @ok, do: @dir, else: "Choose the folder the agents work in"}
      class={[
        "flex max-w-64 items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[13px] transition-colors disabled:cursor-default",
        if(@ok,
          do: "border-success/40 bg-success/[0.07] hover:border-success/70",
          else: "border-error/50 bg-error/[0.08] text-error hover:border-error"
        ),
        @warn && !@ok && "animate-pulse ring-2 ring-error/40"
      ]}
    >
      <span class={["size-2 shrink-0 rounded-full", if(@ok, do: "bg-success", else: "bg-error")]}></span>
      <.icon name="hero-folder-mini" class="size-4 shrink-0 opacity-70" />
      <span class="truncate">{if @ok, do: Path.basename(@dir), else: "Choose folder"}</span>
    </button>
    """
  end

  attr :workflows, :list, required: true
  attr :workflow, :map, required: true
  attr :locked, :boolean, required: true

  # The workflow the chat plans for: "Build a feature" unless another is picked.
  def workflow_picker(assigns) do
    ~H"""
    <div
      :if={@locked}
      id="workflow-picker"
      aria-disabled="true"
      class="flex items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-0.5 text-[13px]"
    >
      <.icon name={FactoryWeb.RunParts.workflow_icon(@workflow, :micro)} class="size-4 text-primary" />
      <span class="max-w-48 truncate">{@workflow.name}</span>
    </div>
    <details
      :if={!@locked}
      id="workflow-picker"
      class="relative"
      phx-click-away={JS.remove_attribute("open", to: "#workflow-picker")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-0.5 text-[13px] hover:bg-base-content/[0.06]">
        <.icon
          name={FactoryWeb.RunParts.workflow_icon(@workflow, :micro)}
          class="size-4 text-primary"
        />
        <span class="max-w-48 truncate">{@workflow.name}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute left-0 z-30 mt-1 w-72 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <p class="px-3 pb-1 pt-1.5 text-xs text-base-content/45">Workflow</p>
        <button
          :for={w <- @workflows}
          type="button"
          phx-click={
            JS.push("pick_workflow", value: %{id: w.id})
            |> JS.remove_attribute("open", to: "#workflow-picker")
          }
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            w.id == @workflow.id && "bg-base-200"
          ]}
        >
          <.icon name={FactoryWeb.RunParts.workflow_icon(w, :micro)} class="size-4 text-primary" />
          <span class="flex-1 truncate">{w.name}</span>
          <.icon :if={w.id == @workflow.id} name="hero-check-mini" class="size-4" />
        </button>
      </div>
    </details>
    """
  end

  attr :runs, :list, required: true
  attr :run, :any, required: true

  # The chat title doubles as the menu for switching chats.
  def chat_switcher(assigns) do
    ~H"""
    <details
      id="chat-switcher"
      class="relative min-w-0"
      phx-click-away={JS.remove_attribute("open", to: "#chat-switcher")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-1 rounded-full px-3 py-1 hover:bg-base-content/[0.06]">
        <span class="truncate text-[14px] font-semibold">{if @run, do: @run.title, else: "New run"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 shrink-0 opacity-50" />
      </summary>
      <div class="absolute left-0 z-30 mt-1 w-72 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <.link
          navigate={~p"/chat"}
          class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm font-medium hover:bg-base-content/[0.06]"
        >
          <.icon name="hero-pencil-square-mini" class="size-4" /> New run
        </.link>
        <p :if={@runs != []} class="px-3 pb-1 pt-2 text-xs text-base-content/45">Recent</p>
        <nav class="max-h-80 overflow-y-auto" aria-label="Chats">
          <.link
            :for={r <- @runs}
            navigate={~p"/chat/#{r.id}"}
            class={[
              "block rounded-xl px-3 py-2 text-sm",
              if(@run && @run.id == r.id, do: "bg-base-200", else: "hover:bg-base-content/[0.06]")
            ]}
          >
            <span class="block truncate">{r.title}</span>
            <span class="flex items-center gap-1.5 text-xs text-base-content/50">
              <span class={["size-1.5 rounded-full", Layouts.status_dot(r.status)]}></span>
              {Layouts.status_label(r.status) <>
                if(r.tasks != [], do: ", #{length(r.tasks)} tasks", else: "")}
            </span>
          </.link>
        </nav>
        <.link
          :if={@runs != []}
          id="all-runs"
          navigate={~p"/runs"}
          class="mt-1 flex items-center gap-2 rounded-xl px-3 py-2 text-xs text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content"
        >
          <.icon name="hero-queue-list-mini" class="size-4" /> All runs
        </.link>
      </div>
    </details>
    """
  end

  attr :steps, :list, required: true
  attr :focus, :any, required: true
  attr :run, :any, required: true

  # The workflow drawn small and live: who's busy, what's done, where it stopped. Click
  # an agent to chat with just that agent (again to go back); "All" shows everything.
  # The run's agents in one quiet line: a status dot and name each, a thin bar under
  # an agent whose context is filling up. A click shows only that agent's messages;
  # × goes back to all of them.
  def run_steps(assigns) do
    steps = Enum.reject(assigns.steps, &(&1.kind == "action" or &1.agent == nil))
    assigns = assign(assigns, steps: steps, states: WorkflowMap.states(steps, assigns.run))

    ~H"""
    <nav
      :if={@steps != []}
      id="flow-strip"
      aria-label="Workflow"
      class="flex min-w-0 items-center gap-0.5 overflow-x-auto text-xs [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <.link
        :if={@focus}
        id="agent-all"
        patch={chat_path(@run, nil)}
        title="Show every agent's messages"
        class="mr-0.5 grid size-5 shrink-0 place-items-center rounded text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
      >
        <.icon name="hero-x-mark-micro" class="size-3.5" />
      </.link>
      <%= for {step, i} <- Enum.with_index(@steps) do %>
        <.icon
          :if={i > 0}
          name="hero-chevron-right-micro"
          class="size-3 shrink-0 text-base-content/25"
        />
        <.link
          id={"chat-map-agent-#{step.agent.id}"}
          patch={chat_path(@run, if(@focus && @focus.id == step.agent.id, do: nil, else: step.agent))}
          title={step_title(step, @states[step.id])}
          class={[
            "relative flex shrink-0 items-center gap-1.5 rounded px-1.5 py-0.5 transition-colors",
            if(@focus && @focus.id == step.agent.id,
              do: "bg-base-content/10 font-medium text-base-content",
              else: "text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
            )
          ]}
        >
          <span class={["size-1.5 shrink-0 rounded-full", state_dot(@states[step.id])]}></span>
          {step.name}
          <span
            :if={FactoryWeb.Usage.level(step.agent.usage["context_pct"]) in ["mid", "high"]}
            class={["wf-ctx", "is-#{FactoryWeb.Usage.level(step.agent.usage["context_pct"])}"]}
            style={"width: #{min(step.agent.usage["context_pct"], 100)}%"}
            aria-hidden="true"
          ></span>
        </.link>
      <% end %>
    </nav>
    """
  end

  # "Coder: working (Using Read File)", with its context when it's in use.
  defp step_title(step, state) do
    activity =
      if state == :busy and step.agent.activity, do: " (#{step.agent.activity})", else: ""

    pct = step.agent.usage["context_pct"]

    context =
      if is_number(pct),
        do:
          " · Context #{FactoryWeb.Usage.pct(pct)} (compacts at #{FactoryWeb.Usage.compact_at()}%)",
        else: ""

    "#{step.name}: #{String.downcase(WorkflowMap.state_label(state))}#{activity}#{context}"
  end

  defp state_dot(:done), do: "bg-success"
  defp state_dot(:busy), do: "bg-info animate-pulse"
  defp state_dot(state) when state in [:waiting, :paused], do: "bg-warning"
  defp state_dot(:error), do: "bg-error"
  defp state_dot(_), do: "bg-base-content/25"

  attr :run, :any, required: true

  # Pause and Resume beside the agents while a run is under way or stopped.
  def run_control(assigns) do
    ~H"""
    <button
      :if={@run && @run.status in ["queued", "running"]}
      id="pause-run"
      type="button"
      phx-click="control"
      phx-value-command="/pause"
      title="Pause after the step that's working now"
      class="flex h-6 shrink-0 items-center gap-1 rounded-md px-1.5 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content"
    >
      <.icon name="hero-pause-micro" class="size-3.5" /> Pause
    </button>
    <button
      :if={@run && @run.status == "paused"}
      id="resume-run"
      type="button"
      phx-click="control"
      phx-value-command="/resume"
      title="Go on from the step it stopped at"
      class="flex h-6 shrink-0 items-center gap-1 rounded-md bg-primary/12 px-1.5 text-xs font-medium text-primary hover:bg-primary/20"
    >
      <.icon name="hero-play-micro" class="size-3.5" /> Resume
    </button>
    """
  end

  attr :view, :string, required: true
  attr :run, :any, required: true
  attr :workflow, :any, required: true

  # Less used views and pages, out of the toolbar.
  def more_menu(assigns) do
    ~H"""
    <details
      id="chat-more"
      class="relative shrink-0"
      phx-click-away={JS.remove_attribute("open", to: "#chat-more")}
    >
      <summary
        title="More"
        class="grid size-7 cursor-pointer list-none place-items-center rounded-md text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content [&::-webkit-details-marker]:hidden"
      >
        <.icon name="hero-ellipsis-horizontal-mini" class="size-4" />
      </summary>
      <div class="absolute right-0 z-30 mt-1 w-52 rounded-lg border border-base-content/10 bg-surface p-1 text-sm shadow-lg">
        <button
          id={if @view == "graph", do: "view-chat", else: "view-graph"}
          type="button"
          phx-click={
            JS.push("view", value: %{view: if(@view == "graph", do: "chat", else: "graph")})
            |> JS.remove_attribute("open", to: "#chat-more")
          }
          class="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left hover:bg-base-content/[0.06]"
        >
          <.icon
            name={
              if @view == "graph", do: "hero-chat-bubble-left-right-mini", else: "hero-share-mini"
            }
            class="size-4 text-base-content/55"
          />
          {if @view == "graph", do: "Back to the chat", else: "Show the workflow graph"}
        </button>
        <.link
          :if={@run && @run.kind}
          id="run-details"
          navigate={~p"/runs/#{@run.id}"}
          class="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-base-content/[0.06]"
        >
          <.icon name="hero-chart-bar-mini" class="size-4 text-base-content/55" /> Run details
        </.link>
        <.link
          :if={@workflow}
          navigate={~p"/workflows/#{@workflow.id}"}
          class="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-base-content/[0.06]"
        >
          <.icon name="hero-pencil-square-mini" class="size-4 text-base-content/55" />
          Edit the workflow
        </.link>
      </div>
    </details>
    """
  end

  # An agent's card opens the chat with it, or back with everyone if it's open already.

  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :dir, :string, default: ""
  attr :dir_ok, :boolean, default: false
  attr :workflow, :map, default: nil
  attr :uploads, :map, default: nil
  attr :specs, :integer, default: 0
  attr :chain, :list, default: []
  attr :last_run, :any, default: nil

  attr :scout, :any,
    default: nil,
    doc: "what there is to review in the folder (Factory.Scout): nil, :loading or a result"

  # A new chat: three quick steps, then describe the change and the planner plans it.
  # Set up (a folder is chosen): what the run is, in a small table you can change in
  # place, and the two ways to plan it. Left-aligned with the message box it leads to.
  # Review a PR, set up: a pull request's link, or a branch from the folder, the one
  # it's on first. Each starts the review as a message to the Scout.
  def greeting(%{focus: nil, dir_ok: true, workflow: %{key: "review"}} = assigns) do
    assigns = assign(assigns, picks: review_picks(assigns.scout))

    ~H"""
    <div id="chat-review" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        Review · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        What should we review in <span class="text-primary">{Path.basename(@dir)}</span>?
      </h1>
      <p class="mt-2 text-base-content/60">
        Paste a pull request's link, or pick a branch. The Scout finds the change and plans
        what to check; the Reviewer then reports what to fix.
      </p>

      <form
        id="review-pr-form"
        phx-submit="review_pr"
        class="mt-5 flex items-center gap-2 rounded-xl border border-base-300 bg-base-100 py-1.5 pl-3 pr-1.5 transition-colors focus-within:border-primary/50"
      >
        <.icon name="hero-link-mini" class="size-4 shrink-0 text-base-content/45" />
        <input
          name="url"
          autocomplete="off"
          placeholder="https://github.com/owner/repo/pull/123"
          class="h-7 min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-base-content/35"
        />
        <button class="btn btn-primary btn-sm">Review</button>
      </form>

      <section id="review-scout" class="mt-3 rounded-xl border border-base-300">
        <header class="flex items-center gap-2 border-b border-base-content/10 px-3.5 py-2">
          <.icon name="hero-code-bracket-square-mini" class="size-4 shrink-0 text-base-content/50" />
          <h2 class="min-w-0 flex-1 truncate text-xs font-medium text-base-content/70">
            <%= case @scout do %>
              <% {:ok, %{current: current, base: base}} when is_binary(current) -> %>
                On <span class="font-mono text-base-content">{current}</span>
                <span :if={base && base != current} class="font-normal text-base-content/50">
                  · compared with {base}
                </span>
              <% {:ok, _} -> %>
                Branches here
              <% _ -> %>
                Worth reviewing here
            <% end %>
          </h2>
          <button
            id="scout-again"
            type="button"
            phx-click="scout_again"
            title="Look at the branches again"
            class="grid size-6 shrink-0 place-items-center rounded-md text-base-content/45 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon
              name="hero-arrow-path-micro"
              class={["size-3.5", @scout == :loading && "animate-spin"]}
            />
          </button>
        </header>

        <p :if={@scout == :loading} class="px-3.5 py-3 text-[13px] text-base-content/55">
          Looking at the branches…
        </p>
        <p :if={match?({:error, _}, @scout)} class="px-3.5 py-3 text-[13px] text-base-content/60">
          {elem(@scout, 1)} Paste a pull request's link above instead.
        </p>

        <ol :if={@picks != []} class="divide-y divide-base-content/[0.07]">
          <li :for={pick <- @picks} class="flex items-center gap-3 px-3.5 py-2.5">
            <.icon
              name={
                case pick.kind do
                  :pr -> "hero-arrow-top-right-on-square-micro"
                  :changes -> "hero-pencil-square-micro"
                  :recent -> "hero-clock-micro"
                  _ -> "hero-arrows-right-left-micro"
                end
              }
              class="size-3.5 shrink-0 text-base-content/40"
            />
            <div class="min-w-0 flex-1">
              <p class="flex min-w-0 items-center gap-1.5 text-sm">
                <span class={["truncate", pick.kind == :branch && "font-mono text-[13px]"]}>
                  {pick.label}
                </span>
                <span
                  :if={pick[:current]}
                  class="shrink-0 rounded bg-primary/10 px-1.5 text-[10.5px] font-medium text-primary"
                >
                  checked out
                </span>
                <span :if={pick[:ahead]} class="shrink-0 text-xs text-base-content/50">
                  {pick.ahead} ahead
                </span>
              </p>
              <p class="truncate text-xs text-base-content/50">
                {pick.detail}<span :if={pick.at}> · {Layouts.ago(pick.at)}</span>
              </p>
            </div>
            <button
              :if={pick.kind == :branch}
              type="button"
              phx-click="review_branch"
              phx-value-branch={pick.value}
              class="btn btn-ghost btn-sm shrink-0"
            >
              Review
            </button>
            <button
              :if={pick.kind == :pr}
              type="button"
              phx-click="review_pr"
              phx-value-url={pick.value}
              class="btn btn-ghost btn-sm shrink-0"
            >
              Review
            </button>
            <button
              :if={pick.kind in [:changes, :recent]}
              type="button"
              phx-click="review_local"
              phx-value-what={pick.kind}
              class="btn btn-ghost btn-sm shrink-0"
            >
              Review
            </button>
          </li>
        </ol>

        <p
          :if={match?({:ok, _}, @scout) and @picks == []}
          class="px-3.5 py-3 text-[13px] text-base-content/60"
        >
          Nothing to review here yet: no commits or changes. Paste a pull request's link above.
        </p>

        <p
          :if={scout_notes(@scout) != []}
          class="border-t border-base-content/10 px-3.5 py-2 text-xs text-base-content/50"
        >
          {Enum.join(scout_notes(@scout), " ")}
        </p>
      </section>
    </div>
    """
  end

  def greeting(%{focus: nil, dir_ok: true} = assigns) do
    ~H"""
    <div id="chat-ready" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        New run · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        What are we building in <span class="text-primary">{Path.basename(@dir)}</span>?
      </h1>

      <p class="mt-2 text-base-content/60">
        Describe the change below. {if is_map(@to), do: @to.name, else: "The planner"} reads
        the code, asks about anything unclear, and lists the tasks for you to refine.
      </p>

      <div :if={examples(@workflow) != []} id="examples" class="mt-4 flex flex-wrap gap-1.5">
        <button
          :for={ex <- examples(@workflow)}
          type="button"
          phx-click={JS.dispatch("factory:fill", to: "#chat-input", detail: %{text: ex})}
          class="rounded-full border border-base-300 px-3 py-1 text-[13px] text-base-content/70 transition-colors hover:border-primary/40 hover:bg-primary/[0.05] hover:text-base-content"
        >
          {ex}
        </button>
      </div>

      <div class="mt-6 flex flex-wrap items-center gap-3 border-t border-base-300/60 pt-3 text-xs text-base-content/50">
        <.link
          :if={@last_run}
          id="last-run"
          navigate={~p"/chat/#{@last_run.id}"}
          class="flex min-w-0 items-center gap-2 hover:text-base-content"
        >
          <span class={["size-1.5 shrink-0 rounded-full", Layouts.status_dot(@last_run.status)]}></span>
          <span class="truncate">
            Last: <span class="text-base-content/75">{@last_run.title}</span>
            · {Layouts.status_label(@last_run.status)}
          </span>
          <span :if={@last_run.status == "paused"} class="shrink-0 font-medium text-warning">
            Resume →
          </span>
        </.link>
        <span class="ml-auto hidden items-center gap-3 sm:flex">
          <span><kbd class="launcher-kbd">⌘K</kbd> type</span>
          <span><kbd class="launcher-kbd">P</kbd> Tasks</span>
        </span>
      </div>
    </div>
    """
  end

  def greeting(%{focus: nil} = assigns) do
    ~H"""
    <div id="chat-start" class="mb-8 w-full max-w-xl">
      <h1 class="text-center text-2xl font-semibold tracking-tight">
        {if Workflows.kind(@workflow) == "review",
          do: "What should we review?",
          else: "What should we build?"}
      </h1>
      <p class="mt-3 text-center text-base-content/60">
        Describe the change and {if is_map(@to), do: @to.name, else: "the planner"} turns it into tasks.
        Refine them together, then implement.
      </p>

      <ol class="mt-6 space-y-2">
        <li>
          <button
            type="button"
            phx-click="browse"
            class={[
              "flex w-full items-center gap-3 rounded-xl border px-4 py-3 text-left transition-colors",
              if(@dir_ok,
                do: "border-success/40 bg-success/[0.06] hover:border-success/70",
                else: "border-error/50 bg-error/[0.06] hover:border-error"
              )
            ]}
          >
            <span class={[
              "grid size-6 shrink-0 place-items-center rounded-full text-xs font-medium",
              if(@dir_ok, do: "bg-success text-success-content", else: "bg-error text-error-content")
            ]}>
              <.icon :if={@dir_ok} name="hero-check-micro" class="size-4" />
              <span :if={!@dir_ok}>1</span>
            </span>
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-medium">
                {if @dir_ok,
                  do: "Working in #{Path.basename(@dir)}",
                  else: "Choose the project folder"}
              </span>
              <span class="block truncate text-xs text-base-content/55">
                {if @dir_ok, do: @dir, else: "Required: where the agents read and change code"}
              </span>
            </span>
            <span class="text-xs text-base-content/55">{if @dir_ok, do: "Change", else: "Browse…"}</span>
          </button>
        </li>
      </ol>
    </div>
    """
  end

  def greeting(assigns) do
    ~H"""
    <div class="mb-8 max-w-xl text-center">
      <span class="mx-auto grid size-12 place-items-center rounded-xl bg-base-content/[0.06]">
        <.icon name="hero-cpu-chip" class="size-6" />
      </span>
      <h1 class="mt-3 text-2xl font-semibold tracking-tight">
        Chat with {@focus.name}
      </h1>
      <p class="mt-3 text-base-content/60">
        Runs on Kiro with {@focus.model} in {@focus.kiro_mode} mode. {if @focus.role != "",
          do: @focus.role <> "."}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :run, :any, required: true
  attr :agents, :list, required: true
  attr :focus, :any, required: true

  def message(%{message: %{role: "user"}} = assigns) do
    assigns = assign(assigns, :to, to_agent_name(assigns.message, assigns.agents, assigns.focus))

    # A plan review asked with the button, from before those requests went to the planner
    # only: not something the person wrote, so not shown.
    assigns = assign(assigns, :internal, Factory.ChatPlanner.review_message?(assigns.message))

    ~H"""
    <div id={@id} hidden={@internal} class="flex flex-col items-end gap-1">
      <span :if={@to} class="text-xs text-base-content/45">To {@to}</span>
      <div class="max-w-[85%] rounded-xl border border-base-300/70 bg-base-200 px-4 py-2.5 text-[14px] leading-relaxed">
        <.attachments names={@message.attachments} />
        <p :if={@message.body != ""} class="whitespace-pre-wrap break-words" phx-no-format>{rich(@message.body)}</p>
      </div>
    </div>
    """
  end

  # A scope check: its report is in the plan (FactoryWeb.PlanPanel), so here it's one
  # line that opens to the full text, and the plan isn't pushed out of view.
  def message(%{message: %{author: author, meta: %{"check" => true}}} = assigns)
      when is_binary(author) do
    ~H"""
    <details id={@id} class="group rounded-lg border border-base-content/10 text-sm">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content [&::-webkit-details-marker]:hidden">
        <.icon name="hero-magnifying-glass-micro" class="size-3.5" />
        <span class="font-medium text-base-content/75">Scope check</span>
        by {@message.author} · the report is in the plan
        <.icon
          name="hero-chevron-down-micro"
          class="ml-auto size-3.5 transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="md border-t border-base-content/10 px-3 py-2">
        {FactoryWeb.Markdown.render(FactoryWeb.PlanPanel.report(@message.body))}
      </div>
    </details>
    """
  end

  def message(%{message: %{author: author}} = assigns) when is_binary(author) do
    ~H"""
    <div id={@id}>
      <p
        :if={@message.meta["unclear"]}
        class="mb-2 inline-flex items-center gap-1.5 rounded-full bg-warning/12 px-2.5 py-0.5 text-xs font-medium text-warning"
      >
        <.icon name="hero-question-mark-circle-mini" class="size-4" />
        Not clear enough to plan yet: more information needed
      </p>
      <.agent_reply id={"md-#{@id}"} name={@message.author} body={@message.body} meta={@message.meta} />
      <p :if={@message.meta["unclear"]} class="mt-2 text-sm text-base-content/55">
        Answer below, and I'll make the tasks.
      </p>
      <.elicitation
        :if={@message.meta["elicitation"]}
        id={"elicitation-#{@message.id}"}
        message={@message}
      />
      <.question_form
        :if={answerable?(@message, @run)}
        id={"answers-#{@message.id}"}
        message={@message}
      />
      <.plan_card
        :if={@message.meta["tasks"] not in [nil, []]}
        id={"plan-#{@message.id}"}
        tasks={@message.meta["tasks"]}
        spec_hint={@message.meta["spec_hint"]}
        startable={
          "start" in @message.actions and startable?(@run) and
            Enum.map(@run.tasks, & &1.title) == @message.meta["tasks"]
        }
      />
    </div>
    """
  end

  def message(assigns) do
    ~H"""
    <div id={@id}>
      <p class="mb-1.5 flex items-center gap-2 text-sm">
        <span class="grid size-5 place-items-center rounded-md bg-primary text-primary-content">
          <.icon name="hero-bolt-solid" class="size-3" />
        </span>
        <span class="font-semibold">Factory</span>
      </p>
      <div id={"md-#{@id}"} class="md" phx-hook="Markdown" phx-update="ignore">
        {FactoryWeb.Markdown.render(@message.body)}
      </div>
      <button
        :if={"start" in @message.actions and startable?(@run)}
        id={"start-#{@message.id}"}
        phx-click="action"
        phx-value-action="start"
        class="mt-3 flex items-center gap-1.5 rounded-full bg-primary px-4 py-1.5 text-sm font-medium text-primary-content hover:opacity-90"
      >
        <.icon name="hero-play-mini" class="size-4" /> Start run
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true

  # A question a tool asks mid-turn (MCP elicitation, `Factory.Kiro.Session`): a form
  # from its schema while it's open (the agent waits), then what was answered.
  def elicitation(assigns) do
    e = assigns.message.meta["elicitation"]
    schema = e["schema"] || %{}
    required = schema["required"] || []
    props = schema["properties"] || %{}

    # A planner's question with options comes with an answer of your own beside it
    # (`answer_N_other`, `Factory.PlanTools`): shown under its options, not on its own.
    fields =
      for {name, prop} <- props, not own_answer_field?(name, props) do
        other = if Map.has_key?(props, name <> "_other"), do: name <> "_other"

        %{
          name: name,
          label: prop["title"] || prop["description"] || humanize(name),
          hint: if(prop["title"], do: prop["description"]),
          type: prop["type"],
          options: prop["enum"],
          labels: prop["enumNames"] || prop["enum"],
          default: prop["default"],
          required: name in required,
          other: other
        }
      end
      |> Enum.sort_by(&natural(&1.name))

    assigns = assign(assigns, e: e, fields: fields)

    ~H"""
    <form
      :if={@e["status"] == "open"}
      id={@id}
      phx-submit="elicit_answer"
      class="task-card-active mt-3 rounded-xl border"
    >
      <input type="hidden" name="key" value={@e["key"]} />
      <input type="hidden" name="agent_id" value={@message.meta["agent_id"]} />
      <.question_head
        who={@message.author}
        count={length(@fields)}
        waiting
      />
      <ol class="divide-y divide-base-content/[0.07]">
        <.question_row
          :for={{f, n} <- Enum.with_index(@fields, 1)}
          n={n}
          question={f.label}
          hint={f.hint}
        >
          <%= cond do %>
            <% f.options -> %>
              <.option_list
                name={"fields[#{f.name}]"}
                options={Enum.zip(f.options, f.labels)}
                checked={f.default || hd(f.options)}
                own={f.other && "fields[#{f.other}]"}
              />
            <% f.type == "boolean" -> %>
              <.option_list
                name={"fields[#{f.name}]"}
                options={[{"true", "Yes"}, {"false", "No"}]}
                checked={to_string(f.default == true)}
                recommend={false}
              />
            <% true -> %>
              <input
                type={if f.type in ["number", "integer"], do: "number", else: "text"}
                name={"fields[#{f.name}]"}
                value={f.default}
                required={f.required}
                autocomplete="off"
                class="h-8 w-full rounded-md border border-base-content/15 bg-base-100 px-2.5 text-[13px] outline-none focus:border-primary/50"
              />
          <% end %>
        </.question_row>
      </ol>
      <.question_foot note="It waits for your answers, then carries on.">
        <button
          type="submit"
          name="action"
          value="decline"
          formnovalidate
          class="btn btn-ghost btn-sm"
        >
          Decline
        </button>
        <button type="submit" name="action" value="accept" class="btn btn-primary btn-sm">
          Send answers
        </button>
      </.question_foot>
    </form>
    <div
      :if={@e["status"] == "answered"}
      id={@id}
      class="mt-3 rounded-xl border border-base-content/10 px-3.5 py-2.5 text-[13px]"
    >
      <p class="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-base-content/60">
        <.icon name="hero-check-circle-mini" class="size-4 text-success" /> You answered
      </p>
      <ol class="space-y-2">
        <li :for={{question, answer} <- answers(@e["answer"], @e["schema"])} class="leading-snug">
          <p class="text-xs text-base-content/50">{elem(split_question(question), 0)}</p>
          <p class="mt-0.5">{answer}</p>
        </li>
      </ol>
    </div>
    <p
      :if={@e["status"] not in ["open", "answered"]}
      id={@id}
      class="mt-2 text-xs text-base-content/55"
    >
      {if @e["status"] == "declined",
        do: "You declined to answer.",
        else: "No longer waiting: the turn ended before an answer."}
    </p>
    """
  end

  # Each answer with its question's title, or its field name when it has none: the
  # option picked, with the answer of your own written beside it.
  defp answers(answer, schema) when is_map(answer) do
    props = (schema || %{})["properties"] || %{}

    answer
    |> Enum.reject(fn {k, _} -> own_answer_field?(k, props) end)
    |> Enum.sort_by(&natural(elem(&1, 0)))
    |> Enum.map(fn {k, v} ->
      # "Different content (please describe)" reads as "Different content".
      v =
        case option_label(v) do
          {words, "please" <> _} -> words
          _ -> v
        end

      v =
        [v, answer[k <> "_other"]]
        |> Enum.map(&String.trim(to_string(&1 || "")))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(": ")

      {get_in(props, [k, "title"]) || humanize(k), v}
    end)
  end

  defp answers(_answer, _schema), do: []

  defp humanize(name), do: name |> to_string() |> String.replace("_", " ") |> String.capitalize()

  # A planner's questions with options can be answered by picking, while the run is
  # still being planned.
  defp answerable?(%{meta: meta}, run) do
    run != nil and run.status == "draft" and
      Enum.any?(meta["questions"] || [], &(&1["options"] not in [nil, []]))
  end

  attr :id, :string, required: true
  attr :message, :map, required: true

  # The planner's questions as choices: pick one option per question, or write your
  # own, then send them all as one message to the planner.
  def question_form(assigns) do
    assigns =
      assign(assigns,
        questions:
          for(
            {q, i} <- Enum.with_index(assigns.message.meta["questions"] || []),
            q["options"] not in [nil, []],
            do: {q, i}
          )
      )

    ~H"""
    <form id={@id} phx-submit="answer" class="task-card-active mt-3 rounded-xl border">
      <input type="hidden" name="message_id" value={@message.id} />
      <.question_head who={@message.author} count={length(@questions)} />
      <ol class="divide-y divide-base-content/[0.07]">
        <.question_row :for={{q, i} <- @questions} n={i + 1} question={q["question"]}>
          <.option_list
            name={"answers[#{i}]"}
            options={Enum.map(q["options"], &{&1, &1})}
            checked={hd(q["options"])}
            own={"others[#{i}]"}
          />
        </.question_row>
      </ol>
      <.question_foot note="Your answers go to the planner as one message.">
        <button type="submit" class="btn btn-primary btn-sm">Send answers</button>
      </.question_foot>
    </form>
    """
  end

  attr :who, :string, required: true
  attr :count, :integer, required: true
  attr :waiting, :boolean, default: false

  # A question card's header: who's asking, and whether they're waiting now.
  defp question_head(assigns) do
    ~H"""
    <header class="flex items-center gap-2 border-b border-base-content/10 px-3.5 py-2.5">
      <.icon name="hero-question-mark-circle-mini" class="size-4 shrink-0 text-primary" />
      <h3 class="min-w-0 flex-1 truncate text-sm font-medium">
        {@who} has {if @count == 1, do: "a question", else: "#{@count} questions"}
      </h3>
      <span :if={@waiting} class="flex shrink-0 items-center gap-1.5 text-xs text-primary">
        <span class="size-1.5 animate-pulse rounded-full bg-primary"></span> Waiting for you
      </span>
    </header>
    """
  end

  attr :n, :integer, required: true
  attr :question, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  # One question, numbered like a plan's tasks: its first sentence in bold, the rest
  # under it, then how to answer.
  defp question_row(assigns) do
    {title, rest} = split_question(assigns.question)
    assigns = assign(assigns, title: title, rest: rest)

    ~H"""
    <li class="flex gap-2.5 px-3.5 py-3">
      <span class="w-4 shrink-0 pt-px text-right text-xs tabular-nums text-base-content/40">
        {@n}
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-medium leading-snug">{@title}</p>
        <p :if={@rest} class="mt-0.5 text-[13px] leading-snug text-base-content/60">{@rest}</p>
        <p :if={@hint} class="mt-0.5 text-xs text-base-content/50">{@hint}</p>
        <div class="mt-2">{render_slot(@inner_block)}</div>
      </div>
    </li>
    """
  end

  attr :name, :string, required: true
  attr :options, :list, required: true, doc: "[{value, label}]"
  attr :checked, :any, default: nil
  attr :recommend, :boolean, default: true, doc: "whether the first option is the recommended one"
  attr :own, :string, default: nil, doc: "the field for an answer of your own, as the last row"

  # A question's options as one list, a row each; the first is the one the agent
  # recommends. What an option says in brackets ("please specify", a path) is shown
  # lighter, after it. An answer of your own is the list's last row.
  defp option_list(assigns) do
    ~H"""
    <div class="divide-y divide-base-content/[0.07] overflow-hidden rounded-lg border border-base-content/10">
      <label
        :for={{{value, label}, j} <- Enum.with_index(@options)}
        class="group/opt flex cursor-pointer items-center gap-2.5 px-3 py-2 text-[13px] leading-snug transition-colors hover:bg-base-content/[0.03] has-[input:checked]:bg-primary/[0.08]"
      >
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(value) == to_string(@checked)}
          class="peer sr-only"
        />
        <span class="size-3.5 shrink-0 rounded-full border border-base-content/30 transition-all peer-checked:border-[4px] peer-checked:border-primary peer-focus-visible:ring-2 peer-focus-visible:ring-primary/40"></span>
        <span class="min-w-0 flex-1">
          <span class="text-base-content/85 group-has-[input:checked]/opt:text-base-content">
            {elem(option_label(label), 0)}
          </span>
          <span :if={elem(option_label(label), 1)} class="ml-1 text-base-content/45">
            {elem(option_label(label), 1)}
          </span>
          <span
            :if={@recommend and j == 0}
            class="ml-1.5 inline-block rounded bg-primary/10 px-1.5 align-[1px] text-[10.5px] font-medium text-primary"
          >
            Recommended
          </span>
        </span>
        <.icon
          name="hero-check-mini"
          class="size-4 shrink-0 text-primary opacity-0 transition-opacity group-has-[input:checked]/opt:opacity-100"
        />
      </label>
      <label
        :if={@own}
        class="flex items-center gap-2.5 px-3 py-1.5 focus-within:bg-base-content/[0.03]"
      >
        <.icon name="hero-pencil-square-micro" class="size-3.5 shrink-0 text-base-content/35" />
        <input
          type="text"
          name={@own}
          autocomplete="off"
          placeholder="Add details, or write your own answer"
          class="h-6 min-w-0 flex-1 bg-transparent text-[13px] outline-none placeholder:text-base-content/35"
        />
      </label>
    </div>
    """
  end

  # A question's first sentence, and the rest of it: "Where does it go? The invoices
  # page is the obvious place…"
  defp split_question(question) do
    case Regex.run(~r/\A(.+?\?)\s+(\S.*)\z/s, String.trim(question || "")) do
      [_, title, rest] -> {title, rest}
      _ -> {question, nil}
    end
  end

  # An option's words, and what it says in brackets at the end, shown lighter:
  # "Supplementary documentation (please specify what)".
  defp option_label(label) do
    case Regex.run(~r/\A(.+?)\s*\(([^()]+)\)\s*\z/, to_string(label)) do
      [_, words, aside] -> {words, aside}
      _ -> {label, nil}
    end
  end

  attr :note, :string, required: true
  slot :inner_block, required: true

  defp question_foot(assigns) do
    ~H"""
    <footer class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-3.5 py-2.5">
      <span class="mr-auto text-xs text-base-content/55">{@note}</span>
      {render_slot(@inner_block)}
    </footer>
    """
  end

  # A field that holds the answer of your own to another field's options.
  defp own_answer_field?(name, props) do
    String.ends_with?(name, "_other") and
      Map.has_key?(props, String.trim_trailing(name, "_other"))
  end

  # Field names in reading order: answer_2 before answer_10.
  defp natural(name) do
    for part <- Regex.split(~r/(\d+)/, name, include_captures: true, trim: true) do
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end
  end

  attr :id, :string, required: true
  attr :tasks, :list, required: true
  attr :spec_hint, :boolean, default: false
  attr :startable, :boolean, required: true

  # The planner's tasks, and the question whether to build them.
  # What a planner reply created, in short: the tasks themselves are in the plan below
  # the conversation while it's being made (FactoryWeb.PlanPanel), so this opens on click.
  defp plan_card(assigns) do
    ~H"""
    <details id={@id} class="group mt-2 rounded-lg border border-base-content/10 text-sm">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-1.5 text-xs text-base-content/60 hover:text-base-content [&::-webkit-details-marker]:hidden">
        <.icon name="hero-clipboard-document-list-micro" class="size-3.5 text-primary" />
        Created {length(@tasks)} {if length(@tasks) == 1, do: "task", else: "tasks"}
        <span :if={@startable} class="text-base-content/45">· the plan is below</span>
        <.icon
          name="hero-chevron-down-micro"
          class="ml-auto size-3.5 transition-transform group-open:rotate-180"
        />
      </summary>
      <ol class="space-y-1 border-t border-base-content/10 px-3 py-2">
        <li :for={{title, i} <- Enum.with_index(@tasks, 1)} class="flex gap-2.5">
          <span class="w-4 shrink-0 text-right text-xs tabular-nums text-base-content/40">{i}</span>
          <span>{title}</span>
        </li>
      </ol>
    </details>
    """
  end

  # "To Coder" above a message sent to one agent, shown only in the All view.
  defp to_agent_name(_message, _agents, focus) when focus != nil, do: nil

  defp to_agent_name(%{body: "/" <> _}, _agents, _), do: nil

  defp to_agent_name(%{meta: %{"to_agent_id" => id}}, agents, _),
    do: Enum.find_value(agents, &(&1.id == id && &1.name))

  defp to_agent_name(_message, _agents, _focus), do: nil

  attr :id, :string,
    default: nil,
    doc: "set for stored replies; live ones re-render as text streams in"

  attr :name, :string, required: true
  attr :body, :string, required: true
  attr :meta, :map, default: %{}
  attr :live, :boolean, default: false

  # A reply written by an agent (via Kiro), or one still streaming in.
  def agent_reply(assigns) do
    ~H"""
    <div class="group/reply">
      <p class="mb-1.5 flex items-center gap-2 text-sm">
        <span class="grid size-5 place-items-center rounded-md bg-base-content/[0.06]">
          <.icon name="hero-cpu-chip-mini" class="size-3.5" />
        </span>
        <span class="font-semibold">{@name}</span>
      </p>
      <div :if={@id} id={@id} class="md" phx-hook="Markdown" phx-update="ignore">
        {FactoryWeb.Markdown.render(@body)}
      </div>
      <div :if={!@id and @body != ""} class="md">{FactoryWeb.Markdown.render(@body)}</div>
      <span :if={@live} class="mt-2 inline-flex gap-1" aria-label="Writing">
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.3s]"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.15s]"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40"></span>
      </span>
      <%!-- Usage is always shown; Copy appears on hover. --%>
      <div
        :if={@id}
        class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/45"
      >
        <span
          :if={@meta["credits"]}
          class="flex items-center gap-1"
          title="Kiro credits this reply used"
        >
          <.icon name="hero-bolt-mini" class="size-3.5" />
          {FactoryWeb.Usage.credits(@meta["credits"])} credits
        </span>
        <span :if={@meta["ms"]} class="flex items-center gap-1" title="Time Kiro took">
          <.icon name="hero-clock-mini" class="size-3.5" />
          {Float.round(@meta["ms"] / 1000, 1)} s
        </span>
        <span
          :if={FactoryWeb.Usage.context(@meta)}
          class="flex items-center gap-1"
          title="How full the agent's context window is after this reply. Kiro doesn't state the window size, so it is estimated."
        >
          <.icon name="hero-circle-stack-mini" class="size-3.5" />
          {FactoryWeb.Usage.context(@meta)}
        </span>
        <span
          :if={@meta["session"] == "shared"}
          class="flex items-center gap-1"
          title="Answered in the shared Kiro session, which all shared agents take part in"
        >
          <.icon name="hero-users-mini" class="size-3.5" /> shared session
        </span>
        <button
          id={"copy-#{@id}"}
          type="button"
          phx-click={JS.dispatch("factory:copy", to: "##{@id}", detail: %{button: "copy-#{@id}"})}
          class="flex items-center gap-1 rounded-md px-1.5 py-0.5 opacity-0 transition-opacity hover:bg-base-content/[0.06] hover:text-base-content focus:opacity-100 group-hover/reply:opacity-100"
        >
          <.icon name="hero-clipboard-document-mini" class="size-3.5" /> <span>Copy</span>
        </button>
      </div>
    </div>
    """
  end

  defp startable?(run), do: run && run.status == "draft" && run.tasks != []

  attr :names, :list, required: true

  defp attachments(assigns) do
    ~H"""
    <div :if={@names != []} class="mb-1.5 flex flex-wrap gap-1.5">
      <span
        :for={n <- @names}
        class="inline-flex items-center gap-1.5 rounded-xl bg-base-100 px-2.5 py-1.5 text-xs"
      >
        <.icon name="hero-document-text-mini" class="size-4 opacity-60" /> {n}
      </span>
    </div>
    """
  end

  # Message text with `code` spans. Built as a string (not a template) because messages keep their
  # line breaks, so any whitespace from template formatting would show up in the bubble.
  defp rich(text) do
    ~r/(`[^`\n]+`)/
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn
      "`" <> rest = part when byte_size(part) > 2 ->
        code = rest |> String.trim_trailing("`") |> escape()
        ~s(<code class="code-inline">#{code}</code>)

      part ->
        escape(part)
    end)
    |> Phoenix.HTML.raw()
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  attr :agent, :any, required: true

  # How full the addressed agent's Kiro context is, and a button to compact it. Shown
  # while its session runs, or right after a compaction until the next reply.
  defp context_chip(%{agent: %{usage: usage}} = assigns) when is_map(usage) do
    pct = usage["context_pct"]
    assigns = assign(assigns, pct: pct, usage: usage, level: FactoryWeb.Usage.level(pct))

    ~H"""
    <%!-- Only once it matters: the context filling up, or just compacted. --%>
    <div
      :if={@level in ["mid", "high"] or @usage["compacted_from"]}
      id="context-chip"
      class={[
        "ctx-chip flex h-7 items-center overflow-hidden rounded-full border text-xs tabular-nums",
        @level && "is-#{@level}"
      ]}
    >
      <span
        class="flex items-center gap-1.5 pl-2.5 pr-2"
        title={
          "#{@agent.name}'s context: #{FactoryWeb.Usage.context(@usage)}. " <>
            "It's compacted automatically before the next message at #{FactoryWeb.Usage.compact_at()}%."
        }
      >
        <svg :if={@pct} viewBox="0 0 16 16" class="ctx-ring size-4 -rotate-90" aria-hidden="true">
          <circle cx="8" cy="8" r="6" pathLength="100" class="ctx-track" />
          <circle
            cx="8"
            cy="8"
            r="6"
            pathLength="100"
            class="ctx-fill"
            stroke-dasharray={"#{min(@pct, 100)} 100"}
          />
        </svg>
        <.icon :if={!@pct} name="hero-arrows-pointing-in-mini" class="size-4 opacity-60" />
        <span :if={@pct}>{FactoryWeb.Usage.pct(@pct)}</span>
        <span :if={!@pct} class="text-base-content/55">Compacted</span>
      </span>
      <button
        :if={@pct}
        id="compact-chip"
        type="button"
        phx-click="compact"
        phx-value-id={@agent.id}
        class="flex h-full items-center gap-1 border-l border-current/15 px-2.5 font-medium transition-colors hover:bg-base-content/[0.07]"
        title="Summarize the conversation by fixed rules (the latest messages stay word for word) and continue in a fresh Kiro session"
      >
        <.icon name="hero-arrows-pointing-in-mini" class="size-3.5" /> Compact
      </button>
    </div>
    """
  end

  defp context_chip(assigns), do: ~H""

  attr :form, :any, required: true
  attr :uploads, :map, required: true
  attr :draft, :string, required: true
  attr :commands, :list, required: true
  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :run, :any, required: true

  attr :planner, :any,
    default: nil,
    doc: "the agent that plans the run (Factory.Chat.planner_for/1)"

  attr :job, :string, default: nil, doc: "the workflow's kind (Factory.Workflows.kind/1)"
  attr :glow, :boolean, default: false

  # Rounded card: attachments, the message, then a toolbar with attach, recipient and send.
  def composer(assigns) do
    matches =
      if String.match?(assigns.draft, ~r{^/\S*$}),
        do:
          Enum.filter(assigns.commands, fn {c, _} ->
            String.starts_with?(c, String.downcase(assigns.draft))
          end),
        else: []

    ready = String.trim(assigns.draft) != "" or assigns.uploads.spec.entries != []
    assigns = assign(assigns, matches: matches, ready: ready)

    ~H"""
    <.form
      for={@form}
      id="chat-form"
      phx-change="validate"
      phx-submit="send"
      class="pointer-events-auto relative mx-auto w-full max-w-3xl"
    >
      <ul
        :if={@matches != []}
        class="absolute inset-x-0 bottom-full mb-2 overflow-hidden rounded-xl border border-base-content/10 bg-surface p-1 text-sm shadow-xl"
      >
        <li :for={{cmd, desc} <- @matches}>
          <button
            type="button"
            phx-click="use_command"
            phx-value-cmd={cmd}
            class="flex w-full gap-3 rounded-xl px-3 py-2 text-left hover:bg-base-content/[0.06]"
          >
            <span class="w-24 shrink-0 font-mono text-xs">{cmd}</span>
            <span class="text-base-content/60">{desc}</span>
          </button>
        </li>
      </ul>

      <div class={[
        "composer-box rounded-xl border border-base-content/15 shadow-[0_1px_2px_rgb(0_0_0/0.06),0_8px_28px_-8px_rgb(0_0_0/0.28)] transition-[border-color,box-shadow] focus-within:border-base-content/30 focus-within:shadow-[0_1px_2px_rgb(0_0_0/0.06),0_10px_32px_-8px_rgb(0_0_0/0.36)]",
        @glow && "is-glow"
      ]}>
        <div :if={@uploads.spec.entries != []} class="flex flex-wrap gap-2 px-4 pt-4">
          <span
            :for={entry <- @uploads.spec.entries}
            class={[
              "inline-flex items-center gap-1.5 rounded-xl border px-2.5 py-1.5 text-xs",
              if(upload_errors(@uploads.spec, entry) != [],
                do: "border-error/40 bg-error/10 text-error",
                else: "border-base-300 bg-base-200"
              )
            ]}
          >
            <.icon name="hero-document-text-mini" class="size-4 opacity-60" />
            {entry.client_name}
            <span :for={err <- upload_errors(@uploads.spec, entry)}>: {upload_error(err)}</span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="-mr-1 rounded-full p-0.5 opacity-60 hover:bg-base-content/[0.06] hover:opacity-100"
              aria-label={"Remove #{entry.client_name}"}
            >
              <.icon name="hero-x-mark-mini" class="size-3.5" />
            </button>
          </span>
        </div>
        <p :for={err <- upload_errors(@uploads.spec)} class="px-4 pt-2 text-xs text-error">
          {upload_error(err)}
        </p>

        <textarea
          id="chat-input"
          name="chat[body]"
          phx-hook="ChatInput"
          phx-debounce="100"
          rows="1"
          placeholder={placeholder(recipient(@focus, @to), @run, @planner, @job)}
          class="block max-h-[240px] min-h-[40px] w-full resize-none bg-transparent px-4 pb-1 pt-3 text-[14px] leading-6 outline-none placeholder:text-base-content/40 focus-visible:outline-none"
          aria-label="Message"
        ></textarea>

        <div class="flex items-center gap-1.5 px-2.5 pb-2.5 pt-0.5">
          <label
            for={@uploads.spec.ref}
            class="grid size-8 cursor-pointer place-items-center rounded-full border border-base-300 text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content"
            title="Attach spec files (.md, .txt)"
          >
            <.icon name="hero-plus-mini" class="size-5" />
            <span class="sr-only">Attach spec files</span>
          </label>
          <.live_file_input upload={@uploads.spec} class="sr-only" />

          <.recipient_picker agents={@agents} focus={@focus} to={@to} run={@run} />
          <.context_chip agent={recipient(@focus, @to)} />

          <span class="ml-auto"></span>
          <span class="composer-hint pr-1 text-xs text-base-content/35">
            Enter to send · Shift+Enter for a new line
          </span>
          <button
            id="send"
            type="submit"
            disabled={!@ready}
            class={[
              "grid size-7 place-items-center rounded-full transition",
              if(@ready,
                do: "bg-base-content text-base-100 hover:opacity-85",
                else: "cursor-not-allowed bg-base-content/15 text-base-content/40"
              )
            ]}
            aria-label="Send"
          >
            <.icon name="hero-arrow-up-mini" class="size-5" />
          </button>
        </div>
      </div>
    </.form>
    """
  end

  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :run, :any, required: true

  # "To: Planner ▾" — who the message goes to: the planner unless another is picked.
  defp recipient_picker(assigns) do
    assigns =
      assign(assigns,
        current: recipient(assigns.focus, assigns.to),
        run_draft: settable?(assigns.run)
      )

    ~H"""
    <details
      id="recipient"
      class="relative"
      phx-click-away={JS.remove_attribute("open", to: "#recipient")}
    >
      <summary class={[
        "flex h-8 cursor-pointer list-none items-center gap-1.5 rounded-full px-3 text-sm transition-colors hover:bg-base-content/[0.06] hover:text-base-content",
        if(@current, do: "bg-primary/10 text-base-content", else: "text-base-content/70")
      ]}>
        <.icon
          name={if @current, do: FactoryWeb.RunParts.kind_icon(@current.kind), else: "hero-bolt-mini"}
          class={["size-4", @current && "text-primary"]}
        />
        <span class="max-w-40 truncate">{if @current, do: @current.name, else: "Factory"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute bottom-full left-0 z-30 mb-2 w-72 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <p class="px-3 pb-1 pt-1.5 text-xs text-base-content/45">Send to</p>
        <button
          :for={a <- @agents}
          type="button"
          phx-click={
            JS.push("to", value: %{id: a.id}) |> JS.remove_attribute("open", to: "#recipient")
          }
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            @current && @current.id == a.id && "bg-base-200"
          ]}
        >
          <span class={["size-2 rounded-full", Layouts.status_dot(a.status)]}></span>
          <span class="flex-1 truncate">
            {a.name}
            <span class="text-base-content/45">
              {if a.kind == "planner" and @run_draft, do: "plans the tasks", else: a.model}
            </span>
          </span>
          <.icon :if={@current && @current.id == a.id} name="hero-check-mini" class="size-4" />
        </button>
        <button
          type="button"
          phx-click={JS.push("to", value: %{id: ""}) |> JS.remove_attribute("open", to: "#recipient")}
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            @current == nil && "bg-base-200"
          ]}
        >
          <.icon name="hero-bolt-mini" class="size-4" />
          <span class="flex-1">Factory <span class="text-base-content/45">commands, specs</span></span>
          <.icon :if={@current == nil} name="hero-check-mini" class="size-4" />
        </button>
      </div>
    </details>
    """
  end

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"
  defp upload_error(:too_many_files), do: "up to 5 files at a time"
  defp upload_error(err), do: to_string(err)

  # Starting points for the message box, by the kind of job the workflow does.
  @examples %{
    "feature" => [
      "Add a dark mode toggle to the settings page",
      "Let users export the list as CSV",
      "Add search with filters to the main list"
    ],
    "bug" => [
      "Saving the form logs the user out",
      "The page crashes when the list is empty",
      "Dates show in the wrong time zone"
    ],
    "issue" => [
      "Resolve this issue: (paste the link or the text)",
      "Triage the open issue about slow page loads"
    ],
    "deps" => [
      "Update all dependencies to their latest minor versions",
      "Upgrade the framework to its newest major version",
      "Fix the security advisories in our dependencies"
    ]
  }

  defp examples(workflow), do: Map.get(@examples, Workflows.kind(workflow), [])

  # What the scout found worth reviewing: the branch that's checked out first (when it
  # isn't the base), then the open pull requests, then the other branches with work
  # beyond the base, latest first.
  defp review_picks({:ok, scout}) do
    branch = fn b ->
      %{
        kind: :branch,
        value: b.name,
        label: b.name,
        current: b.current,
        ahead: b.ahead,
        detail: b.subject,
        at: b.at
      }
    end

    worth = Enum.filter(scout.branches, &(&1.name != scout.base and (&1.ahead || 1) > 0))
    {current, others} = Enum.split_with(worth, & &1.current)

    prs =
      for p <- scout.prs || [] do
        %{kind: :pr, value: p.url, label: "##{p.number} #{p.title}", detail: p.branch, at: p.at}
      end

    changes =
      if scout.dirty > 0,
        do: [
          %{
            kind: :changes,
            value: "",
            label: "Uncommitted changes",
            detail:
              "#{scout.dirty} #{if scout.dirty == 1, do: "file", else: "files"} changed on #{scout.current || "this branch"}",
            at: nil
          }
        ],
        else: []

    # On the base, or a branch with nothing beyond it: its latest commits are the work.
    recent =
      case scout.recent do
        [latest | _] = commits when current == [] ->
          [
            %{
              kind: :recent,
              value: "#{length(commits)}",
              label: "Latest commits on #{scout.current || "this branch"}",
              detail: "#{length(commits)} commits, the latest “#{latest.subject}”",
              at: latest.at
            }
          ]

        _ ->
          []
      end

    Enum.map(current, branch) ++ changes ++ prs ++ recent ++ Enum.map(others, branch)
  end

  defp review_picks(_scout), do: []

  # Why pull requests aren't listed, when they aren't.
  defp scout_notes({:ok, %{prs_note: note}}) when is_binary(note), do: [note]

  defp scout_notes(_scout), do: []

  # The run worked on last, other than this one: one that has started or has tasks.
  def last_run(runs, current) do
    Enum.find(runs, fn r ->
      (current == nil or r.id != current.id) and (r.status != "draft" or r.tasks != [])
    end)
  end
end
