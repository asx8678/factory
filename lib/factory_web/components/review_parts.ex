defmodule FactoryWeb.ReviewParts do
  @moduledoc """
  The chat's greeting for a review (`FactoryWeb.ChatParts.greeting/1`, with a review
  workflow): the repository's link, cloned or fetched (`Factory.Repos`), and what the
  Scout found worth reviewing in the chat's folder (`Factory.Scout`). Events go to the
  chat LiveView: `review_link`, `review_branch`, `review_pr`, `review_local`,
  `scout_again` and `browse`.
  """
  use FactoryWeb, :html

  @doc """
  Review a PR: the repository to review first (cloned with SSH into its own folder),
  then, for the folder the chat is on, the branch with the latest changes and the
  rest. Each starts the review as a message to the Scout. Takes the assigns of
  `FactoryWeb.ChatParts.greeting/1`.
  """
  def greeting(assigns) do
    assigns =
      assign(assigns,
        picks: if(assigns.dir_ok, do: review_picks(assigns.scout), else: []),
        root: Factory.Repos.root() |> String.replace_prefix(System.user_home!(), "~"),
        cloned: assigns.dir_ok && Factory.Repos.label(assigns.dir)
      )

    ~H"""
    <div id="chat-review" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        Review · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        <%= cond do %>
          <% @cloned -> %>
            What should we review in <span class="text-primary">{@cloned}</span>?
          <% @dir_ok -> %>
            What should we review in <span class="text-primary">{Path.basename(@dir)}</span>?
          <% true -> %>
            What should we review?
        <% end %>
      </h1>
      <p
        :if={@cloned}
        id="review-clone-path"
        class="mt-1 flex items-center gap-1.5 text-xs text-base-content/50"
      >
        <.icon name="hero-arrow-down-tray-micro" class="size-3.5" />
        The clone in {String.replace_prefix(@dir, System.user_home!(), "~")}, fetched from its server
      </p>
      <p class="mt-2 text-base-content/60">
        Paste the repository's link, or a pull request's. Factory clones it and lists its
        branches, latest changes first; pick one, and the Scout plans what to check before
        the Reviewer reports.
      </p>

      <form
        id="review-repo-form"
        phx-submit="review_link"
        class={[
          "mt-5 flex items-center gap-2 rounded-xl border bg-base-100 py-1.5 pl-3 pr-1.5 transition-colors focus-within:border-primary/50",
          if(@clone_error, do: "border-error/50", else: "border-base-300")
        ]}
      >
        <.icon name="hero-link-mini" class="size-4 shrink-0 text-base-content/45" />
        <input
          name="link"
          autocomplete="off"
          spellcheck="false"
          disabled={@cloning != nil}
          placeholder="git@github.com:owner/repo.git, or a repository or pull request link"
          class="h-7 min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-base-content/35"
        />
        <button class="btn btn-primary btn-sm" disabled={@cloning != nil}>
          <span :if={@cloning} class="loading loading-spinner loading-xs"></span>
          {if @cloning, do: "Cloning…", else: "Clone & scan"}
        </button>
      </form>
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

      <div
        :if={@cloning}
        id="review-cloning-list"
        class="mt-4 flex items-center gap-2.5 rounded-xl border border-dashed border-base-300 px-3.5 py-4 text-[13px] text-base-content/60"
      >
        <span class="loading loading-spinner loading-xs text-primary"></span>
        Cloning {@cloning}. Its branches show here, latest changes first, when it's done.
      </div>

      <section
        :if={@dir_ok && !@cloning}
        id="review-scout"
        class="mt-4 rounded-xl border border-base-300"
      >
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
            class="grid size-6 shrink-0 place-items-center rounded-md text-base-content/45 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon
              name="hero-arrow-path-micro"
              class={["size-3.5", @scout == :loading && "animate-spin"]}
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
              class={["btn btn-sm shrink-0", if(pick[:latest], do: "btn-primary", else: "btn-ghost")]}
            >
              Review
            </button>
            <button
              :if={pick.kind == :pr}
              type="button"
              phx-click="review_pr"
              phx-value-url={pick.value}
              class="btn btn-ghost btn-sm shrink-0"
            >
              Review
            </button>
            <button
              :if={pick.kind in [:changes, :recent]}
              type="button"
              phx-click="review_local"
              phx-value-what={pick.kind}
              class="btn btn-ghost btn-sm shrink-0"
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

  # What the scout found worth reviewing: the branch that's checked out first (when it
  # isn't the base), then the open pull requests, then the other branches with work
  # beyond the base, latest first.
  defp review_picks({:ok, scout}) do
    worth = Enum.filter(scout.branches, &(&1.label != scout.base and (&1.ahead || 1) > 0))

    # The latest changes: the branch with the newest commit, suggested.
    latest =
      Enum.max_by(worth, &DateTime.to_unix(&1.at || ~U[1970-01-01 00:00:00Z]), fn -> nil end)

    branch = fn b ->
      pr = with [_, n] <- Regex.run(~r/^pr-(\d+)$/, b.label), do: n

      %{
        kind: :branch,
        value: b.name,
        label: if(is_binary(pr), do: "Pull request ##{pr}", else: b.label),
        current: b.current,
        ahead: b.ahead,
        latest: latest != nil and b.name == latest.name,
        detail: Enum.join(Enum.reject([b.subject, b.author], &(&1 in [nil, ""])), " · "),
        at: b.at
      }
    end

    # A pull request fetched as `pr-12` first, then the branch that's checked out.
    {prs_here, worth} = Enum.split_with(worth, &Regex.match?(~r/^pr-\d+$/, &1.label))
    {current, others} = Enum.split_with(worth, & &1.current)
    current = prs_here ++ current

    prs =
      for p <- scout.prs || [] do
        %{kind: :pr, value: p.url, label: "##{p.number} #{p.title}", detail: p.branch, at: p.at}
      end

    changes =
      if scout.dirty > 0,
        do: [
          %{
            kind: :changes,
            value: "",
            label: "Uncommitted changes",
            detail:
              "#{scout.dirty} #{if scout.dirty == 1, do: "file", else: "files"} changed on #{scout.current || "this branch"}",
            at: nil
          }
        ],
        else: []

    # On the base, or a branch with nothing beyond it: its latest commits are the work.
    recent =
      case scout.recent do
        [latest | _] = commits when current == [] ->
          [
            %{
              kind: :recent,
              value: "#{length(commits)}",
              label: "Latest commits on #{scout.current || "this branch"}",
              detail:
                "#{length(commits)} #{if length(commits) == 1, do: "commit", else: "commits"}, the latest “#{latest.subject}”",
              at: latest.at
            }
          ]

        _ ->
          []
      end

    # Branches first, the latest changes leading; the base's own commits last.
    Enum.map(current, branch) ++ changes ++ prs ++ Enum.map(others, branch) ++ recent
  end

  defp review_picks(_scout), do: []

  # Why pull requests aren't listed, when they aren't.
  defp scout_notes({:ok, %{prs_note: note}}) when is_binary(note), do: [note]

  defp scout_notes(_scout), do: []
end
