defmodule FactoryWeb.ChatGreeting do
  @moduledoc """
  A new chat before its first message (`FactoryWeb.ChatLive`): the steps to set it up
  and, once it has a folder, what to build or review there, from what the scout found
  (`Factory.Scout`). Events from it go to the chat LiveView.
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

  attr :link_form, :any,
    default: nil,
    doc: "the form for a repository's link to review (to_form(%{\"link\" => \"\"}))"

  attr :scout, :any,
    default: nil,
    doc: "what there is to review in the folder (Factory.Scout): nil, :loading or a result"

  # Review a PR: the repository to review first (cloned with SSH into its own folder),
  # then, for the folder the chat is on, the branch with the latest changes and the
  # rest. Each starts the review as a message to the Scout.
  def greeting(%{focus: nil, workflow: %{key: "review"}} = assigns) do
    assigns =
      assign(assigns,
        picks: if(assigns.dir_ok, do: Factory.Scout.review_picks(assigns.scout), else: []),
        root: Factory.Repos.root() |> String.replace_prefix(System.user_home!(), "~")
      )

    ~H"""
    <div id="chat-review" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        Review · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        <%= if @dir_ok do %>
          What should we review in <span class="text-primary">{Path.basename(@dir)}</span>?
        <% else %>
          What should we review?
        <% end %>
      </h1>
      <p class="mt-2 text-base-content/60">
        Paste the repository's link, or a pull request's. Factory clones it and lists its
        branches, latest changes first; pick one, and the Scout plans what to check before
        the Reviewer reports.
      </p>

      <.form
        for={@link_form}
        id="review-repo-form"
        phx-submit="review_link"
        class={[
          "mt-5 flex items-center gap-2 rounded-xl border bg-base-100 py-1.5 pl-3 pr-1.5 transition-colors focus-within:border-primary/50",
          if(@clone_error, do: "border-error/50", else: "border-base-300")
        ]}
      >
        <.icon name="hero-link-mini" class="size-4 shrink-0 text-base-content/45" />
        <.input
          field={@link_form[:link]}
          id="review-link"
          autocomplete="off"
          spellcheck="false"
          disabled={@cloning != nil}
          placeholder="git@github.com:owner/repo.git, or a repository or pull request link"
          class="h-7 w-full bg-transparent text-sm outline-none placeholder:text-base-content/35"
          wrapper_class="min-w-0 flex-1"
        />
        <button
          id="review-clone"
          class="btn btn-primary btn-sm phx-submit-loading:opacity-60"
          disabled={@cloning != nil}
        >
          <span :if={@cloning} class="loading loading-spinner loading-xs"></span>
          {if @cloning, do: "Cloning…", else: "Clone & scan"}
        </button>
      </.form>
      <p :if={@cloning} id="review-cloning" class="mt-1.5 px-1 text-xs text-base-content/55">
        Cloning {@cloning} with SSH into {@root}…
      </p>
      <p
        :if={@clone_error && !@cloning}
        id="review-clone-error"
        class="mt-1.5 px-1 text-xs text-error"
      >
        {@clone_error}
      </p>
      <p :if={!@cloning && !@clone_error} class="mt-1.5 px-1 text-xs text-base-content/45">
        Cloned with SSH into {@root}; asked for again, it's fetched instead.
      </p>

      <button
        :if={!@dir_ok}
        id="review-browse"
        type="button"
        phx-click="browse"
        class="mt-4 flex w-full items-center gap-3 rounded-xl border border-base-300 px-3.5 py-2.5 text-left transition-colors hover:border-base-content/25"
      >
        <.icon name="hero-folder-mini" class="size-4 shrink-0 text-base-content/50" />
        <span class="min-w-0 flex-1 text-sm">
          Or review a repository that's already on this computer
        </span>
        <span class="text-xs text-base-content/55">Browse…</span>
      </button>

      <section :if={@dir_ok} id="review-scout" class="mt-4 rounded-xl border border-base-300">
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
            aria-label="Look at the branches again"
            class="grid size-6 shrink-0 place-items-center rounded-md text-base-content/45 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon
              name="hero-arrow-path-micro"
              class={["size-3.5", @scout == :loading && "animate-spin motion-reduce:animate-none"]}
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
                  :if={pick[:latest]}
                  class="shrink-0 rounded bg-amber-400/15 px-1.5 text-[10.5px] font-medium text-amber-600 dark:text-amber-300"
                >
                  Latest changes
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
              class={[
                "btn btn-sm shrink-0 phx-click-loading:pointer-events-none phx-click-loading:opacity-60",
                if(pick[:latest], do: "btn-primary", else: "btn-ghost")
              ]}
            >
              Review
            </button>
            <button
              :if={pick.kind == :pr}
              type="button"
              phx-click="review_pr"
              phx-value-url={pick.value}
              class="btn btn-ghost btn-sm shrink-0 phx-click-loading:pointer-events-none phx-click-loading:opacity-60"
            >
              Review
            </button>
            <button
              :if={pick.kind in [:changes, :recent]}
              type="button"
              phx-click="review_local"
              phx-value-what={pick.kind}
              class="btn btn-ghost btn-sm shrink-0 phx-click-loading:pointer-events-none phx-click-loading:opacity-60"
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

  # Set up (a folder is chosen): describe the change, and the planner plans it.
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

  # Why pull requests aren't listed, when they aren't.
  defp scout_notes({:ok, %{prs_note: note}}) when is_binary(note), do: [note]

  defp scout_notes(_scout), do: []

  @doc "The run worked on last, other than this one: one that has started or has tasks."
  def last_run(runs, current) do
    Enum.find(runs, fn r ->
      (current == nil or r.id != current.id) and (r.status != "draft" or r.tasks != [])
    end)
  end
end
