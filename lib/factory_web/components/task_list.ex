defmodule FactoryWeb.TaskList do
  @moduledoc """
  A spec's tasks as a list you can work with: filter, select, expand, edit,
  reorder, delete and queue. The queue panel sits beside it. Events are handled by
  `FactoryWeb.SpecLive`.
  """
  use FactoryWeb, :html

  attr :tasks, :list, required: true, doc: "from Factory.Specs.task_list/1"
  attr :editable, :boolean, required: true, doc: "whether tasks can be reordered and deleted"
  attr :selected, :any, required: true
  attr :expanded, :any, required: true
  attr :editing, :any, default: nil, doc: "index of the task being edited"
  attr :improve, :map, default: %{}, doc: "Kiro's work on tasks, by title (see SpecLive)"
  attr :open, :boolean, default: true, doc: "whether single tasks can be edited and improved"
  attr :filter, :string, required: true
  attr :builders, :list, default: [], doc: "the agents a task can be given to, by name"

  def list(assigns) do
    shown =
      assigns.tasks
      |> Enum.with_index()
      |> Enum.filter(fn {t, _} -> matches?(t, assigns.filter) end)

    filter_form = to_form(%{"q" => assigns.filter})

    selected_titles =
      for {t, i} <- Enum.with_index(assigns.tasks), MapSet.member?(assigns.selected, i), do: t

    assigns =
      assign(assigns,
        shown: shown,
        filter_form: filter_form,
        count: MapSet.size(assigns.selected),
        any_queued: Enum.any?(selected_titles, & &1.queued),
        any_unqueued: Enum.any?(selected_titles, &is_nil(&1.queued)),
        all_selected:
          shown != [] and Enum.all?(shown, fn {_, i} -> MapSet.member?(assigns.selected, i) end)
      )

    ~H"""
    <div id="task-list">
      <div class="mb-3 flex min-h-9 flex-wrap items-center gap-x-3 gap-y-2 pl-4 pr-1">
        <input
          type="checkbox"
          phx-click={if @all_selected, do: "task_select_none", else: "task_select_all"}
          checked={@all_selected}
          aria-label={if @all_selected, do: "Select none", else: "Select all shown"}
          class="checkbox checkbox-xs"
        />

        <div :if={@count == 0} class="flex flex-1 items-center gap-3">
          <.form
            for={@filter_form}
            id="task-filter"
            phx-change="task_filter"
            phx-submit="task_filter"
            class="relative max-w-xs flex-1"
          >
            <.icon
              name="hero-magnifying-glass-mini"
              class="pointer-events-none absolute left-2 top-1/2 z-10 size-4 -translate-y-1/2 text-base-content/45"
            />
            <.input
              field={@filter_form[:q]}
              id="task-filter-q"
              placeholder="Filter tasks"
              phx-debounce="150"
              autocomplete="off"
              class="h-7 w-full rounded-md border border-base-300 bg-base-100 pl-7 pr-2 text-sm outline-none focus:border-base-content/30"
              wrapper_class="block"
            />
          </.form>
          <button
            :if={Enum.any?(@tasks, &is_nil(&1.queued))}
            id="queue-all"
            phx-click="queue_all"
            class="btn btn-xs btn-ghost ml-auto"
            title="Add every task that isn't queued, in list order"
          >
            <.icon name="hero-queue-list-micro" class="size-3.5" /> Queue all
          </button>
          <span class="text-xs tabular-nums text-base-content/60">
            {if @filter == "",
              do: "#{length(@tasks)} #{if length(@tasks) == 1, do: "task", else: "tasks"}",
              else: "#{length(@shown)} of #{length(@tasks)}"}
          </span>
        </div>

        <div :if={@count > 0} class="flex flex-1 flex-wrap items-center gap-1.5 text-sm">
          <span class="mr-1 font-medium tabular-nums">{@count} selected</span>
          <button :if={@any_unqueued} phx-click="queue_selected" class="btn btn-xs btn-primary">
            <.icon name="hero-queue-list-micro" class="size-3.5" /> Add to queue
          </button>
          <button :if={@any_queued} phx-click="unqueue_selected" class="btn btn-xs btn-ghost">
            Remove from queue
          </button>
          <button
            :if={@editable}
            phx-click="tasks_delete"
            data-confirm={"Delete #{@count} #{if @count == 1, do: "task", else: "tasks"}?"}
            class="btn btn-xs btn-ghost text-error"
          >
            Delete
          </button>
          <button phx-click="task_select_none" class="btn btn-xs btn-ghost ml-auto">Clear</button>
        </div>
      </div>

      <p
        :if={@shown == []}
        class="rounded-xl border border-dashed border-base-300 px-4 py-8 text-center text-sm text-base-content/60"
      >
        No task matches “{@filter}”.
      </p>

      <ol class="space-y-2">
        <li
          :for={{task, i} <- @shown}
          id={"task-#{i}"}
          class={[
            "group flex items-start gap-3.5 rounded-xl border py-3.5 pl-4 pr-3 transition-colors",
            cond do
              @open and @editing == i -> "border-base-content/20 bg-base-200/70"
              MapSet.member?(@selected, i) -> "task-card-active task-card-selected"
              MapSet.member?(@expanded, i) -> "task-card-active"
              true -> "border-base-300/70 bg-base-200/40 hover:border-base-content/15"
            end
          ]}
        >
          <%!-- What kind of task it is; hovering (or selecting) turns it into its checkbox. --%>
          <span class="relative mt-px grid size-6 shrink-0 place-items-center">
            <span
              title={elem(kind(task), 0)}
              class={[
                "grid size-6 place-items-center rounded-md transition-opacity",
                elem(kind(task), 2),
                task.done && "opacity-50",
                if(@count > 0,
                  do: "opacity-0",
                  else: "group-hover:opacity-0 [@media(hover:none)]:opacity-0"
                )
              ]}
            >
              <.icon name={elem(kind(task), 1)} class="size-3.5" />
            </span>
            <input
              type="checkbox"
              phx-click="task_select"
              phx-value-i={i}
              checked={MapSet.member?(@selected, i)}
              aria-label={"Select task #{i + 1}"}
              class={[
                "checkbox checkbox-sm absolute transition-opacity focus:opacity-100",
                if(@count > 0,
                  do: "opacity-100",
                  else: "opacity-0 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
                )
              ]}
            />
          </span>

          <.edit_form
            :if={@open and @editing == i}
            task={draft(task, @improve[task.title])}
            i={i}
            from_kiro={match?(%{status: :done}, @improve[task.title])}
            builders={@builders}
          />

          <div :if={!(@open and @editing == i)} class="min-w-0 flex-1">
            <button
              type="button"
              phx-click="task_toggle"
              phx-value-i={i}
              aria-expanded={to_string(MapSet.member?(@expanded, i))}
              class="block w-full text-left"
            >
              <span class={[
                "block text-[14px] font-medium leading-6 text-pretty",
                task.done && "text-base-content/50 line-through"
              ]}>
                <.inline text={task.title} />
              </span>
              <%!-- A task written before tasks had an objective shows its first step. --%>
              <span
                :if={!task[:objective] and task.details != [] and !MapSet.member?(@expanded, i)}
                class="mt-1 block max-w-[72ch] line-clamp-2 text-[13px] leading-[1.6] text-base-content/60"
              >
                <.inline text={hd(task.details)} />
              </span>
              <.task_parts task={task} open={MapSet.member?(@expanded, i)} />
            </button>

            <div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/50">
              <span id={"task-kind-#{i}"} class="flex items-center gap-1.5">
                <span class={["font-medium", kind_text(kind(task))]}>{elem(kind(task), 0)}</span>
                <span class="tabular-nums text-base-content/45">#{i + 1}</span>
              </span>
              <button
                :if={task.details != [] or checks(task) != []}
                type="button"
                phx-click="task_toggle"
                phx-value-i={i}
                class="flex items-center gap-0.5 hover:text-base-content"
              >
                <.icon
                  name="hero-chevron-right-micro"
                  class={[
                    "size-3.5 transition-transform",
                    MapSet.member?(@expanded, i) && "rotate-90"
                  ]}
                />
                {if MapSet.member?(@expanded, i), do: "Less", else: parts_count(task)}
              </button>
              <.agent_tag agent={task[:agent]} />
              <.model_tag model={task[:model]} />
              <span :if={task.requirements != []} class="flex flex-wrap items-center gap-1">
                <span>Req</span>
                <span
                  :for={r <- task.requirements}
                  class="font-mono text-[10.5px] tracking-tight text-base-content/60 [font-stretch:80%]"
                >
                  {r}
                </span>
              </span>
            </div>

            <.improve_panel :if={@improve[task.title]} task={task} entry={@improve[task.title]} />
          </div>

          <div :if={!(@open and @editing == i)} class="flex shrink-0 items-center gap-1.5">
            <div
              :if={@open}
              class="flex opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100 [@media(hover:none)]:opacity-100"
            >
              <.icon_button
                :if={!@improve[task.title]}
                event="improve_open"
                values={%{"phx-value-i" => i}}
                icon="hero-sparkles-mini"
                label="Improve with Kiro"
                class="hover:text-info"
              />
              <span :if={@improve[task.title]} class="size-6"></span>
              <.icon_button
                event="task_edit"
                values={%{"phx-value-i" => i}}
                icon="hero-pencil-square-mini"
                label="Edit"
              />
              <%= if @editable do %>
                <.icon_button
                  :if={i > 0}
                  event="task_move"
                  values={%{"phx-value-i" => i, "phx-value-by" => -1}}
                  icon="hero-arrow-up-mini"
                  label="Move up"
                />
                <span :if={i == 0} class="size-6"></span>
                <.icon_button
                  :if={i < length(@tasks) - 1}
                  event="task_move"
                  values={%{"phx-value-i" => i, "phx-value-by" => 1}}
                  icon="hero-arrow-down-mini"
                  label="Move down"
                />
                <span :if={i == length(@tasks) - 1} class="size-6"></span>
                <.icon_button
                  event="task_delete"
                  values={%{"phx-value-i" => i, "data-confirm" => "Delete “#{task.title}”?"}}
                  icon="hero-trash-mini"
                  label="Delete"
                  class="hover:text-error"
                />
              <% end %>
            </div>
            <button
              :if={task.queued}
              phx-click="queue_remove"
              phx-value-title={task.title}
              title="In the queue. Click to take it out."
              class="flex h-6 items-center gap-1 rounded-full bg-primary/15 px-2 text-xs font-medium text-primary hover:bg-primary/25"
            >
              Queued <span class="tabular-nums">{task.queued + 1}</span>
            </button>
            <button
              :if={!task.queued}
              phx-click="queue_add"
              phx-value-title={task.title}
              title="Add to the queue"
              class="flex h-6 items-center gap-1 rounded-full border border-base-300 px-2 text-xs text-base-content/70 opacity-0 transition-opacity hover:border-base-content/30 hover:text-base-content group-hover:opacity-100 focus:opacity-100 [@media(hover:none)]:opacity-100"
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Queue
            </button>
            <span :if={task.run_status} class="w-[4.75rem] text-right">
              <Layouts.status_badge status={task.run_status} />
            </span>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  attr :queue, :list, required: true, doc: "the queued tasks, in order"
  attr :ready, :boolean, required: true

  @doc "The queue beside the list: order it, then start a run with it."
  def queue(assigns) do
    ~H"""
    <section id="queue" class="border-b border-base-300 pb-8">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-medium">
          Queue
          <span :if={@queue != []} class="tabular-nums text-base-content/55">{length(@queue)}</span>
        </h2>
        <button
          :if={@queue != []}
          phx-click="queue_clear"
          class="text-[13px] text-base-content/55 hover:text-base-content"
        >
          Clear
        </button>
      </div>

      <p :if={@queue == []} class="mt-1 text-base-content/65">
        Queue tasks to choose which ones the next run does, and in what order.
        With no queue, a run does every task.
      </p>
      <button :if={@queue == []} phx-click="queue_all" class="btn btn-sm mt-3">
        <.icon name="hero-queue-list-mini" class="size-4" /> Queue all tasks
      </button>

      <ol :if={@queue != []} class="mt-3 space-y-1">
        <li
          :for={{task, i} <- Enum.with_index(@queue)}
          class="group flex items-start gap-2 rounded-md px-1.5 py-1 hover:bg-base-200"
        >
          <span class="w-4 shrink-0 pt-px text-right text-xs tabular-nums text-base-content/50">
            {i + 1}
          </span>
          <span class="min-w-0 flex-1 leading-5 line-clamp-2"><.inline text={task.title} /></span>
          <span class="flex shrink-0 opacity-0 group-hover:opacity-100 focus-within:opacity-100 [@media(hover:none)]:opacity-100">
            <.icon_button
              :if={i > 0}
              event="queue_move"
              values={%{"phx-value-title" => task.title, "phx-value-by" => -1}}
              icon="hero-arrow-up-mini"
              label="Earlier"
            />
            <.icon_button
              :if={i < length(@queue) - 1}
              event="queue_move"
              values={%{"phx-value-title" => task.title, "phx-value-by" => 1}}
              icon="hero-arrow-down-mini"
              label="Later"
            />
            <.icon_button
              event="queue_remove"
              values={%{"phx-value-title" => task.title}}
              icon="hero-x-mark-mini"
              label="Remove from queue"
            />
          </span>
        </li>
      </ol>

      <button
        :if={@queue != [] and @ready}
        id="start-queue"
        phx-click="start"
        class="btn btn-primary btn-sm mt-4 w-full"
      >
        <.icon name="hero-play-mini" class="size-4" />
        Start run with {length(@queue)} {if length(@queue) == 1, do: "task", else: "tasks"}
      </button>
      <p :if={@queue != [] and !@ready} class="mt-3 text-xs text-base-content/60">
        Approve the tasks to start a run with the queue.
      </p>
    </section>
    """
  end

  attr :task, :map, required: true
  attr :i, :integer, required: true
  attr :from_kiro, :boolean, default: false
  attr :builders, :list, default: []

  # Edits one task in place. Esc cancels.
  defp edit_form(assigns) do
    assigns = assign(assigns, form: to_form(Factory.Specs.task_params(assigns.task)))

    ~H"""
    <.form
      for={@form}
      id={"task-edit-#{@i}"}
      phx-submit="task_save"
      phx-keydown="task_edit_cancel"
      phx-key="Escape"
      class="min-w-0 flex-1 space-y-3"
    >
      <input type="hidden" name="i" value={@i} />
      <p :if={@from_kiro} class="flex items-center gap-1.5 text-xs text-info">
        <.icon name="hero-sparkles-micro" class="size-3.5" /> Filled in with Kiro's suggestion
      </p>
      <.task_fields id={"task-edit-#{@i}"} form={@form} task={@task} builders={@builders} focus />
      <div class="flex items-center gap-2">
        <button type="submit" id={"task-edit-#{@i}-save"} class="btn btn-primary btn-xs">
          Save
        </button>
        <button type="button" phx-click="task_edit_cancel" class="btn btn-ghost btn-xs">
          Cancel
        </button>
      </div>
    </.form>
    """
  end

  # What the edit form starts from: Kiro's suggestion when there is one.
  defp draft(task, %{status: :done, suggestion: s}),
    do:
      Map.merge(task, %{
        title: s.title,
        objective: s.objective,
        details: s.details,
        verify: s.verify,
        agent: s.agent,
        model: s.model,
        requirements: s.requirements
      })

  defp draft(task, _), do: task

  attr :task, :map, required: true
  attr :entry, :map, required: true

  # Asking Kiro to improve a task: what to do better, Kiro at work, then its suggestion.
  defp improve_panel(assigns) do
    assigns =
      assign(assigns,
        key: :erlang.phash2(assigns.task.title),
        form: to_form(%{"instruction" => assigns.entry[:instruction] || ""})
      )

    ~H"""
    <div
      id={"improve-#{@key}"}
      class="mt-3 max-w-[80ch] rounded-lg border border-info/20 bg-info/[0.04] p-3"
    >
      <.form
        :if={@entry.status == :asking}
        for={@form}
        id={"improve-form-#{@key}"}
        phx-submit="improve_send"
        phx-keydown="improve_close"
        phx-key="Escape"
        phx-value-title={@task.title}
        class="space-y-2"
      >
        <input type="hidden" name="title" value={@task.title} />
        <p class="flex items-center gap-1.5 text-xs font-medium text-info">
          <.icon name="hero-sparkles-micro" class="size-3.5" /> What should Kiro do better?
        </p>
        <.input
          field={@form[:instruction]}
          type="textarea"
          id={"improve-instruction-#{@key}"}
          rows="2"
          phx-mounted={JS.focus()}
          placeholder="e.g. Split the setup from the tests, name the exact files, add acceptance criteria… Leave empty to let Kiro decide."
          class="block w-full resize-y rounded-md border border-base-300 bg-base-100 px-2.5 py-2 text-[13px] leading-relaxed outline-none placeholder:text-base-content/40 focus:border-info/60"
          wrapper_class="block"
        />
        <div class="flex items-center gap-2">
          <button type="submit" class="btn btn-info btn-xs">
            <.icon name="hero-sparkles-micro" class="size-3.5" /> Ask Kiro
          </button>
          <button
            type="button"
            phx-click="improve_close"
            phx-value-title={@task.title}
            class="btn btn-ghost btn-xs"
          >
            Cancel
          </button>
          <span class="ml-auto text-[11px] text-base-content/45">
            Kiro reads the project; nothing changes until you apply.
          </span>
        </div>
      </.form>

      <div :if={@entry.status == :thinking} class="flex items-center gap-2 text-[13px]">
        <span class="loading loading-spinner loading-xs text-info"></span>
        <span class="min-w-0 flex-1 truncate text-base-content/70">
          {@entry.activity || "Kiro is looking at the task and the project…"}
        </span>
        <button
          type="button"
          phx-click="improve_close"
          phx-value-title={@task.title}
          class="text-xs text-base-content/55 hover:text-base-content"
        >
          Dismiss
        </button>
      </div>

      <div :if={@entry.status == :error} class="flex flex-wrap items-center gap-2 text-[13px]">
        <.icon name="hero-exclamation-triangle-mini" class="size-4 text-error" />
        <span class="min-w-0 flex-1 text-error">{@entry.error}</span>
        <button
          type="button"
          phx-click="improve_retry"
          phx-value-title={@task.title}
          class="btn btn-ghost btn-xs"
        >
          Try again
        </button>
        <button
          type="button"
          phx-click="improve_close"
          phx-value-title={@task.title}
          class="btn btn-ghost btn-xs"
        >
          Dismiss
        </button>
      </div>

      <div :if={@entry.status == :done} class="space-y-2">
        <.suggestion suggestion={@entry.suggestion} label="Kiro suggests" />
        <div class="flex flex-wrap items-center gap-2 pt-1">
          <button
            type="button"
            phx-click="improve_apply"
            phx-value-title={@task.title}
            class="btn btn-info btn-xs"
          >
            Apply
          </button>
          <button
            type="button"
            phx-click="improve_edit"
            phx-value-title={@task.title}
            class="btn btn-ghost btn-xs"
          >
            Edit first
          </button>
          <button
            type="button"
            phx-click="improve_retry"
            phx-value-title={@task.title}
            class="btn btn-ghost btn-xs"
          >
            Ask again
          </button>
          <button
            type="button"
            phx-click="improve_close"
            phx-value-title={@task.title}
            class="btn btn-ghost btn-xs ml-auto"
          >
            Discard
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :draft, :any, required: true, doc: "the new task being written (see SpecLive), or nil"
  attr :builders, :list, default: [], doc: "the agents a task can be given to, by name"

  @doc """
  Adding a task at the end of the list: a rough title and notes, added as is or
  written out by Kiro after a quick look at the project, then reviewed.
  """
  def new_task(assigns) do
    assigns =
      assign(assigns,
        draft_form:
          assigns.draft &&
            to_form(%{"title" => assigns.draft.title, "notes" => assigns.draft.notes}),
        draft_edit_form:
          if(match?(%{status: :editing, suggestion: %{}}, assigns.draft),
            do: to_form(Factory.Specs.task_params(assigns.draft.suggestion))
          )
      )

    ~H"""
    <button
      :if={is_nil(@draft)}
      id="add-task"
      type="button"
      phx-click="draft_open"
      class="mt-2 flex w-full items-center justify-center gap-1.5 rounded-xl border border-dashed border-base-300 py-3 text-sm text-base-content/55 transition-colors hover:border-base-content/25 hover:text-base-content"
    >
      <.icon name="hero-plus-mini" class="size-4" /> Add task
    </button>

    <section
      :if={@draft}
      id="new-task"
      class="task-card-active mt-2 rounded-xl border px-4 py-4"
    >
      <div class="mb-3 flex items-center justify-between gap-3">
        <h3 class="text-sm font-medium">New task</h3>
        <button
          type="button"
          phx-click="draft_close"
          aria-label="Cancel"
          class="grid size-6 place-items-center rounded text-base-content/50 hover:bg-base-300 hover:text-base-content"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <.form
        :if={@draft.status == :writing}
        for={@draft_form}
        id="task-draft"
        phx-change="draft_change"
        phx-submit="draft_submit"
        phx-keydown="draft_close"
        phx-key="Escape"
        class="space-y-3"
      >
        <.input
          field={@draft_form[:title]}
          id="task-draft-title"
          autocomplete="off"
          placeholder="What should be done? e.g. Export invoices as CSV"
          phx-mounted={JS.focus()}
          class="h-8 w-full rounded-md border border-base-300 bg-base-100 outline-none placeholder:text-base-content/40 focus:border-base-content/30 px-3 text-[14px] font-medium"
          wrapper_class="block"
        />
        <.input
          field={@draft_form[:notes]}
          type="textarea"
          id="task-draft-notes"
          rows="3"
          placeholder="Notes (optional): what it should do, files you know it touches, what to watch out for…"
          class="block w-full resize-y rounded-md border border-base-300 bg-base-100 outline-none placeholder:text-base-content/40 focus:border-base-content/30 px-3 py-2 text-[13px] leading-relaxed"
          wrapper_class="block"
        />
        <div class="flex flex-wrap items-center gap-2">
          <button
            id="draft-improve"
            type="submit"
            name="action"
            value="refine"
            disabled={!draft_text?(@draft)}
            title="AI reads what you wrote and the code, then suggests the full task"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-sparkles-mini" class="size-4" /> Suggest with AI
          </button>
          <button
            id="draft-add"
            type="submit"
            name="action"
            value="add"
            disabled={String.trim(@draft.title) == ""}
            class="btn btn-ghost btn-sm"
          >
            Add as is
          </button>
          <span id="draft-hint" class="text-xs text-base-content/50 sm:ml-auto">
            {if draft_text?(@draft),
              do: "AI reads your idea and the code, then suggests the full task for you to review.",
              else: "Write your idea in your own words, then let AI suggest the full task."}
          </span>
        </div>
      </.form>

      <div :if={@draft.status == :thinking} class="space-y-2">
        <p class="text-sm font-medium text-base-content/80">{@draft.title}</p>
        <div class="flex items-center gap-2 text-[13px]">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          <span class="min-w-0 flex-1 truncate text-base-content/65">
            {@draft.activity || "Kiro is scoping the task in the project and the spec…"}
          </span>
        </div>
      </div>

      <div :if={@draft.status == :error} class="flex flex-wrap items-center gap-2 text-[13px]">
        <.icon name="hero-exclamation-triangle-mini" class="size-4 text-error" />
        <span class="min-w-0 flex-1 text-error">{@draft.error}</span>
        <button type="button" phx-click="draft_retry" class="btn btn-ghost btn-xs">
          Try again
        </button>
      </div>

      <div :if={@draft.status == :done} class="space-y-3">
        <.suggestion suggestion={@draft.suggestion} label="Kiro wrote" />
        <div class="flex flex-wrap items-center gap-2">
          <button
            id="draft-accept"
            type="button"
            phx-click="draft_accept"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-mini" class="size-4" /> Add task
          </button>
          <button type="button" phx-click="draft_edit" class="btn btn-ghost btn-sm">
            Edit first
          </button>
          <button type="button" phx-click="draft_retry" class="btn btn-ghost btn-sm">
            Ask again
          </button>
        </div>
      </div>

      <.form
        :if={@draft.status == :editing}
        for={@draft_edit_form}
        id="task-draft-edit"
        phx-submit="draft_save"
        class="space-y-3"
      >
        <.task_fields
          id="task-draft-edit"
          form={@draft_edit_form}
          task={@draft.suggestion}
          builders={@builders}
          focus
        />
        <div class="flex items-center gap-2">
          <button type="submit" id="task-draft-edit-save" class="btn btn-primary btn-sm">
            <.icon name="hero-plus-mini" class="size-4" /> Add task
          </button>
          <button type="button" phx-click="draft_back" class="btn btn-ghost btn-sm">Back</button>
        </div>
      </.form>
    </section>
    """
  end

  attr :suggestion, :map, required: true
  attr :label, :string, required: true

  # A task as Kiro wrote it, before it's applied or added.
  defp suggestion(assigns) do
    ~H"""
    <div class="space-y-2">
      <p class="flex items-center gap-1.5 text-xs font-medium text-info">
        <.icon name="hero-sparkles-micro" class="size-3.5" /> {@label}
      </p>
      <p class="text-[14px] font-medium leading-6"><.inline text={@suggestion.title} /></p>
      <.task_parts task={@suggestion} />
      <p class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/50">
        <.agent_tag agent={@suggestion[:agent]} />
        <.model_tag model={@suggestion[:model]} />
        <span :if={@suggestion.requirements != []} class="flex flex-wrap items-center gap-1">
          Req
          <span
            :for={r <- @suggestion.requirements}
            class="font-mono text-[10.5px] tracking-tight text-base-content/60 [font-stretch:80%]"
          >
            {r}
          </span>
        </span>
      </p>
      <p :if={@suggestion.why != ""} class="text-xs italic text-base-content/55">
        {@suggestion.why}
      </p>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :open, :boolean, default: true, doc: "whether the approach and checks show"

  @doc """
  A task's objective, then (when open) its approach as numbered steps and the checks
  that prove it's done. The Spec page, the chat's plan and Kiro's suggestions show
  tasks this way.
  """
  def task_parts(assigns) do
    ~H"""
    <span
      :if={@task[:objective]}
      class="mt-1 block max-w-[72ch] text-[13px] leading-[1.6] text-base-content/75"
    >
      <.inline text={@task.objective} />
    </span>
    <span
      :if={@open and (@task.details != [] or checks(@task) != [])}
      class="mt-2.5 block max-w-[72ch] space-y-2.5 text-[13px] leading-[1.6]"
    >
      <span :if={@task.details != []} class="block">
        <span class="mb-1 block text-[11px] font-medium text-base-content/50">Approach</span>
        <span
          :for={{d, n} <- Enum.with_index(@task.details, 1)}
          class="flex gap-2 py-0.5 text-base-content/75"
        >
          <span class="w-4 shrink-0 text-right tabular-nums text-base-content/35">{n}</span>
          <span class="min-w-0"><.inline text={d} /></span>
        </span>
      </span>
      <span :if={checks(@task) != []} class="block">
        <span class="mb-1 block text-[11px] font-medium text-base-content/50">Verify</span>
        <span :for={c <- checks(@task)} class="flex gap-2 py-0.5 text-base-content/75">
          <.icon name="hero-check-circle-micro" class="mt-[3px] size-3.5 shrink-0 text-teal-500" />
          <span class="min-w-0"><.inline text={c} /></span>
        </span>
      </span>
    </span>
    """
  end

  attr :agent, :string, default: nil

  @doc "The agent a task is given to, as a small tag; nothing when it names none."
  def agent_tag(assigns) do
    ~H"""
    <span :if={@agent} title="The agent that builds it" class="flex items-center gap-1">
      <.icon name="hero-user-micro" class="size-3" />{@agent}
    </span>
    """
  end

  attr :model, :string, default: nil

  @doc """
  The model a task is to be built with, as a small tag; nothing when it names none, or
  names one Factory doesn't use for tasks (Sonnet: it's built on Auto).
  """
  def model_tag(assigns) do
    ~H"""
    <span
      :if={@model && !Factory.Kiro.avoided?(@model)}
      title="The model to build it with"
      class="flex items-center gap-1"
    >
      <.icon name="hero-cpu-chip-micro" class="size-3" />{Factory.Kiro.model_name(@model)}
    </span>
    """
  end

  @doc "A task's checks (its `Verify:` lines); none for a task written before it had them."
  def checks(task), do: Map.get(task, :verify) || []

  # What opening a task shows, for its toggle: "3 steps · 2 checks".
  defp parts_count(task) do
    [
      task.details != [] && "#{length(task.details)} #{plural(task.details, "step")}",
      checks(task) != [] && "#{length(checks(task))} #{plural(checks(task), "check")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp plural([_], word), do: word
  defp plural(_list, word), do: word <> "s"

  attr :id, :string, required: true, doc: "the form's id, which the fields' ids start with"
  attr :form, :any,
    required: true,
    doc: "the task as a form: to_form(Factory.Specs.task_params(task))"

  attr :task, :map, required: true
  attr :focus, :boolean, default: false
  attr :builders, :list, default: [], doc: "the names of the agents a task can be given to"

  @doc """
  A task's fields, for editing it or a new one Kiro wrote: the form sends title,
  objective, details and verify (a line each), model and requirements, under the
  form's names (plain, or `task[title]` for a form made with `as: :task`).
  """
  def task_fields(assigns) do
    field_class =
      "h-8 w-full rounded-md border border-base-300 bg-base-100 px-2.5 outline-none placeholder:text-base-content/35 focus:border-base-content/30"

    area_class =
      "block w-full resize-y rounded-md border border-base-300 bg-base-100 px-2.5 py-2 text-[13px] leading-relaxed outline-none placeholder:text-base-content/35 focus:border-base-content/30"

    select_class =
      "h-8 w-full rounded-md border border-base-300 bg-base-100 px-2 text-[13px] outline-none focus:border-base-content/30"

    agents = Enum.uniq(assigns.builders ++ List.wrap(assigns.task[:agent]))
    models = Factory.Kiro.task_models() -- ["auto"]

    assigns =
      assign(assigns,
        field_class: field_class,
        area_class: area_class,
        select_class: select_class,
        agent_options: [{"First that builds", ""} | agents],
        model_options: [{"Auto", ""} | for(m <- models, do: {Factory.Kiro.model_name(m), m})]
      )

    ~H"""
    <div class="block">
      <span class="mb-1 block text-xs font-medium text-base-content/60">Title</span>
      <.input
        field={@form[:title]}
        id={"#{@id}-title"}
        required
        autocomplete="off"
        phx-mounted={@focus && JS.focus()}
        class={[@field_class, "text-sm font-medium"]}
        wrapper_class="block"
      />
    </div>
    <div class="block">
      <span class="mb-1 flex items-baseline justify-between text-xs font-medium text-base-content/60">
        Objective <span class="font-normal text-base-content/45">What's true when it's done</span>
      </span>
      <.input
        field={@form[:objective]}
        id={"#{@id}-objective"}
        autocomplete="off"
        placeholder="e.g. A person can download this month's invoices as a CSV file."
        class={[@field_class, "text-[13px]"]}
        wrapper_class="block"
      />
    </div>
    <div class="block">
      <span class="mb-1 flex items-baseline justify-between text-xs font-medium text-base-content/60">
        Approach
        <span class="font-normal text-base-content/45">One step per line · `code` in backticks</span>
      </span>
      <.input
        field={@form[:details]}
        type="textarea"
        id={"#{@id}-details"}
        rows={max(3, length(@task.details) + 1)}
        class={@area_class}
        wrapper_class="block"
      />
    </div>
    <div class="block">
      <span class="mb-1 flex items-baseline justify-between text-xs font-medium text-base-content/60">
        Verify <span class="font-normal text-base-content/45">One check per line</span>
      </span>
      <.input
        field={@form[:verify]}
        type="textarea"
        id={"#{@id}-verify"}
        rows={max(2, length(checks(@task)) + 1)}
        placeholder="e.g. `mix test test/app/export_test.exs` passes"
        class={@area_class}
        wrapper_class="block"
      />
    </div>
    <div class="grid gap-3 sm:grid-cols-3">
      <div class="block">
        <span class="mb-1 block text-xs font-medium text-base-content/60">Agent</span>
        <.input
          field={@form[:agent]}
          type="select"
          id={"#{@id}-agent"}
          options={@agent_options}
          class={@select_class}
          wrapper_class="block"
        />
      </div>
      <div class="block">
        <span class="mb-1 block text-xs font-medium text-base-content/60">Model</span>
        <.input
          field={@form[:model]}
          type="select"
          id={"#{@id}-model"}
          options={@model_options}
          class={@select_class}
          wrapper_class="block"
        />
      </div>
      <div class="block">
        <span class="mb-1 flex items-baseline justify-between text-xs font-medium text-base-content/60">
          Requirements <span class="font-normal text-base-content/45">Comma separated</span>
        </span>
        <.input
          field={@form[:requirements]}
          id={"#{@id}-requirements"}
          autocomplete="off"
          placeholder="1.1, 1.2"
          class={[@field_class, "font-mono text-xs"]}
          wrapper_class="block"
        />
      </div>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :values, :map, default: %{}
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :class, :string, default: nil

  defp icon_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      title={@label}
      aria-label={@label}
      class={[
        "grid size-6 place-items-center rounded text-base-content/50 hover:bg-base-300 hover:text-base-content",
        @class
      ]}
      {@values}
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end

  # What a task is, from its title or, when that doesn't say, its first step:
  # {label, icon, colour classes}, in the colours base specs use (FactoryWeb.SpecParts).
  # The first that matches wins. Icon names are written out in full so Tailwind's
  # heroicons plugin sees them.
  @kinds [
    {~r/^(verify|check|confirm|typecheck|lint|run|smoke)\b|\btypecheck/i, "Check",
     "hero-check-badge-mini", "bg-teal-500/12 text-teal-500"},
    {~r/\btest(s|ing|ed)?\b/i, "Test", "hero-beaker-mini", "bg-success/12 text-success"},
    {~r/\b(docs?|documentation|readme|changelog|moduledoc|comments?)\b/i, "Docs",
     "hero-book-open-mini", "bg-fuchsia-500/12 text-fuchsia-500"},
    {~r/^(fix|repair|resolve)\b|\b(bugs?|crash\w*|regression)\b/i, "Fix", "hero-bug-ant-mini",
     "bg-orange-500/12 text-orange-500"},
    {~r/\b(auth\w*|permissions?|secrets?|csrf|xss|sanitiz\w*|encrypt\w*)\b/i, "Security",
     "hero-shield-check-mini", "bg-error/12 text-error"},
    {~r/\b(migrations?|schema|database|db|tables?|columns?|seeds?|quer(y|ies))\b/i, "Data",
     "hero-circle-stack-mini", "bg-warning/15 text-warning"},
    {~r/\b(api|endpoints?|functions?|helpers?|types?|interfaces?|modules?|exports?)\b/i, "Code",
     "hero-code-bracket-mini", "bg-indigo-500/12 text-indigo-500"},
    {~r/\b(ui|buttons?|pages?|screens?|views?|templates?|components?|layouts?|styles?|css|modals?|forms?|icons?|themes?)\b/i,
     "UI", "hero-swatch-mini", "bg-info/12 text-info"}
  ]

  @code {"Code", "hero-code-bracket-mini", "bg-indigo-500/12 text-indigo-500"}

  @doc "What kind of task this is: `{label, icon, classes}` (Test, Check, Docs, UI, Code…)."
  def kind(task) do
    [task.title, List.first(task.details) || ""]
    |> Enum.find_value(fn text ->
      Enum.find_value(@kinds, fn {re, label, icon, classes} ->
        Regex.match?(re, text) && {label, icon, classes}
      end)
    end)
    |> Kernel.||(@code)
  end

  # The kind's colour for text alone: its classes without the background.
  defp kind_text({_label, _icon, classes}),
    do:
      classes |> String.split() |> Enum.reject(&String.starts_with?(&1, "bg-")) |> Enum.join(" ")

  # Whether the new task has anything written for Kiro to work from.
  defp draft_text?(draft), do: String.trim(draft.title <> draft.notes) != ""

  attr :text, :string, required: true

  # Task text with `code` shown as code (FactoryWeb.CoreComponents.inline_code/1). Nothing
  # else is formatted, so it reads as written.
  def inline(assigns) do
    ~H"{inline_code(@text)}"
  end

  def matches?(_task, ""), do: true

  def matches?(task, filter) do
    q = String.downcase(filter)

    [task.title | task.details ++ task.requirements]
    |> Enum.any?(&(&1 |> String.downcase() |> String.contains?(q)))
  end
end
