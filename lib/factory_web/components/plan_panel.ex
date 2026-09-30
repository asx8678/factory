defmodule FactoryWeb.PlanPanel do
  @moduledoc """
  The plan of a run being made in the chat (`FactoryWeb.ChatLive`): the run's name,
  then each task as its own card, with what to change and how to check it. A task can
  be edited or removed, or handed to Kiro to improve from the code or to change as
  asked; Kiro's version is shown beside the task until it's used or discarded. The
  panel ends with the choice to implement the plan.

  A task too thin to build without guessing (`Factory.Specs.TaskCheck`) is marked with
  what it's missing. Scope (check scope of work) has the planner compare the plan with what was asked
  and report, changing nothing; Refine has it rework the plan from the code.

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

  attr :builders, :list, default: [], doc: "the agents a task can be given to, by name"

  attr :job, :string,
    default: nil,
    doc: "the workflow's kind: a review's plan is started, not implemented"

  attr :before, :list,
    default: nil,
    doc:
      "the plan before the planner last reworked it (FactoryWeb.PlanDiff), to mark what changed"

  def panel(assigns) do
    thin = for {t, i} <- Enum.with_index(assigns.tasks, 1), TaskCheck.thin?(t), do: i
    {marks, removed} = FactoryWeb.PlanDiff.diff(assigns.before, assigns.tasks)
    assigns = assign(assigns, thin: thin, marks: marks, removed: removed)

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
          title="Check scope of work: Kiro reads the code and checks the plan against what you asked: what's covered, missing or beyond scope, the risks, and whether the tasks are the right size. It doesn't change the plan."
          class="flex h-6 shrink-0 items-center gap-1 rounded-md px-1.5 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content disabled:opacity-40"
        >
          <.icon name="hero-magnifying-glass-micro" class="size-3.5" /> Scope
        </button>
        <button
          id="chat-plan-review"
          type="button"
          phx-click="plan_review"
          disabled={@working != nil}
          title="Refine the plan: Kiro looks at the code and the whole plan again, then reworks it: concrete tasks, the right size, the tests it needs, and what a scope check found"
          class="flex h-6 shrink-0 items-center gap-1 rounded-md px-1.5 text-xs font-medium text-primary hover:bg-primary/10 disabled:opacity-40"
        >
          <.icon name="hero-sparkles-micro" class="size-3.5" /> Refine
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

      <ol class={[
        "divide-y divide-base-content/[0.07] transition-opacity",
        @working && !@checking && "pointer-events-none opacity-70"
      ]}>
        <li
          :for={{{task, mark}, i} <- Enum.with_index(Enum.zip(@tasks, @marks))}
          id={"chat-plan-task-#{i}"}
          class={["group px-3.5 py-2.5", mark && "bg-amber-400/[0.035]"]}
        >
          <.edit_form :if={@editing == i} task={task} i={i} builders={@builders} />
          <div :if={@editing != i} class="flex gap-2.5">
            <span class={[
              "w-4 shrink-0 pt-px text-right text-xs tabular-nums",
              if(mark, do: gold(true), else: "text-base-content/40")
            ]}>
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
                  class={[
                    "min-w-0 flex-1 cursor-text text-sm font-medium leading-snug",
                    gold(part_changed?(mark, :title))
                  ]}
                >
                  <TaskList.inline text={task.title} />
                  <span
                    :if={mark}
                    id={"chat-plan-mark-#{i}"}
                    class={[
                      "ml-1.5 inline-block rounded bg-amber-400/15 px-1 align-[1px] text-[10px] font-medium",
                      gold(true)
                    ]}
                  >
                    {if mark.new, do: "New", else: "Updated"}
                  </span>
                </p>
                <.actions i={i} busy={@improve[task.title][:status] == :thinking} />
              </div>
              <%!-- What's true when it's done. --%>
              <.inline_field
                :if={@inline == {i, "objective"}}
                i={i}
                part="objective"
                value={task[:objective] || ""}
                placeholder="What's true when it's done"
                class="mt-1 w-full text-[13px] leading-snug"
              />
              <p
                :if={@inline != {i, "objective"} and task[:objective]}
                id={"chat-plan-objective-#{i}"}
                data-edit="objective"
                data-i={i}
                title="Double-click to edit"
                class={[
                  "mt-1 cursor-text text-[13px] leading-snug",
                  gold(part_changed?(mark, :objective)) || "text-base-content/80"
                ]}
              >
                <TaskList.inline text={task.objective} />
              </p>

              <button
                :if={@inline != {i, "objective"} and !task[:objective]}
                id={"chat-plan-add-objective-#{i}"}
                type="button"
                phx-click="plan_inline"
                phx-value-i={i}
                phx-value-part="objective"
                class="mt-1 flex items-center gap-1 text-xs text-base-content/45 hover:text-base-content"
              >
                <.icon name="hero-plus-micro" class="size-3" />
                Add the objective: what's true when it's done
              </button>

              <%!-- How: the steps. --%>
              <p class="mt-2 text-[11px] font-medium text-base-content/45">Approach</p>
              <ul class="mt-0.5 space-y-0.5 text-[13px] leading-snug text-base-content/65">
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
                    class={["min-w-0 cursor-text", gold(line_changed?(mark, :steps, j))]}
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
              <%!-- How to tell it's done right: the checks a different model runs. --%>
              <p class="mt-2 text-[11px] font-medium text-base-content/45">Verify</p>
              <ul
                id={"chat-plan-checks-#{i}"}
                class="mt-0.5 space-y-0.5 text-[13px] leading-snug text-base-content/65"
              >
                <li :for={{c, j} <- Enum.with_index(TaskList.checks(task))} class="flex gap-1.5">
                  <.icon
                    name="hero-check-circle-micro"
                    class="mt-[2px] size-3.5 shrink-0 text-teal-500"
                  />
                  <.inline_field
                    :if={@inline == {i, "check-#{j}"}}
                    i={i}
                    part={"check-#{j}"}
                    value={c}
                    class="flex-1 text-[13px] leading-snug"
                  />
                  <span
                    :if={@inline != {i, "check-#{j}"}}
                    data-edit={"check-#{j}"}
                    data-i={i}
                    title="Double-click to edit; clear it to remove the check"
                    class={["min-w-0 cursor-text", gold(line_changed?(mark, :checks, j))]}
                  >
                    <TaskList.inline text={c} />
                  </span>
                </li>
                <li :if={@inline == {i, "newcheck"}} class="flex gap-1.5">
                  <.icon
                    name="hero-check-circle-micro"
                    class="mt-[2px] size-3.5 shrink-0 text-base-content/30"
                  />
                  <.inline_field
                    i={i}
                    part="newcheck"
                    value=""
                    placeholder="A check: a command and what it must show, or what to look at"
                    class="flex-1 text-[13px] leading-snug"
                  />
                </li>
                <li :if={@inline != {i, "newcheck"}}>
                  <button
                    id={"chat-plan-add-check-#{i}"}
                    type="button"
                    phx-click="plan_inline"
                    phx-value-i={i}
                    phx-value-part="newcheck"
                    class={[
                      "flex items-center gap-1 text-xs transition-opacity hover:text-base-content focus:opacity-100",
                      if(TaskList.checks(task) == [],
                        do: "text-base-content/45",
                        else: "text-base-content/40 opacity-0 group-hover:opacity-100"
                      )
                    ]}
                  >
                    <.icon name="hero-plus-micro" class="size-3" />
                    {if TaskList.checks(task) == [],
                      do: "Add a check: how to tell it's done right",
                      else: "Add a check"}
                  </button>
                </li>
              </ul>

              <p
                :if={task[:agent] || task[:model] || task.requirements != []}
                class="mt-2 flex flex-wrap items-center gap-x-3 text-xs text-base-content/45"
              >
                <span class={gold(part_changed?(mark, :agent))}>
                  <TaskList.agent_tag agent={task[:agent]} />
                </span>
                <span class={gold(part_changed?(mark, :model))}>
                  <TaskList.model_tag model={task[:model]} />
                </span>
                <span :if={task.requirements != []}>
                  Requirements {Enum.join(task.requirements, ", ")}
                </span>
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
        :if={Enum.any?(@marks) or @removed != []}
        id="chat-plan-changes"
        class="flex flex-wrap items-center gap-x-2 gap-y-1 border-t border-base-content/10 px-3.5 py-2 text-xs text-base-content/60"
      >
        <span class="size-2 shrink-0 rounded-full bg-amber-400"></span>
        <span>Gold marks what the planner changed: {changes_summary(@marks, @removed)}</span>
        <span :for={t <- @removed} class="text-base-content/40 line-through">{t}</span>
        <button
          id="chat-plan-changes-clear"
          type="button"
          phx-click="plan_changes_clear"
          class="ml-auto rounded px-1.5 py-0.5 text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content"
        >
          Clear marks
        </button>
      </p>

      <%!-- The latest scope check, below the tasks it's about. --%>
      <details
        :if={@check && !@checking}
        id={"chat-plan-check-#{@check.id}"}
        open
        phx-mounted={JS.ignore_attributes(["open"])}
        class="group border-t border-base-content/10 bg-base-content/[0.02]"
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 px-3.5 py-2 text-xs [&::-webkit-details-marker]:hidden">
          <.icon name="hero-magnifying-glass-micro" class="size-3.5 text-base-content/55" />
          <span class="font-medium">Scope check</span>
          <span class="text-base-content/45">by {@check.author}</span>
          <span
            :if={verdict(@check.body)}
            id="chat-plan-verdict"
            class={[
              "rounded px-1.5 py-px font-medium",
              verdict_class(verdict(@check.body))
            ]}
          >
            {verdict(@check.body)}
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="ml-auto size-3.5 text-base-content/45 transition-transform group-open:rotate-180"
          />
        </summary>
        <div class="max-h-80 overflow-y-auto px-3.5 pb-1">
          <div class="md">{FactoryWeb.Markdown.render(report(@check.body))}</div>
        </div>
        <div class="flex items-center gap-1.5 px-3.5 pb-2.5 pt-1.5">
          <button
            id="chat-plan-check-improve"
            type="button"
            phx-click="plan_review"
            disabled={@working != nil}
            class="btn btn-primary btn-xs gap-1"
          >
            <.icon name="hero-sparkles-micro" class="size-3.5" /> Refine with this
          </button>
          <button type="button" phx-click="plan_check_dismiss" class="btn btn-ghost btn-xs">
            Dismiss
          </button>
        </div>
      </details>

      <p
        :if={@spec_hint}
        class="flex items-center gap-2 border-t border-base-content/10 px-3.5 py-2 text-xs text-base-content/55"
      >
        <.icon name="hero-document-plus-micro" class="size-3.5 shrink-0" />
        <span class="min-w-0 flex-1">
          Have a spec or requirements? Add them, then press Refine to plan with them. The tasks stay as they are.
        </span>
        <.link
          :if={@run.spec_id}
          id="chat-plan-add-spec"
          navigate={~p"/specs/#{@run.spec_id}"}
          class="flex h-6 shrink-0 items-center gap-1 rounded-md border border-base-content/15 px-2 font-medium text-base-content/75 transition-colors hover:border-base-content/30 hover:text-base-content"
        >
          <.icon name="hero-plus-micro" class="size-3.5" /> Add a spec
        </.link>
      </p>

      <footer class="flex flex-wrap items-center gap-2 border-t border-base-content/10 px-3.5 py-2.5">
        <span class="mr-auto text-sm">
          {if @job == "review", do: "Start the review?", else: "Implement this plan?"}
        </span>
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
          <.icon name="hero-play-micro" class="size-3.5" />
          {if @job == "review", do: "Yes, review", else: "Yes, implement"}
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
  attr :builders, :list, default: []

  defp edit_form(assigns) do
    ~H"""
    <form id={"chat-plan-form-#{@i}"} phx-submit="plan_save" class="space-y-2.5">
      <input type="hidden" name="i" value={@i} />
      <TaskList.task_fields task={@task} as="task" builders={@builders} focus />
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
          <TaskList.task_parts task={@entry.suggestion} />
          <p
            :if={@entry.suggestion[:agent] || @entry.suggestion[:model]}
            class="mt-1.5 flex flex-wrap items-center gap-x-3 text-xs text-base-content/45"
          >
            <TaskList.agent_tag agent={@entry.suggestion[:agent]} />
            <TaskList.model_tag model={@entry.suggestion[:model]} />
          </p>
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

  # Gold, for what the planner changed since the plan was last read.
  defp gold(true), do: "text-amber-600 dark:text-amber-300"
  defp gold(_), do: nil

  defp part_changed?(nil, _part), do: false
  defp part_changed?(%{new: true}, _part), do: true
  defp part_changed?(mark, part), do: Map.get(mark, part, false)

  defp line_changed?(nil, _part, _j), do: false
  defp line_changed?(%{new: true}, _part, _j), do: true
  defp line_changed?(mark, part, j), do: j in Map.get(mark, part, [])

  # "1 new, 2 updated, 1 removed:"
  defp changes_summary(marks, removed) do
    new = Enum.count(marks, &match?(%{new: true}, &1))
    updated = Enum.count(marks, &match?(%{new: false}, &1))

    [
      new > 0 && "#{new} new",
      updated > 0 && "#{updated} updated",
      removed != [] && "#{length(removed)} removed:"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  @doc """
  A scope check's report from its verdict on: the notes Kiro sometimes writes while it
  works ("Checking dependencies…") come before the report and aren't part of it.
  """
  def report(body) do
    case Regex.split(~r/^(?=[ \t#>*_-]*Verdict\b)/im, body || "", parts: 2) do
      [_notes, report] -> report
      _ -> body || ""
    end
  end

  # The scope check's verdict, from its report's first section (Factory.Specs.Planner
  # asks for one of three).
  defp verdict(body) do
    case Regex.run(
           ~r/Verdict:?\**:?\s*\**(Ready to build|Ready after small fixes|Needs rework)/i,
           body || ""
         ) do
      [_, v] -> String.capitalize(v)
      _ -> nil
    end
  end

  defp verdict_class("Ready to build"), do: "bg-success/15 text-success"
  defp verdict_class("Ready after small fixes"), do: "bg-warning/15 text-warning"
  defp verdict_class(_rework), do: "bg-error/15 text-error"
end
