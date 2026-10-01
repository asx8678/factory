defmodule FactoryWeb.ReviewParts do
  @moduledoc """
  The chat's greeting for a review (`FactoryWeb.ChatGreeting.greeting/1`, with a review
  workflow), in two steps before the review itself (the chat's `review_step`):

    * `source/1`: which repository, and nothing more yet: one on this computer
      (`browse`, then `browse_pick`) or one cloned from its link (`review_link`,
      `Factory.Repos`).
    * `analysis/1`: what's in the repository chosen (`Factory.Scout`): the change
      suggested first, then the pull requests, the branches and the changes on this
      computer, each starting the review as a message to the Scout.

  Events go to the chat LiveView: `browse`, `review_link`, `review_change`,
  `review_branch`, `review_pr`, `review_local` and `scout_again`.
  """
  use FactoryWeb, :html

  @doc "The step the review is on. Takes the assigns of `FactoryWeb.ChatGreeting.greeting/1`."
  def greeting(%{review_step: :analysis} = assigns), do: analysis(assigns)
  def greeting(assigns), do: source(assigns)

  @doc """
  Step one: the repository to review, from this computer or cloned from a link. Nothing
  is looked at until one is chosen.
  """
  def source(assigns) do
    assigns =
      assign(assigns,
        root: Factory.Repos.root() |> String.replace_prefix(System.user_home!(), "~")
      )

    ~H"""
    <div id="review-source" class="step-in relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        Review · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        What do you want to review?
      </h1>
      <p class="mt-2 text-base-content/60">
        Choose a repository, then what in it to review. The Scout plans the checks and the
        Reviewer reports.
      </p>

      <div class="mt-5 grid gap-3 sm:grid-cols-2">
        <section
          id="review-local"
          class={[
            "flex flex-col rounded-xl border bg-base-100 p-4 transition-colors duration-150",
            if(@folder_error,
              do: "border-error/50",
              else: "border-base-300 hover:border-base-content/25"
            )
          ]}
        >
          <div class="flex items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-base-200 text-base-content/70">
              <.icon name="hero-folder" class="size-[18px]" />
            </span>
            <h2 class="font-semibold">On this computer</h2>
          </div>
          <p class="mt-2 text-sm text-base-content/60">
            A folder you already have, with its branches and uncommitted changes.
          </p>
          <p :if={@folder_error} id="review-folder-error" class="mt-2 text-xs text-error">
            {@folder_error}
          </p>
          <div class="mt-auto pt-3">
            <button
              id="review-choose-folder"
              type="button"
              phx-click="browse"
              disabled={@cloning != nil}
              class="btn btn-sm"
            >
              <.icon name="hero-folder-open-mini" class="size-4" /> Choose folder…
            </button>
          </div>
        </section>

        <section
          id="review-remote"
          class={[
            "flex flex-col rounded-xl border bg-base-100 p-4 transition-colors duration-150",
            if(@clone_error && !@cloning,
              do: "border-error/50",
              else: "border-base-300 hover:border-base-content/25"
            )
          ]}
        >
          <div class="flex items-center gap-2.5">
            <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-base-200 text-base-content/70">
              <.icon name="hero-cloud-arrow-down" class="size-[18px]" />
            </span>
            <h2 class="font-semibold">Clone from a link</h2>
          </div>
          <p class="mt-2 text-sm text-base-content/60">
            A repository or pull request, cloned with SSH into <span class="whitespace-nowrap">{@root}</span>, or fetched if it's already there.
          </p>
          <div class="mt-auto pt-3">
            <.form
              for={@link_form}
              id="review-repo-form"
              phx-submit="review_link"
              class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 py-1 pl-2.5 pr-1 transition-colors focus-within:border-primary/50"
            >
              <.icon name="hero-link-mini" class="size-4 shrink-0 text-base-content/45" />
              <.input
                field={@link_form[:link]}
                id="review-link"
                autocomplete="off"
                spellcheck="false"
                disabled={@cloning != nil}
                aria-label="Repository or pull request link"
                placeholder="git@github.com:owner/repo.git"
                class="h-7 w-full bg-transparent text-sm outline-none placeholder:text-base-content/35"
                wrapper_class="min-w-0 flex-1"
              />
              <button
                id="review-clone"
                class="btn btn-primary btn-sm phx-submit-loading:opacity-60"
                disabled={@cloning != nil}
              >
                <span :if={@cloning} class="loading loading-spinner loading-xs"></span>
                {if @cloning, do: "Cloning…", else: "Clone"}
              </button>
            </.form>
            <p :if={@cloning} id="review-cloning" class="mt-1.5 px-1 text-xs text-base-content/55">
              Cloning {@cloning} into {@root}…
            </p>
            <p
              :if={@clone_error && !@cloning}
              id="review-clone-error"
              class="mt-1.5 px-1 text-xs text-error"
            >
              {@clone_error}
            </p>
          </div>
        </section>
      </div>
    </div>
    """
  end

  @doc """
  Step two: what's in the repository chosen, the change suggested first (a pull request
  whose link was cloned, else the branch with the latest changes), then the rest by
  kind. Each starts the review.
  """
  def analysis(assigns) do
    dir = assigns.dir
    settings = (assigns.run && assigns.run.settings) || %{}
    picks = Factory.Scout.review_picks(assigns.scout)
    suggested = suggested(picks, settings["review_pr_branch"])
    rest = List.delete(picks, suggested)

    current =
      with {:ok, %{current: c}} when is_binary(c) <- assigns.scout, do: c, else: (_ -> nil)

    cloned = settings["review_source"] == "clone" or Factory.Repos.label(dir) != nil

    groups =
      [
        {"prs", "Pull requests", Enum.filter(rest, &(&1.kind == :pr or &1[:pr]))},
        {"branches", "Branches", Enum.filter(rest, &(&1.kind == :branch and !&1[:pr]))},
        {"local", "On #{current || "this branch"}",
         Enum.filter(rest, &(&1.kind in [:changes, :recent]))}
      ]
      |> Enum.reject(fn {_key, _title, list} -> list == [] end)

    assigns =
      assign(assigns,
        name: Factory.Repos.label(dir) || Path.basename(dir),
        path: String.replace_prefix(dir, System.user_home!(), "~"),
        cloned: cloned,
        picks: picks,
        suggested: suggested,
        groups: groups,
        stats: stats(assigns.scout, picks)
      )

    ~H"""
    <div id="review-analysis" class="step-in relative w-full max-w-3xl px-1">
      <div class="flex items-start gap-3">
        <div class="min-w-0 flex-1">
          <p class="text-xs font-medium text-base-content/45">
            Review · {Calendar.strftime(Date.utc_today(), "%-d %b")}
          </p>
          <h1 class="mt-1 truncate text-2xl font-semibold leading-tight tracking-tight">
            {@name}
          </h1>
          <p class="mt-1.5 flex min-w-0 items-center gap-2 text-xs text-base-content/55">
            <span class={[
              "inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-0.5 font-medium",
              if(@cloned,
                do: "bg-info/10 text-info",
                else: "bg-base-content/[0.06] text-base-content/70"
              )
            ]}>
              <.icon
                name={
                  if @cloned, do: "hero-cloud-arrow-down-micro", else: "hero-computer-desktop-micro"
                }
                class="size-3.5"
              />
              {if @cloned, do: "Cloned", else: "On this computer"}
            </span>
            <span id="review-path" class="truncate font-mono">{@path}</span>
          </p>
        </div>
        <button
          id="review-change"
          type="button"
          phx-click="review_change"
          class="btn btn-ghost btn-sm shrink-0"
        >
          <.icon name="hero-arrows-right-left-micro" class="size-4" /> Change
        </button>
      </div>

      <div
        id="review-summary"
        class="mt-5 flex flex-wrap items-center gap-x-3 gap-y-1.5 border-y border-base-content/10 py-2 text-[13px] text-base-content/65"
      >
        <%= case @scout do %>
          <% :loading -> %>
            <span class="flex items-center gap-2">
              <span class="loading loading-spinner loading-xs text-primary"></span>
              Looking at its branches and changes…
            </span>
          <% {:error, _} -> %>
            <span class="text-error">Couldn't read this repository.</span>
          <% _ -> %>
            <span :for={stat <- @stats} class="flex items-center gap-1.5">
              <.icon name={stat.icon} class="size-3.5 text-base-content/40" />
              <span class={stat[:mono] && "font-mono text-[12.5px] text-base-content"}>
                {stat.text}
              </span>
            </span>
        <% end %>
        <button
          id="scout-again"
          type="button"
          phx-click="scout_again"
          title="Look again"
          aria-label="Look again"
          class="ml-auto grid size-6 shrink-0 place-items-center rounded-md text-base-content/45 transition-colors hover:bg-base-content/[0.06] hover:text-base-content"
        >
          <.icon
            name="hero-arrow-path-micro"
            class={["size-3.5", @scout == :loading && "animate-spin motion-reduce:animate-none"]}
          />
        </button>
      </div>

      <div :if={@scout == :loading} id="review-loading" class="mt-4 space-y-2" aria-hidden="true">
        <div class="h-16 animate-pulse rounded-xl bg-base-content/[0.05]"></div>
        <div class="h-11 animate-pulse rounded-lg bg-base-content/[0.04]"></div>
        <div class="h-11 animate-pulse rounded-lg bg-base-content/[0.03]"></div>
      </div>

      <div
        :if={match?({:error, _}, @scout)}
        id="review-scout-error"
        class="mt-4 rounded-xl border border-error/30 bg-error/[0.04] px-4 py-3 text-sm"
      >
        <p>{elem(@scout, 1)}</p>
        <button
          type="button"
          phx-click="review_change"
          class="mt-2 text-sm font-medium text-primary hover:underline"
        >
          Choose another repository
        </button>
      </div>

      <p
        :if={match?({:ok, _}, @scout) and @picks == []}
        id="review-nothing"
        class="mt-4 rounded-xl border border-dashed border-base-300 px-4 py-3 text-sm text-base-content/60"
      >
        Nothing to review here yet: no branches with work beyond the base, and no changes.
        Describe below what to review, or paste a pull request's link.
      </p>

      <section
        :if={@suggested}
        id="review-suggested"
        class="mt-4 rounded-xl border border-primary/30 bg-primary/[0.04] px-4 py-3"
      >
        <p class="mb-1.5 flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide text-primary">
          <.icon name="hero-sparkles-micro" class="size-3.5" /> Suggested
        </p>
        <.pick_row id="review-suggested-pick" pick={@suggested} primary />
      </section>

      <section :for={{key, title, list} <- @groups} id={"review-#{key}"} class="mt-5">
        <h2 class="mb-1 px-1 text-xs font-medium text-base-content/50">
          {title} <span class="tabular-nums text-base-content/35">{length(list)}</span>
        </h2>
        <ol class="divide-y divide-base-content/[0.07] rounded-xl border border-base-300">
          <li :for={{pick, n} <- Enum.with_index(Enum.take(list, 5))} class="px-3.5 py-2.5">
            <.pick_row id={"review-#{key}-#{n}"} pick={pick} />
          </li>
        </ol>
        <details :if={length(list) > 5} class="group mt-1">
          <summary class="flex cursor-pointer list-none items-center gap-1 px-1 py-1 text-xs text-base-content/55 hover:text-base-content [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3.5 transition-transform group-open:rotate-90"
            />
            {length(list) - 5} more
          </summary>
          <ol class="mt-1 divide-y divide-base-content/[0.07] rounded-xl border border-base-300">
            <li :for={{pick, n} <- Enum.with_index(Enum.drop(list, 5), 5)} class="px-3.5 py-2.5">
              <.pick_row id={"review-#{key}-#{n}"} pick={pick} />
            </li>
          </ol>
        </details>
      </section>

      <p
        :if={scout_notes(@scout) != []}
        class="mt-4 px-1 text-xs text-base-content/45"
      >
        {Enum.join(scout_notes(@scout), " ")}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :pick, :map, required: true
  attr :primary, :boolean, default: false

  # One thing to review: what it is, where it's from and how recent, and Review.
  defp pick_row(assigns) do
    ~H"""
    <div id={@id} class="flex items-center gap-3">
      <.icon
        name={
          case @pick.kind do
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
          <span class={["truncate", @pick.kind == :branch && !@pick[:pr] && "font-mono text-[13px]"]}>
            {@pick.label}
          </span>
          <span
            :if={@pick[:latest]}
            class="shrink-0 rounded bg-warning/15 px-1.5 text-[10.5px] font-medium text-warning"
          >
            Latest changes
          </span>
          <span
            :if={@pick[:current]}
            class="shrink-0 rounded bg-primary/10 px-1.5 text-[10.5px] font-medium text-primary"
          >
            checked out
          </span>
          <span :if={@pick[:ahead]} class="shrink-0 text-xs text-base-content/50">
            {@pick.ahead} ahead
          </span>
        </p>
        <p class="truncate text-xs text-base-content/50">
          {@pick.detail}<span :if={@pick.at}> · {Layouts.ago(@pick.at)}</span>
        </p>
      </div>
      <button
        type="button"
        phx-click={
          case @pick.kind do
            :branch -> "review_branch"
            :pr -> "review_pr"
            _ -> "review_local"
          end
        }
        phx-value-branch={@pick.kind == :branch && @pick.value}
        phx-value-url={@pick.kind == :pr && @pick.value}
        phx-value-what={@pick.kind in [:changes, :recent] && @pick.kind}
        class={[
          "btn btn-sm shrink-0 phx-click-loading:pointer-events-none phx-click-loading:opacity-60",
          if(@primary, do: "btn-primary", else: "btn-ghost")
        ]}
      >
        Review
      </button>
    </div>
    """
  end

  # What leads: the pull request whose link was cloned, else the branch with the latest
  # changes, else the first there is.
  defp suggested(picks, pr_branch) do
    (pr_branch && Enum.find(picks, &(&1.kind == :branch and &1.value == pr_branch))) ||
      Enum.find(picks, & &1[:latest]) || List.first(picks)
  end

  # The line above the picks: the branch it's on, and how much there is to review.
  defp stats({:ok, scout}, picks) do
    branches = Enum.count(picks, &(&1.kind == :branch and !&1[:pr]))
    prs = Enum.count(picks, &(&1.kind == :pr or &1[:pr]))

    [
      scout.current &&
        %{
          icon: "hero-arrows-right-left-micro",
          text:
            if(scout.base && scout.base != scout.current,
              do: "#{scout.current} → #{scout.base}",
              else: scout.current
            ),
          mono: true
        },
      branches > 0 &&
        %{
          icon: "hero-queue-list-micro",
          text: count(branches, "branch", "branches") <> " with work"
        },
      prs > 0 && %{icon: "hero-arrow-top-right-on-square-micro", text: count(prs, "pull request")},
      scout.dirty > 0 &&
        %{icon: "hero-pencil-square-micro", text: count(scout.dirty, "file") <> " changed"}
    ]
    |> Enum.filter(& &1)
  end

  defp stats(_scout, _picks), do: []

  defp count(n, one, many \\ nil), do: "#{n} #{if n == 1, do: one, else: many || one <> "s"}"

  # Why pull requests aren't listed, when they aren't.
  defp scout_notes({:ok, %{prs_note: note}}) when is_binary(note), do: [note]

  defp scout_notes(_scout), do: []
end
