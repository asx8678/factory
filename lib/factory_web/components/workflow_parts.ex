defmodule FactoryWeb.WorkflowParts do
  @moduledoc """
  The Workflows page's pieces (`FactoryWeb.WorkflowsLive`): the workflow bar and its
  menu, the agent panel's fields and context editor, and the arrow's hand-off prompt
  window. Events from them go to the Workflows LiveView.
  """
  use FactoryWeb, :html
  import FactoryWeb.RunParts, only: [type_icon: 2]
  alias Factory.{Kiro, Workflows}
  alias Factory.Agents.{Agent, Workflow}

  def agent_path(%Agent{workflow_id: wid, id: id}), do: ~p"/workflows/#{wid}/agents/#{id}"

  attr :agent, :map, required: true
  attr :form, :any, required: true

  # Editor for an agent's prompt, laid out like a file in a code editor.
  def context_editor(assigns) do
    text = assigns.form[:prompt].value || ""

    # The agent's own role first in the Templates menu.
    kinds =
      Enum.sort_by(FactoryWeb.AgentKinds.all(), fn {kind, _, _} -> kind != assigns.agent.kind end)

    assigns =
      assign(assigns,
        kinds: kinds,
        text: text,
        chars: String.length(text),
        lines: max(length(String.split(text, "\n")), 1),
        dirty: text != (assigns.agent.prompt || ""),
        close: JS.patch(agent_path(assigns.agent))
      )

    ~H"""
    <div
      id="context-editor"
      class="absolute inset-0 z-40 flex items-center justify-center bg-black/50 p-3 sm:p-6"
      phx-window-keydown={!@dirty && @close}
      phx-key="Escape"
    >
      <.form
        for={@form}
        id="context-form"
        phx-change="context_change"
        phx-submit="save_context"
        phx-click-away={!@dirty && @close}
        class="flex h-full max-h-[760px] w-full max-w-3xl flex-col overflow-hidden rounded-xl border border-base-content/10 bg-surface shadow-2xl"
      >
        <header class="flex h-14 shrink-0 items-center gap-2 border-b border-base-content/10 pl-4 pr-3">
          <.icon name={FactoryWeb.AgentKinds.icon(@agent.kind)} class="size-4 shrink-0 opacity-60" />
          <p class="min-w-0 truncate text-xs">
            <span class="text-base-content/60">{@agent.name}</span>
            <span class="mx-1 text-base-content/30">/</span>
            <span class="font-semibold">Prompt</span>
          </p>
          <span
            :if={@dirty}
            class="flex shrink-0 items-center gap-1.5 text-xs text-base-content/50"
          >
            <span class="size-1.5 rounded-full bg-amber-300/80"></span> Unsaved
          </span>

          <div class="ml-auto flex shrink-0 items-center gap-1.5">
            <details
              id="prompt-templates"
              class="relative"
              phx-click-away={JS.remove_attribute("open", to: "#prompt-templates")}
            >
              <summary class="flex h-8 cursor-pointer list-none items-center gap-1 rounded-lg px-2.5 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content">
                Templates <.icon name="hero-chevron-down-mini" class="size-4 opacity-60" />
              </summary>
              <div class="absolute right-0 z-10 mt-1 w-72 rounded-xl border border-base-content/10 bg-surface p-1 shadow-xl">
                <p class="px-3 pb-1 pt-2 text-xs text-base-content/45">
                  Replaces the current text
                </p>
                <button
                  :for={{kind, label, icon} <- @kinds}
                  type="button"
                  phx-click={
                    JS.dispatch("factory:fill",
                      to: "#context-prompt",
                      detail: %{text: FactoryWeb.AgentKinds.template(kind, @agent.name)}
                    )
                    |> JS.remove_attribute("open", to: "#prompt-templates")
                  }
                  class="flex w-full items-start gap-2.5 rounded-lg px-3 py-2 text-left hover:bg-base-content/[0.06]"
                >
                  <.icon name={icon} class="mt-0.5 size-4 shrink-0 opacity-60" />
                  <span class="min-w-0 flex-1">
                    <span class="flex items-center gap-1.5 text-[13px]">
                      {label}
                      <span
                        :if={kind == @agent.kind}
                        class="rounded bg-base-200 px-1 text-[10px] text-base-content/55"
                      >
                        this agent
                      </span>
                    </span>
                    <span class="block text-[11px] text-base-content/50">
                      {FactoryWeb.AgentKinds.blurb(kind)}
                    </span>
                  </span>
                </button>
              </div>
            </details>
            <.link
              patch={agent_path(@agent)}
              data-confirm={@dirty && "Discard your changes to #{@agent.name}'s prompt?"}
              class="flex h-8 items-center rounded-lg px-3 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content"
            >
              Cancel
            </.link>
            <button
              type="submit"
              class="flex h-8 items-center rounded-lg bg-base-content px-3.5 text-xs font-medium text-base-100 hover:opacity-90"
            >
              Save
            </button>
          </div>
        </header>

        <div class="relative min-h-0 flex-1 overflow-y-auto bg-base-200/40">
          <div class="flex min-h-full">
            <div
              class="w-10 shrink-0 select-none border-r border-base-content/10 py-3.5 pr-2 text-right font-mono text-[10px] leading-[18px] text-base-content/25"
              aria-hidden="true"
            >
              <div :for={n <- 1..@lines}>{n}</div>
            </div>
            <textarea
              id="context-prompt"
              name={@form[:prompt].name}
              phx-hook="PromptEditor"
              phx-debounce="150"
              spellcheck="false"
              aria-label={"#{@agent.name}'s prompt"}
              class="block min-h-full w-full resize-none overflow-hidden bg-transparent px-4 py-3.5 font-mono text-[11px] leading-[18px] outline-none focus-visible:outline-none"
            >{Phoenix.HTML.Form.normalize_value("textarea", @text)}</textarea>
          </div>

          <div
            :if={String.trim(@text) == ""}
            class="pointer-events-none absolute inset-0 flex items-center justify-center p-6"
          >
            <div class="max-w-sm text-center">
              <p class="text-[13px] font-medium">Write how {@agent.name} should work</p>
              <p class="mt-1.5 text-[11px] leading-[18px] text-base-content/55">
                What it's responsible for, how it should work, and what it must never do.
                Kiro reads this before your first message in each session.
              </p>
              <button
                type="button"
                phx-click={
                  JS.dispatch("factory:fill",
                    to: "#context-prompt",
                    detail: %{text: FactoryWeb.AgentKinds.template(@agent.kind, @agent.name)}
                  )
                }
                class="pointer-events-auto mt-4 inline-flex items-center gap-1.5 rounded-lg border border-base-content/15 bg-base-100 px-3 py-1.5 text-xs hover:bg-base-content/[0.06]"
              >
                <.icon name={FactoryWeb.AgentKinds.icon(@agent.kind)} class="size-4 opacity-70" />
                Start from the {FactoryWeb.AgentKinds.label(@agent.kind)} template
              </button>
              <p class="mt-2 text-[11px] text-base-content/40">or just start typing</p>
            </div>
          </div>
        </div>

        <p
          :for={{msg, _} <- @form[:prompt].errors}
          class="border-t border-error/30 bg-error/10 px-4 py-2 text-xs text-error"
        >
          {msg}
        </p>

        <footer class="flex h-9 shrink-0 items-center gap-4 border-t border-base-content/10 px-4 text-[10px] text-base-content/45">
          <span>Markdown</span>
          <span id="context-count" class="tabular-nums">
            {@lines} {if @lines == 1, do: "line", else: "lines"}, {@chars} characters
          </span>
          <span class="hidden sm:inline">Saving restarts {@agent.name}'s Kiro</span>
          <span class="ml-auto hidden sm:inline">⌘S to save</span>
        </footer>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  # One row in the side panel: label on the left, value on the right.
  def prop(assigns) do
    ~H"""
    <div class="flex min-h-9 items-center gap-2">
      <dt class="w-24 shrink-0 text-base-content/50">{@label}</dt>
      <dd class="min-w-0 flex-1">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true

  # A select that reads as plain text until hovered.
  def plain_select(assigns) do
    ~H"""
    <select
      name={@field.name}
      class="w-full cursor-pointer appearance-none truncate rounded-md border border-transparent bg-transparent px-1.5 py-1 outline-none hover:bg-base-content/[0.06] focus:border-base-content/25 focus-visible:outline-none"
    >
      {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
    </select>
    """
  end

  def prompt_summary(prompt) do
    case String.trim(prompt || "") do
      "" ->
        "Not set"

      text ->
        case length(String.split(text, "\n")) do
          1 -> "1 line"
          n -> "#{n} lines"
        end
    end
  end

  attr :workflow, :map, required: true
  attr :workflows, :list, required: true
  attr :naming, :string, default: nil
  attr :sources, :list, default: []

  # Above the canvas: which workflow this is, a menu to pick another, and what to do with it.
  def workflow_bar(assigns) do
    {standard, custom} = Enum.split_with(assigns.workflows, &Workflow.standard?/1)

    assigns =
      assign(assigns,
        standard: standard,
        custom: custom,
        modified: Workflows.modified?(assigns.workflow),
        name_form:
          to_form(%{
            "name" => if(assigns.naming == "rename", do: assigns.workflow.name, else: "")
          })
      )

    ~H"""
    <div
      id="workflow-bar"
      class="flex min-h-11 flex-wrap items-center gap-x-3 gap-y-1.5 border-b border-base-300 bg-base-100 px-4 py-1.5 sm:px-6"
    >
      <details
        id="workflow-picker"
        class="relative"
        phx-click-away={JS.remove_attribute("open", to: "#workflow-picker")}
      >
        <summary class="flex h-7 cursor-pointer list-none items-center gap-1.5 rounded-md border border-base-300 px-2 text-sm hover:border-base-content/25 [&::-webkit-details-marker]:hidden">
          <.icon name="hero-squares-2x2-mini" class="size-4 text-base-content/50" />
          <span class="text-base-content/55">Select workflow</span>
          <.icon name="hero-chevron-down-mini" class="size-4 text-base-content/40" />
        </summary>
        <div class="absolute left-0 z-40 mt-1.5 w-80 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
          <p class="px-2.5 pb-1 pt-1.5 text-[11px] font-medium text-base-content/45">
            Standard
          </p>
          <.workflow_item :for={w <- @standard} w={w} open={w.id == @workflow.id} />
          <p class="px-2.5 pb-1 pt-3 text-[11px] font-medium text-base-content/45">
            Custom
          </p>
          <p :if={@custom == []} class="px-2.5 pb-2 text-xs text-base-content/50">
            None yet. Make one, or clone a standard one to change it freely.
          </p>
          <.workflow_item :for={w <- @custom} w={w} open={w.id == @workflow.id} />
        </div>
      </details>

      <div :if={@naming != "rename"} class="flex min-w-0 items-center gap-2">
        <.icon
          :if={@workflow.key}
          name={type_icon(@workflow.key, :micro)}
          class="size-4 shrink-0 text-primary"
        />
        <h1 id="workflow-name" class="truncate text-[14px] font-semibold">{@workflow.name}</h1>
        <span
          :if={@workflow.key}
          class="rounded bg-base-content/10 px-1.5 py-0.5 text-[11px] font-medium text-base-content/60"
        >
          Standard
        </span>
        <span
          :if={@modified}
          id="workflow-modified"
          class="rounded bg-warning/15 px-1.5 py-0.5 text-[11px] font-medium text-warning"
        >
          Modified
        </span>
        <span
          :if={@workflow.current}
          title="Plain chats talk to this workflow's agents"
          class="rounded bg-success/15 px-1.5 py-0.5 text-[11px] font-medium text-success"
        >
          Used in chat
        </span>
      </div>

      <.form
        :if={@naming in ["rename", "new"]}
        for={@name_form}
        id="workflow-name-form"
        phx-submit={if @naming == "new", do: "wf_create", else: "wf_rename"}
        phx-keydown="wf_naming"
        phx-key="Escape"
        phx-value-what=""
        class="flex items-center gap-2"
      >
        <.input
          field={@name_form[:name]}
          id="workflow-name-input"
          placeholder="Workflow name"
          maxlength="60"
          phx-mounted={JS.focus()}
          class="h-7 w-full rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none focus:border-base-content/30"
          wrapper_class="w-60"
        />
        <button id="workflow-name-save" class="btn btn-primary btn-xs">
          {if @naming == "new", do: "Create", else: "Rename"}
        </button>
        <button type="button" phx-click="wf_naming" phx-value-what="" class="btn btn-ghost btn-xs">
          Cancel
        </button>
      </.form>

      <div class="ml-auto flex flex-wrap items-center gap-1">
        <.bar_button
          :if={@naming == nil}
          id="wf-rename"
          event="wf_naming"
          value="rename"
          icon="hero-pencil-mini"
        >
          Rename
        </.bar_button>
        <.bar_button id="wf-base-specs" event="wf_base_specs" icon="hero-building-library-mini">
          Base specs{if @workflow.base_spec_ids != [], do: " · #{length(@workflow.base_spec_ids)}"}
        </.bar_button>
        <.bar_button id="wf-clone" event="wf_clone" icon="hero-document-duplicate-mini">
          Clone
        </.bar_button>
        <.bar_button
          :if={@workflow.key}
          id="wf-restore"
          event="wf_restore"
          icon="hero-arrow-uturn-left-mini"
          confirm={"Restore “#{@workflow.name}” to its default? Its agents, prompts and arrows are replaced. Clone it first to keep your changes."}
          disabled={!@modified}
        >
          Restore default
        </.bar_button>
        <.bar_button
          :if={!@workflow.key}
          id="wf-delete"
          event="wf_delete"
          icon="hero-trash-mini"
          confirm={"Delete “#{@workflow.name}” and its agents?"}
          danger
        >
          Delete
        </.bar_button>
        <span class="mx-1 h-5 w-px bg-base-300"></span>
        <button
          id="wf-new"
          type="button"
          phx-click="wf_naming"
          phx-value-what="new"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-mini" class="size-4" /> Add new workflow
        </button>
      </div>
    </div>
    """
  end

  attr :w, :map, required: true
  attr :open, :boolean, required: true

  defp workflow_item(assigns) do
    ~H"""
    <.link
      patch={~p"/workflows/#{@w.id}"}
      id={"pick-workflow-#{@w.id}"}
      class={[
        "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm hover:bg-base-content/[0.06]",
        @open && "bg-base-content/[0.06] font-medium"
      ]}
    >
      <.icon :if={@w.key} name={type_icon(@w.key, :micro)} class="size-4 shrink-0 text-primary" />
      <.icon :if={!@w.key} name="hero-squares-2x2-micro" class="size-4 shrink-0 text-base-content/45" />
      <span class="min-w-0 flex-1 truncate">{@w.name}</span>
      <span :if={@w.current} class="size-1.5 rounded-full bg-success" title="Used in chat"></span>
      <span class="text-xs tabular-nums text-base-content/45">
        {length(@w.agents)} {if length(@w.agents) == 1, do: "agent", else: "agents"}
      </span>
      <.icon :if={@open} name="hero-check-mini" class="size-4 text-base-content/60" />
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, default: nil
  attr :icon, :string, required: true
  attr :confirm, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :danger, :boolean, default: false
  slot :inner_block, required: true

  defp bar_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-what={@value}
      data-confirm={@confirm}
      disabled={@disabled}
      class={[
        "inline-flex h-7 items-center gap-1 rounded-md px-2 text-sm text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content disabled:pointer-events-none disabled:opacity-40",
        @danger && "hover:bg-error/10 hover:text-error"
      ]}
    >
      <.icon name={@icon} class="size-3.5" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :agents, :list, required: true

  def agent_links(assigns) do
    ~H"""
    <span :if={@agents == []} class="text-base-content/40">None</span>
    <.link
      :for={a <- @agents}
      patch={agent_path(a)}
      class="rounded-md bg-base-200 px-1.5 py-0.5 text-xs hover:bg-base-300"
    >
      {a.name}
    </.link>
    """
  end

  attr :link, :map, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true

  # Editing what an arrow says on its hand-off.
  def link_prompt_window(assigns) do
    assigns = assign(assigns, form: to_form(%{"prompt" => assigns.link.prompt}))

    ~H"""
    <div
      id="link-prompt-window"
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 backdrop-blur-sm sm:items-center"
      phx-window-keydown="link_prompt_close"
      phx-key="Escape"
    >
      <.form
        for={@form}
        id="link-prompt-form"
        phx-submit="link_prompt_save"
        phx-click-away="link_prompt_close"
        class="drawer-in w-full max-w-xl overflow-hidden rounded-xl border border-base-content/10 bg-surface shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-labelledby="link-prompt-title"
      >
        <header class="flex items-center gap-3 border-b border-base-content/10 px-5 py-4">
          <span class="grid size-9 place-items-center rounded-xl bg-info/15 text-info">
            <.icon name="hero-chat-bubble-bottom-center-text" class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <h2 id="link-prompt-title" class="truncate font-semibold">
              {@from.name}
              <.icon name="hero-arrow-long-right-mini" class="size-4 text-base-content/40" />
              {@to.name}
            </h2>
            <p class="text-xs text-base-content/55">
              Added to {@to.name}'s context each time {@from.name} hands work over.
            </p>
          </div>
          <button
            type="button"
            phx-click="link_prompt_close"
            aria-label="Close"
            class="grid size-8 place-items-center rounded-lg text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </header>
        <div class="px-5 py-4">
          <.input
            field={@form[:prompt]}
            type="textarea"
            id="link-prompt-text"
            rows="7"
            phx-mounted={JS.focus()}
            placeholder={"e.g. Only pass on the tasks that touch the API, and list the files you changed so #{@to.name} can start there."}
            class="textarea w-full text-sm leading-relaxed"
            wrapper_class="block"
          />
        </div>
        <footer class="flex items-center gap-2 border-t border-base-content/10 px-5 py-3">
          <button type="submit" id="link-prompt-save" class="btn btn-primary btn-sm">
            Save prompt
          </button>
          <button type="button" phx-click="link_prompt_close" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            :if={@link.prompt != ""}
            id="link-prompt-remove"
            type="button"
            phx-click="link_prompt_remove"
            class="btn btn-ghost btn-sm ml-auto text-error"
          >
            <.icon name="hero-trash-micro" class="size-4" /> Remove
          </button>
        </footer>
      </.form>
    </div>
    """
  end

  attr :selected, Factory.Agents.Agent, required: true
  attr :form, :any, required: true
  attr :neighbours, :map, required: true

  # The side panel for the selected agent: its name, role, kind, model and mode, its
  # Kiro session and usage, its context, and delete.
  def agent_panel(assigns) do
    ~H"""
    <aside
      id={"panel-#{@selected.id}"}
      class="drawer-in absolute inset-x-3 bottom-3 flex max-h-[70%] flex-col overflow-hidden rounded-xl border border-base-content/10 bg-surface shadow-xl sm:inset-x-auto sm:right-3 sm:top-3 sm:max-h-none sm:w-[340px]"
    >
      <.form
        for={@form}
        id="agent-form"
        phx-change="save"
        phx-submit="save"
        class="flex min-h-0 flex-1 flex-col"
      >
        <div class="min-h-0 flex-1 overflow-y-auto px-4 pb-4 pt-3.5">
          <div class="flex items-center gap-2">
            <.icon
              name={FactoryWeb.AgentKinds.icon(@selected.kind)}
              class="size-5 shrink-0 text-base-content/60"
            />
            <input
              type="text"
              id="agent-name"
              name={@form[:name].name}
              value={@form[:name].value}
              phx-debounce="300"
              aria-label="Name"
              class="-mx-1 min-w-0 flex-1 rounded-md border border-transparent bg-transparent px-1 py-0.5 text-base font-semibold outline-none hover:border-base-content/10 focus:border-base-content/25 focus-visible:outline-none"
            />
            <.link
              navigate={~p"/chat?#{[agent: @selected.id]}"}
              title="Chat with this agent"
              class="flex h-7 items-center gap-1 rounded-md px-2 text-xs text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
            >
              <.icon name="hero-chat-bubble-left-right-mini" class="size-4" /> Chat
            </.link>
            <.link
              patch={~p"/workflows/#{@selected.workflow_id}"}
              class="grid size-7 place-items-center rounded-md text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
              aria-label="Close"
            >
              <.icon name="hero-x-mark-mini" class="size-4" />
            </.link>
          </div>
          <p :for={{msg, _} <- @form[:name].errors} class="mt-1 text-xs text-error">{msg}</p>

          <div class="ml-7 mt-0.5 flex items-center gap-1.5 text-xs text-base-content/50">
            <span class={["size-1.5 rounded-full", Layouts.status_dot(@selected.status)]}></span>
            {Layouts.status_label(@selected.status)}
            <span :if={@selected.activity} class="truncate">· {@selected.activity}</span>
          </div>

          <textarea
            id="agent-role"
            name={@form[:role].name}
            phx-debounce="300"
            rows="2"
            placeholder="Add a description…"
            aria-label="Description"
            class="mt-3 block w-full resize-none rounded-md border border-transparent bg-transparent px-1 py-1 text-[13px] leading-5 text-base-content/80 outline-none placeholder:text-base-content/35 hover:border-base-content/10 focus:border-base-content/25 focus-visible:outline-none"
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:role].value)}</textarea>

          <dl class="mt-3 border-t border-base-content/10 pt-2 text-[13px]">
            <.prop label="Role">
              <.plain_select
                field={@form[:kind]}
                options={for {k, l, _} <- FactoryWeb.AgentKinds.all(), do: {l, k}}
              />
            </.prop>
            <.prop label="Model">
              <.plain_select field={@form[:model]} options={Kiro.models()} />
            </.prop>
            <.prop label="Mode">
              <.plain_select field={@form[:kiro_mode]} options={Kiro.modes()} />
            </.prop>
            <.prop label="Session">
              <.plain_select
                field={@form[:session]}
                options={[{"Own session", "own"}, {"Shared session", "shared"}]}
              />
            </.prop>
            <.prop label="Kiro">
              <span :if={!Kiro.running?(@selected)} class="px-1.5 text-base-content/50">
                Starts on first message
              </span>
              <span :if={Kiro.running?(@selected)} class="flex items-center gap-2 px-1.5">
                <span class="size-1.5 rounded-full bg-success"></span>
                {if @selected.session == "shared",
                  do: "Shared session running",
                  else: "Running"}
                <button
                  id="stop-kiro"
                  type="button"
                  phx-click="stop_kiro"
                  class="text-xs text-base-content/50 underline-offset-2 hover:text-base-content hover:underline"
                >
                  Stop
                </button>
              </span>
            </.prop>
            <.prop label="Usage">
              <div id="agent-usage" class="space-y-1.5 px-1.5 py-1">
                <span :if={!@selected.usage["turns"]} class="text-base-content/40">
                  No turns yet
                </span>
                <div :if={@selected.usage["turns"]} class="flex items-center gap-3 text-xs">
                  <span class="flex items-center gap-1" title="Turns with Kiro">
                    <.icon
                      name="hero-arrow-path-rounded-square-mini"
                      class="size-4 opacity-50"
                    />
                    {@selected.usage["turns"]} {if @selected.usage["turns"] == 1,
                      do: "turn",
                      else: "turns"}
                  </span>
                  <span class="flex items-center gap-1" title="Kiro credits used">
                    <.icon name="hero-bolt-mini" class="size-4 opacity-50" />
                    {FactoryWeb.Usage.credits(@selected.usage["credits"])} credits
                  </span>
                </div>
                <div
                  :if={@selected.usage["context_pct"]}
                  title="Current Kiro session. The window size is estimated from Kiro's numbers."
                >
                  <div class="relative h-1 rounded-full bg-base-content/10">
                    <div
                      class={[
                        "h-full rounded-full",
                        case FactoryWeb.Usage.level(@selected.usage["context_pct"]) do
                          "high" -> "bg-error"
                          "mid" -> "bg-warning"
                          _ -> "bg-info"
                        end
                      ]}
                      style={"width: #{min(max(@selected.usage["context_pct"], 2), 100)}%"}
                    >
                    </div>
                    <%!-- Where the session compacts before its next message. --%>
                    <span
                      id="compact-at"
                      class="absolute -top-0.5 h-2 w-px bg-base-content/40"
                      style={"left: #{FactoryWeb.Usage.compact_at()}%"}
                      title={"Compacts before the next message from #{FactoryWeb.Usage.compact_at()}%"}
                    ></span>
                  </div>
                  <p class="mt-1 flex items-center justify-between gap-2 text-[11px] text-base-content/50">
                    <span>Context {FactoryWeb.Usage.context(@selected.usage)}</span>
                    <button
                      :if={Kiro.running?(@selected)}
                      id="compact-context"
                      type="button"
                      phx-click="compact"
                      phx-value-id={@selected.id}
                      title="Summarize the conversation by fixed rules (the latest messages stay word for word) and continue in a fresh Kiro session"
                      class="flex shrink-0 items-center gap-0.5 rounded px-1 text-error/80 hover:bg-error/10 hover:text-error"
                    >
                      <.icon name="hero-document-minus-mini" class="size-3.5" /> Compact
                    </button>
                  </p>
                </div>
              </div>
            </.prop>
            <.prop label="Prompt">
              <.link
                id="edit-context"
                patch={~p"/workflows/#{@selected.workflow_id}/agents/#{@selected.id}?prompt"}
                class="flex w-full items-center justify-between rounded-md px-1.5 py-1 hover:bg-base-content/[0.06]"
              >
                <span class={String.trim(@selected.prompt) == "" && "text-base-content/40"}>
                  {prompt_summary(@selected.prompt)}
                </span>
                <span class="text-xs text-base-content/50">
                  {if String.trim(@selected.prompt) == "", do: "Add", else: "Edit"}
                </span>
              </.link>
            </.prop>
            <.prop label="Hands off to">
              <div class="flex flex-wrap gap-1 px-1.5 py-0.5">
                <.agent_links agents={@neighbours.hands_off_to} />
              </div>
            </.prop>
            <.prop label="Receives from">
              <div class="flex flex-wrap gap-1 px-1.5 py-0.5">
                <.agent_links agents={@neighbours.receives_from} />
              </div>
            </.prop>
          </dl>
        </div>

        <div class="flex items-center justify-between border-t border-base-content/10 px-4 py-2">
          <span class="text-[11px] text-base-content/40">Saved automatically</span>
          <button
            id="delete-agent"
            type="button"
            phx-click="delete_agent"
            data-confirm={"Delete #{@selected.name} and its arrows?"}
            class="rounded-md px-1.5 py-1 text-xs text-base-content/45 hover:bg-error/10 hover:text-error"
          >
            Delete agent
          </button>
        </div>
      </.form>
    </aside>
    """
  end
end
