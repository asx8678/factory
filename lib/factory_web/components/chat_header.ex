defmodule FactoryWeb.ChatHeader do
  @moduledoc """
  The controls above the chat (`FactoryWeb.ChatLive`): the chat switcher, the folder
  and workflow pickers, the workflow strip with the run's agents, Pause and Resume,
  and the menu of less used views. Events from them go to the chat LiveView.
  """
  use FactoryWeb, :html
  import FactoryWeb.ChatParts
  alias FactoryWeb.WorkflowMap

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
          <span class={["size-1.5 shrink-0 rounded-full", Layouts.status_dot(@states[step.id])]}></span>
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
end
