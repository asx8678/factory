defmodule FactoryWeb.ChatGreeting do
  @moduledoc """
  A new chat before its first message (`FactoryWeb.ChatLive`): the steps to set it up
  and, once it has a folder, what to build there, from what the scout found
  (`Factory.Scout`). A review's greeting is `FactoryWeb.ReviewParts`, troubleshooting's
  `FactoryWeb.IncidentParts`. Events from it go to the chat LiveView.
  """
  use FactoryWeb, :html
  alias Factory.Workflows

  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :dir, :string, default: ""
  attr :dir_ok, :boolean, default: false
  attr :workflow, :map, default: nil
  attr :uploads, :map, default: nil
  attr :specs, :integer, default: 0
  attr :chain, :list, default: []
  attr :last_run, :any, default: nil

  attr :ideas, :any,
    default: nil,
    doc: "what there is to pick up in the folder (Factory.Scout.ideas/2), or nil while it looks"

  attr :cloning, :string, default: nil, doc: "the repository being cloned, while it is"
  attr :clone_error, :string, default: nil
  attr :folder_error, :string, default: nil, doc: "why a folder picked for a review won't do"

  attr :review_step, :atom,
    default: nil,
    doc: "for Review a PR: :source (choose the repository) or :analysis (what's in it)"

  attr :run, :any, default: nil

  attr :link_form, :any,
    default: nil,
    doc: "the form for a repository's link to review (to_form(%{\"link\" => \"\"}))"

  attr :scout, :any,
    default: nil,
    doc: "what there is to review in the folder (Factory.Scout): nil, :loading or a result"

  # Review a PR: its own greeting (FactoryWeb.ReviewParts).
  def greeting(%{focus: nil, workflow: %{key: "review"}} = assigns),
    do: FactoryWeb.ReviewParts.greeting(assigns)

  # Troubleshooting: its own greeting, with its two modes (FactoryWeb.IncidentParts).
  def greeting(%{focus: nil, workflow: %{key: "incident"}} = assigns),
    do: FactoryWeb.IncidentParts.greeting(assigns)

  # Set up (a folder is chosen): describe the change, and the planner plans it.
  def greeting(%{focus: nil, dir_ok: true} = assigns) do
    ~H"""
    <div id="chat-ready" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        New run · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        What are we building in <span class="font-semibold">{Path.basename(@dir)}</span>?
      </h1>

      <p class="mt-2 text-base-content/60">
        Describe the change below. {if is_map(@to), do: @to.name, else: "The planner"} reads
        the code, asks about anything unclear, and lists the tasks for you to refine.
      </p>

      <div
        :if={suggestions(@ideas, @workflow) != []}
        id="examples"
        class="mt-4 flex flex-wrap gap-1.5"
      >
        <button
          :for={idea <- suggestions(@ideas, @workflow)}
          type="button"
          title={idea.text}
          phx-click={JS.dispatch("factory:fill", to: "#chat-input", detail: %{text: idea.text})}
          class={[
            "flex max-w-full items-center gap-1.5 rounded-full border px-3 py-1 text-[13px] transition-colors hover:border-primary/40 hover:bg-primary/[0.05] hover:text-base-content",
            if(idea.here,
              do: "border-primary/25 text-base-content/85",
              else: "border-base-300 text-base-content/70"
            )
          ]}
        >
          <.icon
            :if={idea.here}
            name="hero-code-bracket-micro"
            class="size-3.5 shrink-0 text-primary/80"
          />
          <span class="truncate">{idea.label}</span>
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

  # A new chat without a folder yet: the first step is to choose one.
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
            id="choose-folder"
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

  # A chat with one agent.
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

  # Ways to start that suit any project, when the folder has nothing of its own to
  # suggest (or to fill the row after what it has), by the kind of job the workflow does.
  @starters %{
    "feature" => [
      "Suggest the three most useful improvements to this project",
      "Add tests where the code has none",
      "Make the README explain how to set up and run the project"
    ],
    "bug" => [
      "Run the tests and fix what fails",
      "Fix the warnings the build prints",
      "Find errors the code swallows and handle them"
    ]
  }

  # A new chat's suggestions: what the folder has to pick up (Factory.Scout.ideas/2),
  # marked as from the code, then starters for the kind of job, four at most. Starters
  # for building are only offered to the workflows that build; the others keep theirs.
  defp suggestions(ideas, workflow) do
    kind = Workflows.kind(workflow)
    here = for i <- ideas || [], do: Map.put(i, :here, true)

    starters =
      for text <- Map.get(@starters, kind, []), do: %{label: text, text: text, here: false}

    Enum.take(if(kind in ["feature", "bug", "other"], do: here, else: []) ++ starters, 4)
  end

  @doc "The run worked on last, other than this one: one that has started or has tasks."
  def last_run(runs, current) do
    Enum.find(runs, fn r ->
      (current == nil or r.id != current.id) and (r.status != "draft" or r.tasks != [])
    end)
  end
end
