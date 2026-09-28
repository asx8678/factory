defmodule FactoryWeb.SourceParts do
  @moduledoc """
  The data sources window on the Workflows page: the workflow's sources, the kinds
  to add, and the form for one. Events are handled by `FactoryWeb.WorkflowsLive`.
  """
  use FactoryWeb, :html
  alias Factory.Sources

  # Class names written out in full so Tailwind's heroicons plugin sees them.
  @icons %{
    "azure_devops" => {"hero-cloud", "hero-cloud-mini"},
    "git" => {"hero-code-bracket-square", "hero-code-bracket-square-mini"},
    "folder" => {"hero-folder-open", "hero-folder-open-mini"},
    "instructions" => {"hero-document-text", "hero-document-text-mini"},
    "meta_index" => {"hero-map", "hero-map-mini"},
    "pageindex" => {"hero-rectangle-stack", "hero-rectangle-stack-mini"}
  }

  def icon(kind, :outline), do: @icons |> Map.fetch!(kind) |> elem(0)
  def icon(kind, :mini), do: @icons |> Map.fetch!(kind) |> elem(1)

  attr :workflow, :map, required: true
  attr :sources, :list, required: true
  attr :view, :atom, required: true, doc: ":list, :pick or :form"
  attr :kind, :string, default: nil
  attr :form, :any, default: nil
  attr :editing, :any, default: nil
  attr :upload, :any, required: true
  attr :browser, :any, default: nil, doc: "the folder browser, when open (see WorkflowsLive)"
  attr :agents, :list, default: [], doc: "the workflow's agents, to attach the source to"
  attr :attached, :any, default: MapSet.new(), doc: "ids of the agents it's attached to"

  def window(assigns) do
    ~H"""
    <div
      id="sources-window"
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 backdrop-blur-sm sm:items-center"
      phx-window-keydown="sources_close"
      phx-key="Escape"
    >
      <div
        class="drawer-in w-full max-w-2xl overflow-hidden rounded-2xl border border-base-content/10 bg-surface shadow-2xl"
        phx-click-away="sources_close"
        role="dialog"
        aria-modal="true"
        aria-labelledby="sources-title"
      >
        <header class="flex items-center gap-3 border-b border-base-content/10 px-5 py-4">
          <span class="grid size-9 place-items-center rounded-xl bg-primary/12 text-primary">
            <.icon name="hero-circle-stack" class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <h2 id="sources-title" class="font-semibold">Data sources</h2>
            <p class="truncate text-xs text-base-content/55">
              What {@workflow.name}'s agents work from, besides the project folder
            </p>
          </div>
          <button
            type="button"
            phx-click="sources_close"
            aria-label="Close"
            class="grid size-8 place-items-center rounded-lg text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </header>

        <.source_list :if={@view == :list} sources={@sources} />
        <.kind_picker :if={@view == :pick} back={@sources != []} />
        <.browser :if={@view == :form && @browser} browser={@browser} />
        <.source_form
          :if={@view == :form && !@browser}
          kind={@kind}
          form={@form}
          editing={@editing}
          upload={@upload}
          agents={@agents}
          attached={@attached}
        />
      </div>
    </div>
    """
  end

  attr :sources, :list, required: true

  defp source_list(assigns) do
    ~H"""
    <div class="max-h-[60vh] overflow-y-auto px-5 py-4">
      <ul id="sources" class="space-y-2">
        <li
          :for={s <- @sources}
          id={"source-#{s.id}"}
          class={[
            "flex items-start gap-3 rounded-xl border border-base-content/10 px-3.5 py-3",
            !s.enabled && "opacity-55"
          ]}
        >
          <span class="mt-0.5 grid size-8 shrink-0 place-items-center rounded-lg bg-base-content/[0.06]">
            <.icon name={icon(s.kind, :mini)} class="size-4 text-base-content/70" />
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2">
              <span class="font-medium">{s.name}</span>
              <span class="text-xs text-base-content/50">{Sources.label(s.kind)}</span>
            </div>
            <p class="truncate font-mono text-[11px] text-base-content/55" title={detail(s)}>
              {detail(s)}
            </p>
            <.status source={s} />
            <p class="mt-1 text-xs text-base-content/50">
              {case length(Sources.agent_ids(s)) do
                0 -> "Not attached to any agent yet"
                1 -> "Attached to 1 agent"
                n -> "Attached to #{n} agents"
              end}
            </p>
          </div>
          <div class="flex shrink-0 items-center gap-0.5">
            <button
              :if={Sources.repo?(s)}
              type="button"
              phx-click="source_sync"
              phx-value-id={s.id}
              disabled={s.status == "syncing"}
              title="Pull the latest"
              aria-label={"Sync #{s.name}"}
              class="grid size-8 place-items-center rounded-lg text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content disabled:opacity-40"
            >
              <.icon
                name="hero-arrow-path-mini"
                class={["size-4", s.status == "syncing" && "animate-spin"]}
              />
            </button>
            <button
              type="button"
              phx-click="source_edit"
              phx-value-id={s.id}
              aria-label={"Edit #{s.name}"}
              class="grid size-8 place-items-center rounded-lg text-base-content/55 hover:bg-base-content/[0.06] hover:text-base-content"
            >
              <.icon name="hero-pencil-square-mini" class="size-4" />
            </button>
            <input
              type="checkbox"
              class="toggle toggle-xs toggle-success mx-1.5"
              checked={s.enabled}
              phx-click="source_toggle"
              phx-value-id={s.id}
              aria-label={if s.enabled, do: "Turn off #{s.name}", else: "Turn on #{s.name}"}
              title={if s.enabled, do: "Agents use it", else: "Agents don't use it"}
            />
            <button
              type="button"
              phx-click="source_delete"
              phx-value-id={s.id}
              data-confirm={"Remove “#{s.name}” from this workflow?"}
              aria-label={"Remove #{s.name}"}
              class="grid size-8 place-items-center rounded-lg text-base-content/45 hover:bg-error/10 hover:text-error"
            >
              <.icon name="hero-trash-mini" class="size-4" />
            </button>
          </div>
        </li>
      </ul>
    </div>
    <footer class="flex items-center justify-between gap-3 border-t border-base-content/10 px-5 py-3">
      <p class="text-xs text-base-content/50">
        Agents get these with their next message. Kiro reads them when it plans a run.
      </p>
      <button
        id="add-source"
        type="button"
        phx-click="source_view"
        phx-value-view="pick"
        class="btn btn-primary btn-sm"
      >
        <.icon name="hero-plus-mini" class="size-4" /> Add data source
      </button>
    </footer>
    """
  end

  attr :source, :map, required: true

  defp status(assigns) do
    ~H"""
    <p :if={@source.status == "syncing"} class="mt-1 flex items-center gap-1.5 text-xs text-info">
      <span class="loading loading-spinner loading-xs"></span> Syncing…
    </p>
    <p :if={@source.status == "error"} class="mt-1 text-xs text-error">{@source.error}</p>
    <p
      :if={@source.status == "ready" and @source.synced_at}
      class="mt-1 flex items-center gap-1.5 text-xs text-base-content/50"
    >
      <span class="size-1.5 rounded-full bg-success"></span> Synced {Layouts.ago(@source.synced_at)}
    </p>
    """
  end

  attr :back, :boolean, required: true

  defp kind_picker(assigns) do
    ~H"""
    <div class="px-5 py-4">
      <p class="mb-3 text-sm text-base-content/65">What should the agents work from?</p>
      <div id="source-kinds" class="grid gap-2 sm:grid-cols-2">
        <button
          :for={{kind, label, text} <- Sources.kinds()}
          id={"pick-source-#{kind}"}
          type="button"
          phx-click="source_pick"
          phx-value-kind={kind}
          class="group flex items-start gap-3 rounded-xl border border-base-content/10 p-3.5 text-left transition-colors hover:border-success/40 hover:bg-success/10"
        >
          <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/12 text-primary">
            <.icon name={icon(kind, :outline)} class="size-5" />
          </span>
          <span>
            <span class="block font-medium">{label}</span>
            <span class="block text-xs leading-relaxed text-base-content/55">{text}</span>
          </span>
        </button>
      </div>
      <button
        :if={@back}
        type="button"
        phx-click="source_view"
        phx-value-view="list"
        class="mt-4 text-sm text-base-content/55 hover:text-base-content"
      >
        ← Back to the sources
      </button>
    </div>
    """
  end

  attr :kind, :string, required: true
  attr :form, :any, required: true
  attr :editing, :any, default: nil
  attr :upload, :any, required: true
  attr :agents, :list, default: []
  attr :attached, :any, default: MapSet.new()

  defp source_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="source-form"
      phx-change="source_validate"
      phx-submit="source_save"
      class="px-5 py-4"
    >
      <div class="mb-4 flex items-center gap-3">
        <span class="grid size-10 place-items-center rounded-xl bg-primary/12 text-primary">
          <.icon name={icon(@kind, :outline)} class="size-5" />
        </span>
        <div>
          <h3 class="font-medium">{Sources.label(@kind)}</h3>
          <p class="text-xs text-base-content/55">
            {@kind
            |> then(fn k -> Enum.find_value(Sources.kinds(), fn {kk, _, t} -> kk == k && t end) end)}
          </p>
        </div>
      </div>

      <div class="space-y-3">
        <.field form={@form} name="name" label="Name" placeholder={name_hint(@kind)} />

        <%= case @kind do %>
          <% "azure_devops" -> %>
            <div class="grid gap-3 sm:grid-cols-3">
              <.field form={@form} name="org" config label="Organization" placeholder="contoso" />
              <.field form={@form} name="project" config label="Project" placeholder="Shop" />
              <.field form={@form} name="repo" config label="Repository" placeholder="backend" />
            </div>
            <div class="grid gap-3 sm:grid-cols-2">
              <.field
                form={@form}
                name="branch"
                config
                label="Branch"
                placeholder="Default branch"
                optional
              />
              <.field
                form={@form}
                name="pat_env"
                config
                label="Token environment variable"
                placeholder="AZURE_DEVOPS_PAT"
                optional
                hint="The name of a variable holding a personal access token (Code: Read). The token itself is never saved. Empty: git's own sign-in."
              />
            </div>
          <% "git" -> %>
            <.field
              form={@form}
              name="url"
              config
              label="Repository URL"
              placeholder="https://github.com/acme/api.git"
              mono
              hint="Private repos use git's own sign-in (credential manager or SSH key)."
            />
            <.field
              form={@form}
              name="branch"
              config
              label="Branch"
              placeholder="Default branch"
              optional
            />
          <% "folder" -> %>
            <.field
              form={@form}
              name="path"
              config
              label="Folder"
              placeholder="/Users/you/projects/docs"
              mono
              browse="dir"
              hint="Agents may read anything in it; they don't change it."
            />
          <% "pageindex" -> %>
            <.field
              form={@form}
              name="path"
              config
              label="PageIndex tree"
              placeholder="/Users/you/docs/manual_structure.json"
              mono
              browse="json"
              hint="The JSON PageIndex writes, e.g. python3 run_pageindex.py --pdf_path manual.pdf (github.com/VectifyAI/PageIndex). With --if-add-node-text yes, agents can open each section's text."
            />
            <.field
              form={@form}
              name="document"
              config
              label="Document"
              placeholder="/Users/you/docs/manual.pdf"
              mono
              optional
              browse="any"
              hint="The document the tree indexes, for reading pages when the tree has no text."
            />
          <% kind when kind in ["instructions", "meta_index"] -> %>
            <.field
              form={@form}
              name="path"
              config
              label={if kind == "meta_index", do: "Index file", else: "File"}
              placeholder={
                if kind == "meta_index",
                  do: "/Users/you/specs/00-index.md",
                  else: "/Users/you/AGENTS.md"
              }
              mono
              optional
              browse="file"
              hint="Read fresh every time, so edits to the file count. Or write or upload the text below."
            />
            <div>
              <div class="mb-1 flex items-center justify-between">
                <span class="text-sm font-medium">
                  Text <span class="font-normal text-base-content/45">(if there's no file)</span>
                </span>
                <label
                  for={@upload.ref}
                  class="inline-flex cursor-pointer items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
                >
                  <.icon name="hero-arrow-up-tray-mini" class="size-3.5" /> Upload .md or .txt
                  <.live_file_input upload={@upload} class="sr-only" />
                </label>
              </div>
              <textarea
                name="source[content]"
                rows="6"
                phx-debounce="400"
                placeholder={
                  if kind == "meta_index",
                    do:
                      "- 00-overview.md: what the system is\n- 01-architecture.md: modules and data flow\n- tasks/: one file per task",
                    else: "- Use Ecto changesets for all input\n- Every change comes with a test"
                }
                class="block w-full resize-y rounded-lg border border-base-300 bg-base-100 px-3 py-2 font-mono text-xs leading-relaxed outline-none placeholder:text-base-content/35 focus:border-base-content/30"
              >{@form[:content].value}</textarea>
              <.errors form={@form} name="content" />
            </div>
            <.field
              :if={kind == "meta_index"}
              form={@form}
              name="root"
              config
              label="Docs folder"
              placeholder="Where the index's paths point; empty: the index file's folder"
              mono
              optional
              browse="dir"
            />
        <% end %>
      </div>

      <p
        :if={!@editing}
        id="source-unattached-note"
        class="mt-4 flex items-start gap-2 rounded-lg border border-success/30 bg-success/[0.06] px-3 py-2 text-xs leading-relaxed text-base-content/70"
      >
        <.icon name="hero-arrow-long-right-mini" class="mt-px size-4 shrink-0 text-success" />
        It starts attached to no agent. Then draw an arrow from its card to each agent that should
        get it in its prompt.
      </p>

      <fieldset :if={@editing} id="source-agents" class="mt-4">
        <legend class="mb-1.5 text-sm font-medium">Attached to</legend>
        <input type="hidden" name="source[agents][]" value="" />
        <p :if={@agents == []} class="text-xs text-base-content/50">
          This workflow has no agents yet. Add some, then attach the source to them.
        </p>
        <div :if={@agents != []} class="flex flex-wrap gap-1.5">
          <label
            :for={a <- @agents}
            class={[
              "inline-flex cursor-pointer items-center gap-1.5 rounded-lg border px-2.5 py-1 text-sm transition-all",
              if(MapSet.member?(@attached, a.id),
                do:
                  "border-success bg-success/25 font-semibold text-base-content ring-2 ring-success/30 shadow-[0_0_14px_-4px_var(--color-success)]",
                else:
                  "border-base-300 text-base-content/60 hover:border-success/40 hover:text-base-content"
              )
            ]}
          >
            <input
              type="checkbox"
              name="source[agents][]"
              value={a.id}
              checked={MapSet.member?(@attached, a.id)}
              class="checkbox checkbox-xs checkbox-success"
            />
            {a.name}
          </label>
        </div>
        <p class="mt-1.5 text-xs text-base-content/50">
          Only these agents get it in their prompt. You can also draw an arrow from its card to an agent.
        </p>
      </fieldset>

      <div class="mt-5 flex items-center gap-2">
        <button type="submit" class="btn btn-primary btn-sm">
          {cond do
            @editing -> "Save"
            @kind in ["azure_devops", "git"] -> "Add and sync"
            true -> "Add source"
          end}
        </button>
        <button
          type="button"
          phx-click="source_back"
          class="btn btn-ghost btn-sm"
        >
          Back
        </button>
      </div>
    </.form>
    """
  end

  attr :browser, :map, required: true

  @doc """
  Picking a folder or file on this machine: `browser` is `%{mode:, hidden:, listing:, error:}`
  with `listing` from `Factory.FileBrowser.list/2`. The page handles `browse_go`
  (`path`), `browse_hidden`, `browse_cancel` and `browse_pick` (`path`).
  """
  def browser(assigns) do
    ~H"""
    <div id="file-browser" class="flex max-h-[70vh] flex-col">
      <div class="border-b border-base-content/10 px-5 py-3">
        <div class="flex items-center justify-between gap-3">
          <h3 class="font-medium">
            {case @browser.mode do
              "dir" -> "Choose a folder"
              "json" -> "Choose a PageIndex tree (.json)"
              _ -> "Choose a file"
            end}
          </h3>
          <label class="flex cursor-pointer items-center gap-1.5 text-xs text-base-content/55">
            <input
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={@browser.hidden}
              phx-click="browse_hidden"
            /> Show hidden
          </label>
        </div>
        <div class="mt-2 flex flex-wrap gap-1">
          <button
            :for={{label, path} <- Factory.FileBrowser.places()}
            type="button"
            phx-click="browse_go"
            phx-value-path={path}
            class="rounded-md bg-base-content/[0.06] px-2 py-0.5 text-xs hover:bg-base-content/10"
          >
            {label}
          </button>
        </div>
        <nav
          :if={@browser.listing}
          class="mt-2 flex flex-wrap items-center gap-0.5 font-mono text-xs"
          aria-label="Path"
        >
          <%= for {{part, path}, i} <- Enum.with_index(@browser.listing.crumbs) do %>
            <span :if={i > 1} class="text-base-content/30">/</span>
            <button
              type="button"
              phx-click="browse_go"
              phx-value-path={path}
              class="rounded px-1 py-0.5 hover:bg-base-content/[0.06]"
            >
              {part}
            </button>
          <% end %>
        </nav>
      </div>

      <p :if={@browser.error} class="px-5 py-3 text-sm text-error">{@browser.error}</p>

      <ul
        :if={@browser.listing}
        id="browser-entries"
        class="min-h-40 flex-1 overflow-y-auto px-2 py-2"
      >
        <li :if={@browser.listing.parent}>
          <button
            type="button"
            phx-click="browse_go"
            phx-value-path={@browser.listing.parent}
            class="flex w-full items-center gap-2.5 rounded-lg px-3 py-1.5 text-left text-sm text-base-content/60 hover:bg-base-content/[0.06]"
          >
            <.icon name="hero-arrow-uturn-up-mini" class="size-4" /> Up
          </button>
        </li>
        <li :for={e <- @browser.listing.entries}>
          <button
            type="button"
            phx-click={if e.dir?, do: "browse_go", else: "browse_pick"}
            phx-value-path={e.path}
            class="flex w-full items-center gap-2.5 rounded-lg px-3 py-1.5 text-left text-sm hover:bg-base-content/[0.06]"
          >
            <.icon :if={e.dir?} name="hero-folder-mini" class="size-4 shrink-0 text-warning/80" />
            <.icon
              :if={!e.dir?}
              name="hero-document-text-mini"
              class="size-4 shrink-0 text-base-content/55"
            />
            <span class="truncate">{e.name}</span>
            <.icon
              :if={e.dir?}
              name="hero-chevron-right-mini"
              class="ml-auto size-4 text-base-content/30"
            />
            <span :if={!e.dir?} class="ml-auto text-xs text-success">Choose</span>
          </button>
        </li>
        <li
          :if={@browser.listing.entries == []}
          class="px-3 py-6 text-center text-sm text-base-content/50"
        >
          {if @browser.mode == "dir",
            do: "No folders in here.",
            else: "No folders or text files in here."}
        </li>
        <li :if={@browser.listing.more > 0} class="px-3 py-2 text-xs text-base-content/45">
          …and {@browser.listing.more} more. Open a folder inside to narrow it down.
        </li>
      </ul>

      <footer class="flex items-center gap-2 border-t border-base-content/10 px-5 py-3">
        <button type="button" phx-click="browse_cancel" class="btn btn-ghost btn-sm">
          Cancel
        </button>
        <button
          :if={@browser.mode == "dir" && @browser.listing}
          id="browse-choose"
          type="button"
          phx-click="browse_pick"
          phx-value-path={@browser.listing.dir}
          class="btn btn-sm ml-auto border-success/50 bg-success/15 hover:bg-success/25"
        >
          <.icon name="hero-check-mini" class="size-4 text-success" /> Use this folder
        </button>
        <span :if={@browser.mode != "dir"} class="ml-auto text-xs text-base-content/55">
          {case @browser.mode do
            "json" -> "Folders and .json files"
            "any" -> "Folders and all files"
            _ -> "Folders and text files (.md, .txt, .json, .yaml…)"
          end}
        </span>
      </footer>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :hint, :string, default: nil
  attr :config, :boolean, default: false
  attr :optional, :boolean, default: false
  attr :mono, :boolean, default: false
  attr :browse, :string, default: nil, doc: "\"dir\" or \"file\": offer a Browse button"

  # One text input, under source[name] or source[config][name].
  defp field(assigns) do
    value =
      if assigns.config,
        do: (assigns.form[:config].value || %{})[assigns.name],
        else: assigns.form[String.to_existing_atom(assigns.name)].value

    assigns =
      assign(assigns,
        value: value,
        input_name:
          if(assigns.config,
            do: "source[config][#{assigns.name}]",
            else: "source[#{assigns.name}]"
          )
      )

    ~H"""
    <label class="block">
      <span class="mb-1 block text-sm font-medium">
        {@label} <span :if={@optional} class="font-normal text-base-content/45">(optional)</span>
      </span>
      <span class="flex gap-2">
        <input
          name={@input_name}
          value={@value}
          placeholder={@placeholder}
          autocomplete="off"
          phx-debounce="400"
          class={[
            "h-9 min-w-0 flex-1 rounded-lg border border-base-300 bg-base-100 px-3 text-sm outline-none placeholder:text-base-content/35 focus:border-base-content/30",
            @mono && "font-mono text-xs"
          ]}
        />
        <button
          :if={@browse}
          id={"browse-#{@name}"}
          type="button"
          phx-click="browse_open"
          phx-value-field={@name}
          phx-value-mode={@browse}
          class="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-lg border border-success/40 bg-success/10 px-3 text-sm font-medium transition-colors hover:border-success/70 hover:bg-success/20"
        >
          <.icon name="hero-folder-open-mini" class="size-4 text-success" /> Browse…
        </button>
      </span>
      <span :if={@hint} class="mt-1 block text-xs text-base-content/50">{@hint}</span>
      <.errors form={@form} name={@name} config={@config} />
    </label>
    """
  end

  attr :form, :any, required: true
  attr :name, :string, required: true
  attr :config, :boolean, default: false

  # Errors on a config key are stored on :config with the key in `field`.
  defp errors(assigns) do
    messages =
      if assigns.form.source.action do
        for {:config, {msg, opts}} <- assigns.form.source.errors,
            opts[:field] == assigns.name,
            do: msg
      else
        []
      end

    messages =
      messages ++
        if !assigns.config and assigns.form.source.action,
          do:
            for(
              {field, {msg, _}} <- assigns.form.source.errors,
              to_string(field) == assigns.name,
              do: msg
            ),
          else: []

    assigns = assign(assigns, messages: messages)

    ~H"""
    <span :for={m <- @messages} class="mt-1 block text-xs text-error">{m}</span>
    """
  end

  defp name_hint("azure_devops"), do: "e.g. Backend repo"
  defp name_hint("git"), do: "e.g. API service"
  defp name_hint("folder"), do: "e.g. Design docs"
  defp name_hint("instructions"), do: "e.g. Coding rules"
  defp name_hint("meta_index"), do: "e.g. Spec index"
  defp name_hint("pageindex"), do: "e.g. Product manual"

  # One line saying where a source is.
  def detail(%{kind: "azure_devops", config: c}),
    do: "dev.azure.com/#{c["org"]}/#{c["project"]}/_git/#{c["repo"]}#{branch(c)}"

  def detail(%{kind: "git", config: c}), do: "#{c["url"]}#{branch(c)}"
  def detail(%{kind: "folder", config: c}), do: c["path"]

  def detail(%{config: %{"path" => path}}) when is_binary(path) and path != "", do: path

  def detail(%{content: content}) do
    lines = content |> String.split(~r/\R/u, trim: true) |> length()
    "Written here · #{lines} #{if lines == 1, do: "line", else: "lines"}"
  end

  defp branch(%{"branch" => b}) when is_binary(b) and b != "", do: " @ #{b}"
  defp branch(_), do: ""
end
