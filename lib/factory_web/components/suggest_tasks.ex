defmodule FactoryWeb.SuggestTasks do
  @moduledoc """
  The "Suggest tasks with Kiro" window on a spec's Tasks step: Kiro reads the
  project, asks questions, then suggests tasks to choose from. The spec's `plan`
  says which stage it's at; the events are handled by `FactoryWeb.SpecLive`.
  """
  use FactoryWeb, :html

  @stages [
    {"read", "Read the project"},
    {"answer", "Answer questions"},
    {"choose", "Choose tasks"}
  ]

  attr :spec, :map, required: true
  attr :activity, :list, required: true
  attr :answers, :map, required: true
  attr :others, :map, required: true
  attr :question, :integer, default: 0, doc: "the question on screen"
  attr :picked, :any, required: true
  attr :add_mode, :string, required: true
  attr :project_dir, :string, required: true

  def window(assigns) do
    plan = assigns.spec.plan

    assigns =
      assign(assigns,
        plan: plan,
        status: plan["status"],
        stage: stage(plan),
        stages: @stages
      )

    ~H"""
    <div
      id="suggest-window"
      class="fixed inset-0 z-50 flex items-center justify-center bg-base-content/25 p-3 backdrop-blur-[2px] sm:p-6"
      phx-window-keydown="close_suggest"
      phx-key="Escape"
      role="dialog"
      aria-modal="true"
      aria-labelledby="suggest-title"
    >
      <div class="absolute inset-0" phx-click="close_suggest" aria-hidden="true"></div>

      <div class="relative flex max-h-full min-h-[min(34rem,100%)] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-2xl">
        <header class="flex flex-wrap items-center gap-x-6 gap-y-3 border-b border-base-300 px-5 py-4 sm:px-6">
          <h2 id="suggest-title" class="text-lg font-semibold tracking-tight">
            Suggest tasks with Kiro
          </h2>
          <ol class="flex items-center gap-2 text-[13px]">
            <%= for {{key, label}, i} <- Enum.with_index(@stages, 1) do %>
              <li :if={i > 1} class="h-px w-4 bg-base-300" aria-hidden="true"></li>
              <li
                aria-current={@stage == key && "step"}
                class={[
                  "flex items-center gap-1.5",
                  cond do
                    @stage == key -> "font-medium text-base-content"
                    stage_done?(@stage, key) -> "text-base-content/60"
                    true -> "text-base-content/35"
                  end
                ]}
              >
                <span class={[
                  "grid size-4 place-items-center rounded-full text-[10px] tabular-nums",
                  if(stage_done?(@stage, key),
                    do: "bg-success text-success-content",
                    else: "border border-current"
                  )
                ]}>
                  <.icon :if={stage_done?(@stage, key)} name="hero-check-micro" class="size-3" />
                  <span :if={!stage_done?(@stage, key)}>{i}</span>
                </span>
                <span class="hidden sm:inline">{label}</span>
              </li>
            <% end %>
          </ol>
          <button
            phx-click="close_suggest"
            class="ml-auto grid size-8 place-items-center rounded-md text-base-content/55 hover:bg-base-200 hover:text-base-content"
            aria-label="Close"
            title="Close (Kiro keeps working)"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <.start :if={@status in [nil, "error"] and @plan["failed"] != "writing"} {assigns} />
        <.working :if={@status == "reading"} activity={@activity} title="Kiro is reading the project">
          It looks at how the project is built and the code this spec touches.
          This usually takes a minute or two.
        </.working>
        <.questions :if={@status == "questions"} {assigns} />
        <.working
          :if={@status == "writing"}
          activity={@activity}
          tasks={@plan["tasks"] || []}
          title="Kiro is writing tasks"
        >
          From the spec, the project and your answers. This usually takes a minute or two.
        </.working>
        <.failed_writing :if={@status == "error" and @plan["failed"] == "writing"} plan={@plan} />
        <.choose :if={@status == "tasks"} {assigns} />
      </div>
    </div>
    """
  end

  defp stage(%{"status" => s}) when s in ["questions", "writing"], do: "answer"
  defp stage(%{"status" => "tasks"}), do: "choose"
  defp stage(%{"status" => "error", "failed" => "writing"}), do: "answer"
  defp stage(_), do: "read"

  defp stage_done?(current, key) do
    order = ~w(read answer choose)
    Enum.find_index(order, &(&1 == key)) < Enum.find_index(order, &(&1 == current))
  end

  # Stage 1: the project folder, then Kiro reads it.
  defp start(assigns) do
    ~H"""
    <form id="plan-read" phx-submit="plan_read" class="flex min-h-0 flex-1 flex-col">
      <div class="flex-1 overflow-y-auto px-5 py-6 sm:px-6">
        <div class="max-w-2xl">
          <p class="text-[14px] leading-relaxed text-base-content/75">
            Kiro first reads the project to learn how it's built. It can read files but can't change
            them or run commands. Then it asks you a few questions and suggests about 20 tasks
            you can pick from.
          </p>

          <p :if={@status == "error"} class="mt-5 rounded-lg bg-error/10 px-4 py-3 text-sm text-error">
            {@plan["error"]}
          </p>

          <label class="mt-6 block">
            <span class="text-sm font-medium">Project folder</span>
            <span class="block text-xs text-base-content/70">
              The folder with the code this spec is for.
            </span>
            <input
              name="dir"
              value={@project_dir}
              required
              spellcheck="false"
              class="input mt-1.5 w-full font-mono text-[13px]"
            />
          </label>
        </div>
      </div>
      <footer class="flex items-center justify-end gap-2 border-t border-base-300 px-5 py-3 sm:px-6">
        <button type="button" phx-click="close_suggest" class="btn btn-ghost btn-sm">Cancel</button>
        <button class="btn btn-primary btn-sm">
          {if @status == "error", do: "Try again", else: "Read the project"}
        </button>
      </footer>
    </form>
    """
  end

  attr :activity, :list, required: true
  attr :title, :string, required: true
  attr :tasks, :list, default: []
  slot :inner_block, required: true

  # Waiting for Kiro: what it's reading, and the tasks it has suggested so far.
  defp working(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-2 px-6 py-16 text-center">
      <span class="loading loading-spinner loading-md text-info"></span>
      <h3 class="mt-2 font-medium">{@title}</h3>
      <p class="max-w-md text-sm text-base-content/75">{render_slot(@inner_block)}</p>
      <ul class="mt-4 w-full max-w-md space-y-1 text-left font-mono text-[12px]">
        <li
          :for={{line, i} <- Enum.with_index(@activity)}
          class={[
            "truncate",
            if(i == length(@activity) - 1, do: "text-base-content/75", else: "text-base-content/55")
          ]}
        >
          {line}
        </li>
      </ul>
      <div :if={@tasks != []} id="suggested-so-far" class="mt-5 w-full max-w-md text-left">
        <p class="mb-1.5 text-xs font-medium text-base-content/60">
          Suggested so far ({length(@tasks)})
        </p>
        <ol class="space-y-1 text-sm">
          <li :for={{t, i} <- Enum.with_index(@tasks, 1)} class="flex gap-2">
            <span class="w-5 shrink-0 text-right tabular-nums text-base-content/45">{i}.</span>
            <span class="min-w-0 truncate">{t["title"]}</span>
          </li>
        </ol>
      </div>
      <p class="mt-4 text-xs text-base-content/60">You can close this window; Kiro keeps working.</p>
    </div>
    """
  end

  # Stage 2: Kiro's questions, one at a time, each with options a, b, c… and an answer
  # of your own. Keys: A–D pick, Enter moves on.
  defp questions(%{plan: %{"questions" => []}} = assigns) do
    ~H"""
    <form id="plan-answers" phx-submit="plan_tasks" class="flex min-h-0 flex-1 flex-col">
      <div class="flex-1 overflow-y-auto px-5 py-8 sm:px-8">
        <div class="mx-auto max-w-2xl">
          <p class="text-base leading-relaxed">
            Kiro has no questions: the spec answers everything it needs.
          </p>
          <.learned project={@plan["project"]} />
        </div>
      </div>
      <footer class="flex items-center justify-end gap-2 border-t border-base-300 px-5 py-3 sm:px-8">
        <button id="plan-suggest" class="btn btn-primary btn-sm">Suggest tasks</button>
      </footer>
    </form>
    """
  end

  defp questions(assigns) do
    questions = assigns.plan["questions"]
    i = min(assigns.question, length(questions) - 1)
    q = Enum.at(questions, i)
    key = to_string(i)

    assigns =
      assign(assigns,
        questions: questions,
        i: i,
        q: q,
        key: key,
        chosen: assigns.answers[key],
        last: i == length(questions) - 1
      )

    ~H"""
    <form
      id="plan-answers"
      phx-change="plan_answer"
      phx-submit="plan_next"
      phx-hook="QuestionKeys"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="flex-1 overflow-y-auto px-5 py-7 sm:px-8">
        <div class="mx-auto mb-5 flex max-w-2xl items-center gap-3">
          <span class="text-xs font-medium tabular-nums text-base-content/70">
            {@i + 1} of {length(@questions)}
          </span>
          <nav class="flex gap-1" aria-label="Questions">
            <button
              :for={{_q, n} <- Enum.with_index(@questions)}
              type="button"
              phx-click="plan_question"
              phx-value-i={n}
              aria-label={"Question #{n + 1}"}
              aria-current={n == @i && "step"}
              title={"Question #{n + 1}"}
              class="group py-1.5"
            >
              <span class={[
                "block h-1 w-6 rounded-full transition-colors",
                cond do
                  n == @i -> "bg-primary"
                  n < @i -> "bg-base-content/50 group-hover:bg-base-content/70"
                  true -> "bg-base-content/15 group-hover:bg-base-content/35"
                end
              ]}></span>
            </button>
          </nav>
        </div>

        <fieldset class="mx-auto max-w-2xl">
          <legend class="text-lg font-semibold leading-snug tracking-tight text-pretty">
            {@q["question"]}
          </legend>
          <p :if={@q["why"] != ""} class="mt-1.5 text-sm leading-relaxed text-base-content/70">
            {@q["why"]}
          </p>

          <div class="mt-5 space-y-1.5" role="radiogroup">
            <label
              :for={{option, j} <- Enum.with_index(@q["options"])}
              data-key={letter(j)}
              class={option_class(@chosen == option)}
            >
              <input
                type="radio"
                name={"answer[#{@key}]"}
                value={option}
                checked={@chosen == option}
                class="sr-only"
              />
              <.dot on={@chosen == option} letter={letter(j)} />
              <span class="flex-1">
                {option}
                <span
                  :if={j == 0}
                  class="ml-1 inline-block whitespace-nowrap rounded-full bg-success/15 px-1.5 text-[11px] font-medium leading-[18px] text-success"
                >
                  Recommended
                </span>
              </span>
            </label>

            <label
              data-key={letter(length(@q["options"]))}
              class={option_class(@chosen == "__other")}
            >
              <input
                type="radio"
                name={"answer[#{@key}]"}
                value="__other"
                checked={@chosen == "__other"}
                class="sr-only"
              />
              <.dot on={@chosen == "__other"} letter={letter(length(@q["options"]))} />
              <input
                name={"other[#{@key}]"}
                value={@others[@key]}
                placeholder="Something else: write your own answer"
                phx-debounce="300"
                class="min-w-0 flex-1 bg-transparent outline-none placeholder:text-base-content/50"
              />
            </label>
          </div>

          <.learned :if={@i == 0} project={@plan["project"]} />
        </fieldset>
      </div>

      <footer class="flex items-center gap-2 border-t border-base-300 px-5 py-3 sm:px-8">
        <button
          type="button"
          phx-click="plan_skip"
          class="btn btn-ghost btn-sm text-base-content/70"
          title="Kiro uses its recommended answers for everything"
        >
          Skip questions
        </button>
        <p class="ml-auto hidden items-center gap-1 text-xs text-base-content/55 md:flex">
          <kbd class="kbd kbd-xs">A</kbd>–<kbd class="kbd kbd-xs">{String.upcase(
            letter(length(@q["options"]))
          )}</kbd>
          to pick <kbd class="kbd kbd-xs ml-2">Enter</kbd>
          for next
        </p>
        <button
          :if={@i > 0}
          type="button"
          phx-click="plan_question"
          phx-value-i={@i - 1}
          class="btn btn-ghost btn-sm ml-2 max-md:ml-auto"
        >
          Back
        </button>
        <button
          id="plan-next"
          class={["btn btn-primary btn-sm", @i == 0 && "max-md:ml-auto"]}
        >
          {if @last, do: "Suggest tasks", else: "Next"}
        </button>
      </footer>
    </form>
    """
  end

  defp option_class(on) do
    [
      "flex cursor-pointer items-start gap-3 rounded-lg border px-3.5 py-2.5 text-sm leading-5 transition-colors",
      if(on,
        do: "border-primary bg-primary/10 ring-1 ring-primary",
        else: "border-base-content/15 hover:border-base-content/35 hover:bg-base-200"
      )
    ]
  end

  attr :on, :boolean, required: true
  attr :letter, :string, required: true

  # The radio mark, with the option's key letter inside when it isn't picked.
  defp dot(assigns) do
    ~H"""
    <span class={[
      "grid size-5 shrink-0 place-items-center rounded-full text-[11px] font-semibold uppercase",
      if(@on,
        do: "bg-primary text-primary-content",
        else: "border border-base-content/30 text-base-content/70"
      )
    ]}>
      <.icon :if={@on} name="hero-check-micro" class="size-3.5" />
      <span :if={!@on}>{@letter}</span>
    </span>
    """
  end

  attr :project, :string, required: true

  defp learned(assigns) do
    ~H"""
    <details :if={@project != ""} class="group mt-8 border-t border-base-300 pt-4 text-sm">
      <summary class="flex cursor-pointer list-none items-center gap-1.5 text-base-content/70 hover:text-base-content">
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 transition-transform group-open:rotate-90"
        /> What Kiro learned about the project
      </summary>
      <p class="mt-2 whitespace-pre-line pl-5 text-[13px] leading-relaxed text-base-content/75">
        {@project}
      </p>
    </details>
    """
  end

  defp failed_writing(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col items-center justify-center gap-3 px-6 py-16 text-center">
      <p class="max-w-md rounded-lg bg-error/10 px-4 py-3 text-sm text-error">{@plan["error"]}</p>
      <p class="text-sm text-base-content/60">Your answers are kept.</p>
      <div class="flex gap-2">
        <button phx-click="plan_restart" class="btn btn-ghost btn-sm">Start over</button>
        <button phx-click="plan_retry" class="btn btn-primary btn-sm">Try again</button>
      </div>
    </div>
    """
  end

  # Stage 3: the suggested tasks, all picked; untick the ones you don't want.
  defp choose(assigns) do
    tasks = assigns.plan["tasks"]
    count = MapSet.size(assigns.picked)

    assigns =
      assign(assigns,
        tasks: tasks,
        count: count,
        has_tasks: String.trim(assigns.spec.tasks) != ""
      )

    ~H"""
    <form
      id="plan-pick"
      phx-change="plan_pick"
      phx-submit="plan_add"
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="flex items-center gap-3 border-b border-base-300 px-5 py-2.5 text-sm sm:px-6">
        <span class="text-base-content/70">
          <span class="font-medium tabular-nums text-base-content">{@count}</span>
          of {length(@tasks)} picked
        </span>
        <button
          type="button"
          phx-click="plan_all"
          class="text-base-content/55 hover:text-base-content"
        >
          Pick all
        </button>
        <button
          type="button"
          phx-click="plan_none"
          class="text-base-content/55 hover:text-base-content"
        >
          None
        </button>
      </div>

      <ol class="flex-1 divide-y divide-base-300 overflow-y-auto">
        <li :for={{task, i} <- Enum.with_index(@tasks)}>
          <label class={[
            "flex cursor-pointer items-start gap-3 px-5 py-3 sm:px-6",
            if(MapSet.member?(@picked, i),
              do: "hover:bg-base-200",
              else: "opacity-55 hover:opacity-80"
            )
          ]}>
            <input
              type="checkbox"
              name="pick[]"
              value={i}
              checked={MapSet.member?(@picked, i)}
              class="checkbox checkbox-sm mt-0.5"
            />
            <span class="w-6 shrink-0 pt-px text-right text-sm tabular-nums text-base-content/55">
              {i + 1}
            </span>
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-medium">{task["title"]}</span>
              <span
                :if={details_text(task) != ""}
                class="mt-0.5 block text-[13px] text-base-content/60"
              >
                {details_text(task)}
              </span>
            </span>
            <span class="flex shrink-0 items-center gap-2 pt-px text-xs text-base-content/50">
              <span :if={task["requirements"] != []} title="Requirements it covers">
                Req {Enum.join(task["requirements"], ", ")}
              </span>
              <span
                :if={task["size"]}
                title={size_title(task["size"])}
                class="grid size-5 place-items-center rounded bg-base-200 font-medium text-base-content/70"
              >
                {task["size"]}
              </span>
            </span>
          </label>
        </li>
      </ol>

      <footer class="flex flex-wrap items-center gap-x-4 gap-y-2 border-t border-base-300 px-5 py-3 sm:px-6">
        <div :if={@has_tasks} class="flex items-center gap-4 text-sm">
          <label class="flex cursor-pointer items-center gap-1.5">
            <input
              type="radio"
              name="mode"
              value="append"
              checked={@add_mode != "replace"}
              class="radio radio-xs"
            /> Add after my tasks
          </label>
          <label class="flex cursor-pointer items-center gap-1.5">
            <input
              type="radio"
              name="mode"
              value="replace"
              checked={@add_mode == "replace"}
              class="radio radio-xs"
            /> Replace my tasks
          </label>
        </div>
        <div class="ml-auto flex items-center gap-2">
          <button
            type="button"
            phx-click="plan_restart"
            data-confirm="Start over? Kiro's questions and suggestions are cleared."
            class="btn btn-ghost btn-sm"
          >
            Start over
          </button>
          <button id="plan-add" class="btn btn-primary btn-sm" disabled={@count == 0}>
            Add {@count} {if @count == 1, do: "task", else: "tasks"}
          </button>
        </div>
      </footer>
    </form>
    """
  end

  defp letter(i), do: <<?a + i>>

  defp size_title("S"), do: "Small change"
  defp size_title("M"), do: "Medium change"
  defp size_title(_), do: "Large change"

  # A suggestion's details: a list of lines, or one string in suggestions saved before
  # tasks had one shape.
  defp details_text(task), do: task["details"] |> List.wrap() |> Enum.join(" ")
end
