defmodule FactoryWeb.PlanPanel do
  @moduledoc """
  The plan of a run being made in the chat (`FactoryWeb.ChatLive`): the run's name,
  then each task as its own card, with what to change and how to check it. A task can
  be edited or removed, or handed to Kiro to improve from the code or to change as
  asked; Kiro's version is shown beside the task until it's used or discarded. The
  panel ends with the choice to implement the plan.

  A task too thin to build without guessing (`Factory.Specs.TaskCheck`) is marked with
  what it's missing. Check scope has the planner compare the plan with what was asked
  and report, changing nothing; Improve plan has it rework the plan from the code.

  Events (to the chat LiveView): `plan_edit`, `plan_edit_cancel`, `plan_save`,
  `plan_remove`, `plan_refine`, `plan_ask_open`, `plan_ask`, `plan_use`,
  `plan_discard`, `plan_scope`, `plan_review`; `action` with "start" to implement.
  """
  alias Factory.Specs.TaskCheck
  use FactoryWeb, :html
  alias FactoryWeb.TaskList

  attr :run, :map, required: true
  attr :tasks, :list, required: true, doc: "the spec's task blocks (Factory.Spec.blocks/1)"
  attr :editing, :any, default: nil, doc: "index of the task being edited"
  attr :asking, :any, default: nil, doc: "title of the task Kiro is being asked about"
  attr :improve, :map, default: %{}, doc: "Kiro's work on tasks, by title"
  attr :inline, :any, default: nil, doc: "{task index, part} being edited in place"

  attr :working, :string,
    default: nil,
    doc: "what the planner is doing, while it works on the plan"

  attr :checking, :boolean, default: false, doc: "whether that work is a scope check"
  attr :check, :any, default: nil, doc: "the latest scope check's message, until the plan changes"

  attr :spec_hint, :boolean, default: false

  def panel(assigns) do
    thin = for {t, i} <- Enum.with_index(assigns.tasks, 1), TaskCheck.thin?(t), do: i
    assigns = assign(assigns, thin: thin)

    ~H"""
    <section
      id="chat-plan"
      phx-hook=".PlanEdit"
      aria-labelledby="chat-plan-title"
      aria-busy={to_string(@working != nil)}
      class="task-card-active rounded-xl border"
    >
      <header class="flex items-center gap-2 border-b border-base-content/10 px-3.5 py-2.5">
        <.icon name="hero-clipboard-document-list-mini" class="size-4 shrink-0 text-primary" />
        <h2 id="chat-plan-title" class="min-w-0 flex-1 truncate text-sm font-medium">
          {@run.title}
        </h2>
        <span class="shrink-0 text-xs tabular-nums text-base-content/50">
          {length(@tasks)} {if length(@tasks) == 1, do: "task", else: "tasks"}
        </span>
        <span
          :if={@thin != []}
          id="chat-plan-thin"
          class="flex shrink-0 items-center gap-1 text-xs text-warning"
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
          {length(@thin)} {if length(@thin) == 1, do: "needs", else: "need"} more context
        </span>
        <button
          id="chat-plan-scope"
          type="button"
          phx-click="plan_scope"
          disabled={@working != nil}
          title="Kiro reads the code and checks the plan against what you asked: what's covered, missing or beyond scope, the risks, and whether the tasks are the right size. It doesn't change the plan."
          class="flex h-6 shrink-0 items-center gap-1 rounded-md px-1.5 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content disabled:opacity-40"
        >
          <.icon name="hero-magnifying-glass-micro" class="size-3.5" /> Check scope
        </button>
        <button
          id="chat-plan-review"
          type="button"
          phx-click="plan_review"
          disabled={@working != nil}
          title="Kiro looks at the code and the whole plan again, then reworks it: concrete tasks, the right size, the tests it needs, and what a scope check found"
          class="flex h-6 shrink-0 items-center gap-1 rounded-md px-1.5 text-xs font-medium text-primary hover:bg-primary/10 disabled:opacity-40"
        >
          <.icon name="hero-sparkles-micro" class="size-3.5" /> Improve plan
        </button>
        <button
          id="chat-plan-spec"
          type="button"
          phx-click="tasks"
          title="Open the plan on the Spec page"
          class="grid size-6 shrink-0 place-items-center rounded-md text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
        >
          <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
        </button>
      </header>

      <p
        :if={@working}
        id="chat-plan-working"
        class="flex items-center gap-2 border-b border-base-content/10 bg-primary/[0.04] px-3.5 py-1.5 text-xs text-base-content/65"
      >
        <span class="loading loading-spinner loading-xs text-primary"></span>
        <span class="shrink-0 font-medium text-base-content/80">
          {if @checking, do: "Checking the scope", else: "Reworking the plan"}
        </span>
        <span class="min-w-0 truncate">{@working}</span>
      </p>

      <details
        :if={@check && !@checking}
        id={"chat-plan-check-#{@check.id}"}
        open
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group border-b border-base-content/10 bg-base-content/[0.02]"
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 px-3.5 py-2 text-xs [&::-webkit-details-marker]:hidden">
          <.icon name="hero-magnifying-glass-micro" class="size-3.5 text-base-content/55" />
          <span class="font-medium">Scope check</span>
          <span class="text-base-content/45">by {@check.author}</span>
          <.icon
            name="hero-chevron-down-micro"
            class="ml-auto size-3.5 text-base-content/45 transition-transform group-open:rotate-180"
          />
        </summary>
        <div class="max-h-80 overflow-y-auto px-3.5 pb-1">
          <div class="md">{FactoryWeb.Markdown.render(@check.body)}</div>
        </div>
        <div class="flex items-center gap-1.5 px-3.5 pb-2.5 pt-1.5">
          <button
            id="chat-plan-check-improve"
            type="button"
            phx-click="plan_review"
            disabled={@working != nil}
            class="btn btn-primary btn-xs gap-1"
          >
            <.icon name="hero-sparkles-micro" class="size-3.5" /> Improve plan with this
          </button>
          <button type="button" phx-click="plan_check_dismiss" class="btn btn-ghost btn-xs">
            Dismiss
          </button>
        </div>
      </details>

      <ol class={[
        "divide-y divide-base-content/[0.07] transition-opacity",
        @working && !@checking && "pointer-events-none opacity-70"
      ]}>
        <li
          :for={{task, i} <- Enum.with_index(@tasks)}
          id={"chat-plan-task-#{i}"}
          class="group px-3.5 py-2.5"
        >
          <.edit_form :if={@editing == i} task={task} i={i} />
          <div :if={@editing != i} class="flex gap-2.5">
            <span class="w-4 shrink-0 pt-px text-right text-xs tabular-nums text-base-content/40">
              {i + 1}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-start gap-2">
                <.inline_field
                  :if={@inline == {i, "title"}}
                  i={i}
                  part="title"
                  value={task.title}
                  class="flex-1 text-sm font-medium leading-snug"
                />
                <p
                  :if={@inline != {i, "title"}}
                  data-edit="title"
                  data-i={i}
                  title="Double-click to edit"
                  class="min-w-0 flex-1 cursor-text text-sm font-medium leading-snug"
                >
                  <TaskList.inline text={task.title} />
                </p>
                <.actions i={i} busy={@improve[task.title][:status] == :thinking} />
              </div>
              <ul class="mt-1 space-y-0.5 text-[13px] leading-snug text-base-content/65">
                <li :for={{d, j} <- Enum.with_index(task.details)} class="flex gap-1.5">
                  <span class="text-base-content/30">–</span>
                  <.inline_field
                    :if={@inline == {i, "step-#{j}"}}
                    i={i}
                    part={"step-#{j}"}
                    value={d}
                    class="flex-1 text-[13px] leading-snug"
                  />
                  <span
                    :if={@inline != {i, "step-#{j}"}}
                    data-edit={"step-#{j}"}
                    data-i={i}
                    title="Double-click to edit; clear it to remove the step"
                    class="min-w-0 cursor-text"
                  >
                    <TaskList.inline text={d} />
                  </span>
                </li>
                <li :if={@inline == {i, "new"}} class="flex gap-1.5">
                  <span class="text-base-content/30">–</span>
                  <.inline_field
                    i={i}
                    part="new"
                    value=""
                    placeholder="A step or note: what to change, where, how to check it"
                    class="flex-1 text-[13px] leading-snug"
                  />
                </li>
                <li :if={@inline != {i, "new"}}>
                  <button
                    id={"chat-plan-add-step-#{i}"}
                    type="button"
                    phx-click="plan_inline"
                    phx-value-i={i}
                    phx-value-part="new"
                    class="flex items-center gap-1 text-xs text-base-content/40 opacity-0 transition-opacity hover:text-base-content group-hover:opacity-100 focus:opacity-100"
                  >
                    <.icon name="hero-plus-micro" class="size-3" /> Add a step
                  </button>
                </li>
              </ul>
              <p :if={task.requirements != []} class="mt-1 text-xs text-base-content/45">
                Requirements {Enum.join(task.requirements, ", ")}
              </p>
              <p
                :if={(i + 1) in @thin and @improve[task.title] == nil}
                id={"chat-plan-thin-#{i}"}
                title="Improve it, or edit it, so an agent can build it without guessing"
                class="mt-1.5 flex items-center gap-1.5 text-xs text-warning"
              >
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
                Needs more context: {Enum.join(TaskCheck.issues(task), ", ")}
              </p>
              <.ask_form :if={@asking == task.title} task={task} i={i} />
              <.kiro :if={@improve[task.title]} task={task} entry={@improve[task.title]} />
            </div>
          </div>
        </li>
      </ol>

      <p
        :if={@spec_hint}
        class="flex items-center gap-2 border-t border-base-content/10 px-3.5 py-2 text-xs text-base-content/55"
      >
        <.icon name="hero-document-plus-micro" class="size-3.5" />
        Have a spec or requirements? Add them under Spec and I'll plan again. Or go on without.
      </p>

      <footer class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-3.5 py-2.5">
        <span class="mr-auto text-sm">Implement this plan?</span>
        <button
          type="button"
          phx-click={JS.focus(to: "#chat-input")}
          class="btn btn-ghost btn-sm"
        >
          Keep refining
        </button>
        <button
          id="implement-plan"
          type="button"
          phx-click="action"
          phx-value-action="start"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-play-micro" class="size-3.5" /> Yes, implement
        </button>
      </footer>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PlanEdit">
      // Double-click a task's title or a step to edit it in place; the field it opens
      // gets the focus, and Esc leaves it unchanged.
      export default {
        mounted() {
          this.el.addEventListener("dblclick", (e) => {
            const target = e.target.closest("[data-edit]")
            if (!target || this.el.getAttribute("aria-busy") === "true") return
            window.getSelection()?.removeAllRanges()
            this.pushEvent("plan_inline", { i: target.dataset.i, part: target.dataset.edit })
          })
          this.el.addEventListener("keydown", (e) => {
            if (e.key === "Escape" && e.target.matches("[data-inline]")) {
              e.preventDefault()
              this.pushEvent("plan_inline_cancel", {})
            }
          })
          this.focus()
        },
        updated() { this.focus() },
        focus() {
          const input = this.el.querySelector("[data-inline]")
          if (input && document.activeElement !== input) {
            input.focus()
            input.setSelectionRange(input.value.length, input.value.length)
          }
        },
      }
    </script>
    """
  end

  attr :i, :integer, required: true
  attr :part, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, default: nil
  attr :class, :string, default: nil

  # A line edited where it is, looking as it did: Enter or leaving it saves, Esc cancels.
  defp inline_field(assigns) do
    ~H"""
    <form
      id={"chat-plan-inline-#{@i}-#{@part}"}
      phx-submit="plan_inline_save"
      class={["min-w-0", @class]}
    >
      <input type="hidden" name="i" value={@i} />
      <input type="hidden" name="part" value={@part} />
      <input
        type="text"
        name="value"
        value={@value}
        placeholder={@placeholder}
        data-inline
        phx-blur="plan_inline_save"
        phx-value-i={@i}
        phx-value-part={@part}
        aria-label={if @part == "title", do: "Task title", else: "Step"}
        class="-mx-1 w-full rounded bg-base-100/60 px-1 outline-none ring-1 ring-primary/40 placeholder:text-base-content/35 focus:ring-primary/70"
      />
    </form>
    """
  end

  attr :i, :integer, required: true
  attr :busy, :boolean, default: false

  # A task's actions: always there, quieter until the task is pointed at.
  defp actions(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-0.5 opacity-60 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100">
      <button
        id={"chat-plan-refine-#{@i}"}
        type="button"
        phx-click="plan_refine"
        phx-value-i={@i}
        disabled={@busy}
        title="Kiro reads the code this task touches and rewrites it: the exact files, the steps, how to check it"
        class="flex h-6 items-center gap-1 rounded-md px-1.5 text-xs text-primary hover:bg-primary/10 disabled:opacity-40"
      >
        <.icon name="hero-sparkles-micro" class="size-3.5" /> Improve
      </button>
      <button
        id={"chat-plan-change-#{@i}"}
        type="button"
        phx-click="plan_ask_open"
        phx-value-i={@i}
        disabled={@busy}
        title="Tell Kiro how to change this task"
        class="flex h-6 items-center gap-1 rounded-md px-1.5 text-xs text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content disabled:opacity-40"
      >
        <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3.5" /> Change…
      </button>
      <button
        id={"chat-plan-edit-#{@i}"}
        type="button"
        phx-click="plan_edit"
        phx-value-i={@i}
        title="Edit"
        class="grid size-6 place-items-center rounded-md text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content"
      >
        <.icon name="hero-pencil-micro" class="size-3.5" />
        <span class="sr-only">Edit</span>
      </button>
      <button
        type="button"
        phx-click="plan_remove"
        phx-value-i={@i}
        data-confirm="Remove this task from the plan?"
        title="Remove"
        class="grid size-6 place-items-center rounded-md text-base-content/55 hover:bg-error/10 hover:text-error"
      >
        <.icon name="hero-trash-micro" class="size-3.5" />
        <span class="sr-only">Remove</span>
      </button>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :i, :integer, required: true

  defp edit_form(assigns) do
    ~H"""
    <form id={"chat-plan-form-#{@i}"} phx-submit="plan_save" class="space-y-2">
      <input type="hidden" name="i" value={@i} />
      <input
        type="text"
        name="task[title]"
        value={@task.title}
        required
        aria-label="Title"
        class="h-8 w-full rounded-md border border-base-300 bg-base-100 px-2.5 text-sm font-medium outline-none focus:border-base-content/30"
      />
      <textarea
        name="task[details]"
        rows={max(length(@task.details), 2) + 1}
        aria-label="Steps, one per line"
        placeholder="Steps or notes, one per line"
        class="w-full rounded-md border border-base-300 bg-base-100 px-2.5 py-1.5 text-[13px] leading-snug outline-none focus:border-base-content/30"
      >{Enum.join(@task.details, "\n")}</textarea>
      <input
        type="text"
        name="task[requirements]"
        value={Enum.join(@task.requirements, ", ")}
        aria-label="Requirements"
        placeholder="Requirements it covers, e.g. 1.1, 2.3"
        class="h-7 w-full rounded-md border border-base-300 bg-base-100 px-2.5 text-xs outline-none focus:border-base-content/30"
      />
      <div class="flex justify-end gap-1.5">
        <button type="button" phx-click="plan_edit_cancel" class="btn btn-ghost btn-xs">
          Cancel
        </button>
        <button class="btn btn-primary btn-xs">Save</button>
      </div>
    </form>
    """
  end

  attr :task, :map, required: true
  attr :i, :integer, required: true

  defp ask_form(assigns) do
    ~H"""
    <form
      id={"chat-plan-ask-#{@i}"}
      phx-submit="plan_ask"
      class="mt-2 flex items-center gap-1.5"
    >
      <input type="hidden" name="i" value={@i} />
      <input
        type="text"
        name="instruction"
        required
        autofocus
        placeholder="How should Kiro change it? e.g. use Req, add a test for the empty case"
        aria-label="How should Kiro change this task?"
        class="h-7 min-w-0 flex-1 rounded-md border border-base-300 bg-base-100 px-2.5 text-[13px] outline-none focus:border-primary/50"
      />
      <button class="btn btn-primary btn-xs">Change it</button>
      <button type="button" phx-click="plan_ask_open" phx-value-i="" class="btn btn-ghost btn-xs">
        Cancel
      </button>
    </form>
    """
  end

  attr :task, :map, required: true
  attr :entry, :map, required: true

  # Kiro working on a task, then its version to use or discard.
  defp kiro(assigns) do
    ~H"""
    <div class="mt-2 rounded-lg border border-primary/25 bg-primary/[0.04] px-2.5 py-2 text-[13px]">
      <%= case @entry.status do %>
        <% :thinking -> %>
          <p class="flex items-center gap-2 text-base-content/65">
            <span class="loading loading-spinner loading-xs text-primary"></span>
            <span class="truncate">{@entry.activity || "Kiro is looking at the code…"}</span>
          </p>
        <% :error -> %>
          <p class="text-error">{@entry.error}</p>
          <div class="mt-1.5 flex gap-1.5">
            <button
              type="button"
              phx-click="plan_discard"
              phx-value-title={@task.title}
              class="btn btn-ghost btn-xs"
            >
              Close
            </button>
          </div>
        <% :done -> %>
          <p class="text-xs font-medium text-primary">Kiro's version</p>
          <p class="mt-0.5 font-medium"><TaskList.inline text={@entry.suggestion.title} /></p>
          <ul :if={@entry.suggestion.details != []} class="mt-1 space-y-0.5 text-base-content/70">
            <li :for={d <- @entry.suggestion.details} class="flex gap-1.5">
              <span class="text-base-content/30">–</span>
              <span class="min-w-0"><TaskList.inline text={d} /></span>
            </li>
          </ul>
          <p
            :if={@entry.suggestion.why not in [nil, ""]}
            class="mt-1 text-xs text-base-content/50"
          >
            {@entry.suggestion.why}
          </p>
          <div class="mt-2 flex gap-1.5">
            <button
              type="button"
              phx-click="plan_use"
              phx-value-title={@task.title}
              class="btn btn-primary btn-xs"
            >
              Use this
            </button>
            <button
              type="button"
              phx-click="plan_discard"
              phx-value-title={@task.title}
              class="btn btn-ghost btn-xs"
            >
              Discard
            </button>
          </div>
      <% end %>
    </div>
    """
  end
end
