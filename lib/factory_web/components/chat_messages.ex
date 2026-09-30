defmodule FactoryWeb.ChatMessages do
  @moduledoc """
  The conversation in the chat (`FactoryWeb.ChatLive`): what was written, Factory's
  notes, and the agents' replies, stored or still streaming in, with the plan a reply
  made and the questions it asks (`FactoryWeb.ChatQuestions`). Events from them go to
  the chat LiveView.
  """
  use FactoryWeb, :html
  alias FactoryWeb.ChatQuestions

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
        <p :if={@message.body != ""} class="whitespace-pre-wrap break-words" phx-no-format>{inline_code(@message.body)}</p>
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
      <ChatQuestions.elicitation
        :if={@message.meta["elicitation"]}
        id={"elicitation-#{@message.id}"}
        message={@message}
      />
      <ChatQuestions.question_form
        :if={ChatQuestions.answerable?(@message, @run)}
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
  attr :tasks, :list, required: true
  attr :spec_hint, :boolean, default: false
  attr :startable, :boolean, required: true

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
      <span :if={@live} class="mt-2 inline-flex gap-1" role="status" aria-label="Writing">
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.3s] motion-reduce:animate-none"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.15s] motion-reduce:animate-none"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 motion-reduce:animate-none"></span>
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
          {FactoryWeb.UsageMeter.credits(@meta["credits"])} credits
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
end
