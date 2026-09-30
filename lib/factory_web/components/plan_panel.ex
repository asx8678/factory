defmodule FactoryWeb.PlanPanel do
  @moduledoc """
  The plan of a run being made in the chat (`FactoryWeb.ChatLive`): the run's name,
  then each task as its own card, with what to change and how to check it. A task can
  be edited or removed, or handed to Kiro to dig deeper into the code or to change as
  asked; Kiro's version is shown beside the task until it's used or discarded. The
  panel ends with the choice to implement the plan.

  Events (to the chat LiveView): `plan_edit`, `plan_edit_cancel`, `plan_save`,
  `plan_remove`, `plan_deeper`, `plan_ask_open`, `plan_ask`, `plan_use`,
  `plan_discard`; `action` with "start" to implement.
  """
  use FactoryWeb, :html
  alias FactoryWeb.TaskList

  attr :run, :map, required: true
  attr :tasks, :list, required: true, doc: "the spec's task blocks (Factory.Spec.blocks/1)"
  attr :editing, :any, default: nil, doc: "index of the task being edited"
  attr :asking, :any, default: nil, doc: "title of the task Kiro is being asked about"
  attr :improve, :map, default: %{}, doc: "Kiro's work on tasks, by title"
  attr :spec_hint, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <section
      id="chat-plan"
      aria-labelledby="chat-plan-title"
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

      <ol class="divide-y divide-base-content/[0.07]">
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
                <p class="min-w-0 flex-1 text-sm font-medium leading-snug">
                  <TaskList.inline text={task.title} />
                </p>
                <.actions i={i} busy={@improve[task.title][:status] == :thinking} />
              </div>
              <ul
                :if={task.details != []}
                class="mt-1 space-y-0.5 text-[13px] leading-snug text-base-content/65"
              >
                <li :for={d <- task.details} class="flex gap-1.5">
                  <span class="text-base-content/30">–</span>
                  <span class="min-w-0"><TaskList.inline text={d} /></span>
                </li>
              </ul>
              <p :if={task.requirements != []} class="mt-1 text-xs text-base-content/45">
                Requirements {Enum.join(task.requirements, ", ")}
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
    """
  end

  attr :i, :integer, required: true
  attr :busy, :boolean, default: false

  # A task's actions: always there, quieter until the task is pointed at.
  defp actions(assigns) do
    ~H"""
    <div class="flex shrink-0 items-center gap-0.5 opacity-60 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100">
      <button
        id={"chat-plan-deeper-#{@i}"}
        type="button"
        phx-click="plan_deeper"
        phx-value-i={@i}
        disabled={@busy}
        title="Kiro reads the code this task touches and makes it concrete: files, steps, how to check it"
        class="flex h-6 items-center gap-1 rounded-md px-1.5 text-xs text-primary hover:bg-primary/10 disabled:opacity-40"
      >
        <.icon name="hero-sparkles-micro" class="size-3.5" /> Dig deeper
      </button>
      <button
        type="button"
        phx-click="plan_ask_open"
        phx-value-i={@i}
        disabled={@busy}
        title="Ask Kiro to change this task"
        class="grid size-6 place-items-center rounded-md text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content disabled:opacity-40"
      >
        <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3.5" />
        <span class="sr-only">Ask Kiro</span>
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
        placeholder="e.g. split out the migration, use Req, add a test for the empty case"
        aria-label="What should Kiro change?"
        class="h-7 min-w-0 flex-1 rounded-md border border-base-300 bg-base-100 px-2.5 text-[13px] outline-none focus:border-primary/50"
      />
      <button class="btn btn-primary btn-xs">Ask Kiro</button>
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
