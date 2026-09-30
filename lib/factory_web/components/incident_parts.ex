defmodule FactoryWeb.IncidentParts do
  @moduledoc """
  The chat's greeting for troubleshooting (`FactoryWeb.ChatGreeting.greeting/1`, with the
  "incident" workflow): what's going wrong goes in the message box below (an error, a
  stack trace, logs), and the two modes to work in are chosen here. Paste the error
  works from what's pasted; with the code, the agents also search a repository, picked
  on this computer (`browse`, then `browse_pick`) or cloned from its link
  (`review_link`). `without_code` sets the repository aside again.
  """
  use FactoryWeb, :html

  @doc "Takes the assigns of `FactoryWeb.ChatGreeting.greeting/1`."
  def greeting(assigns) do
    dir = assigns.dir

    assigns =
      assign(assigns,
        root: Factory.Repos.root() |> String.replace_prefix(System.user_home!(), "~"),
        repo: assigns.dir_ok && (Factory.Repos.label(dir) || Path.basename(dir)),
        path: assigns.dir_ok && String.replace_prefix(dir, System.user_home!(), "~")
      )

    ~H"""
    <div id="incident-start" class="step-in relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium text-base-content/45">
        Troubleshoot · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1 text-2xl font-semibold leading-tight tracking-tight">
        What's going wrong?
      </h1>
      <p class="mt-2 text-base-content/60">
        Paste the error message, a stack trace or logs below, and say where it happens if you
        know. The team looks the error up on the web, traces it to the cause, checks the
        facts, and hands you a verified fix.
      </p>

      <div class="mt-5 grid gap-3 sm:grid-cols-2">
        <button
          id="incident-paste"
          type="button"
          phx-click="without_code"
          aria-pressed={to_string(!@dir_ok)}
          class={[
            "flex flex-col items-start rounded-xl border bg-base-100 p-4 text-left transition duration-150",
            if(@dir_ok,
              do:
                "border-base-300 hover:-translate-y-px hover:border-base-content/25 hover:shadow-sm",
              else: "border-primary/40 bg-primary/[0.04] ring-1 ring-primary/20"
            )
          ]}
        >
          <span class="flex w-full items-center gap-2">
            <span class="grid size-8 place-items-center rounded-lg bg-base-200 text-base-content/70">
              <.icon name="hero-clipboard-document" class="size-[18px]" />
            </span>
            <span class="font-semibold">Paste the error</span>
            <.icon :if={!@dir_ok} name="hero-check-circle-mini" class="ml-auto size-5 text-primary" />
          </span>
          <span class="mt-2 text-sm text-base-content/60">
            An error message, a stack trace or logs: whatever you have. Nothing to set up.
          </span>
        </button>

        <section
          id="incident-with-code"
          class={[
            "flex flex-col rounded-xl border bg-base-100 p-4 transition duration-150",
            cond do
              @dir_ok -> "border-primary/40 bg-primary/[0.04] ring-1 ring-primary/20"
              @folder_error || (@clone_error && !@cloning) -> "border-error/50"
              true -> "border-base-300 hover:border-base-content/25"
            end
          ]}
        >
          <span class="flex items-center gap-2">
            <span class="grid size-8 place-items-center rounded-lg bg-base-200 text-base-content/70">
              <.icon name="hero-code-bracket" class="size-[18px]" />
            </span>
            <span class="font-semibold">With the code</span>
            <.icon :if={@dir_ok} name="hero-check-circle-mini" class="ml-auto size-5 text-primary" />
          </span>

          <%= if @dir_ok do %>
            <p id="incident-repo" class="mt-2 min-w-0 text-sm">
              <span class="font-medium">{@repo}</span>
              <span class="block truncate font-mono text-xs text-base-content/50">{@path}</span>
            </p>
            <p class="mt-1 text-xs text-base-content/55">
              The agents search its code and history, read-only.
            </p>
            <div class="mt-auto pt-3">
              <button
                id="incident-change-repo"
                type="button"
                phx-click="browse"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-arrows-right-left-micro" class="size-4" /> Another folder…
              </button>
            </div>
          <% else %>
            <p class="mt-2 text-sm text-base-content/60">
              Also search a repository and its history for the cause.
            </p>
            <p :if={@folder_error} id="incident-folder-error" class="mt-2 text-xs text-error">
              {@folder_error}
            </p>
            <div class="mt-auto space-y-2 pt-3">
              <button
                id="incident-choose-folder"
                type="button"
                phx-click="browse"
                disabled={@cloning != nil}
                class="btn btn-sm"
              >
                <.icon name="hero-folder-open-mini" class="size-4" /> Choose folder…
              </button>
              <.form
                for={@link_form}
                id="incident-repo-form"
                phx-submit="review_link"
                class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 py-1 pl-2.5 pr-1 transition-colors focus-within:border-primary/50"
              >
                <.icon name="hero-link-mini" class="size-4 shrink-0 text-base-content/45" />
                <.input
                  field={@link_form[:link]}
                  id="incident-link"
                  autocomplete="off"
                  spellcheck="false"
                  disabled={@cloning != nil}
                  aria-label="Repository link to clone"
                  placeholder="or clone: git@github.com:owner/repo.git"
                  class="h-7 w-full bg-transparent text-sm outline-none placeholder:text-base-content/35"
                  wrapper_class="min-w-0 flex-1"
                />
                <button
                  id="incident-clone"
                  class="btn btn-sm phx-submit-loading:opacity-60"
                  disabled={@cloning != nil}
                >
                  <span :if={@cloning} class="loading loading-spinner loading-xs"></span>
                  {if @cloning, do: "Cloning…", else: "Clone"}
                </button>
              </.form>
              <p :if={@cloning} id="incident-cloning" class="px-1 text-xs text-base-content/55">
                Cloning {@cloning} into {@root}…
              </p>
              <p
                :if={@clone_error && !@cloning}
                id="incident-clone-error"
                class="px-1 text-xs text-error"
              >
                {@clone_error}
              </p>
            </div>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
