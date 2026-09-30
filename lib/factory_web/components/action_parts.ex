defmodule FactoryWeb.ActionParts do
  @moduledoc """
  The side panel for an action card on the Workflows page: its settings, what it
  would do (dry run), and running it now. Events are handled by `FactoryWeb.WorkflowsLive`.
  """
  use FactoryWeb, :html
  alias Factory.Actions

  attr :action, :map, required: true, doc: "the action card (a Factory.Agents.Agent)"

  attr :result, :any,
    default: nil,
    doc: "{:plan, lines} | {:ok, text} | {:error, text} | :running"

  attr :new, :boolean, default: false, doc: "just added from the palette, not yet added for good"
  attr :running, :boolean, default: false
  attr :changed, :boolean, default: false, doc: "has settings that aren't saved yet"

  def panel(assigns) do
    type = Actions.get(assigns.action.action["type"])
    config = assigns.action.action["config"] || %{}

    assigns =
      assign(assigns,
        type: type,
        config: config,
        form: to_form(%{"name" => assigns.action.name, "config" => config}, as: :action),
        missing: Actions.missing(assigns.action),
        result: if(assigns.running, do: :running, else: assigns.result)
      )

    ~H"""
    <aside
      id={"action-panel-#{@action.id}"}
      class="drawer-in absolute inset-x-3 bottom-3 flex max-h-[70%] flex-col overflow-hidden rounded-xl border border-warning/30 bg-surface shadow-xl sm:inset-x-auto sm:right-3 sm:top-3 sm:max-h-none sm:w-[340px]"
    >
      <div class="flex items-center gap-2 border-b border-base-content/10 px-4 py-3">
        <span class="grid size-8 shrink-0 place-items-center rounded-lg bg-warning/15 text-warning">
          <.icon name="hero-bolt-mini" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-[11px] text-warning">Action</p>
          <p class="truncate text-sm text-base-content/60">{@type && @type.label}</p>
        </div>
        <button
          :if={!@new}
          type="button"
          phx-click="delete_agent"
          data-confirm={"Delete the action “#{@action.name}” and its arrows?"}
          aria-label="Delete action"
          title="Delete action"
          class="grid size-7 place-items-center rounded-md text-base-content/45 hover:bg-error/10 hover:text-error"
        >
          <.icon name="hero-trash-mini" class="size-4" />
        </button>
        <button
          type="button"
          phx-click="action_cancel"
          aria-label="Close"
          class="grid size-7 place-items-center rounded-md text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <.form
        :if={@type}
        for={@form}
        id="action-form"
        phx-change="action_change"
        phx-submit="action_save"
        class="min-h-0 flex-1 space-y-3 overflow-y-auto px-4 py-3"
      >
        <p class="text-xs leading-relaxed text-base-content/60">{@type.blurb}</p>
        <div class="block">
          <span class="mb-1 block text-xs font-medium text-base-content/70">Name</span>
          <.input
            field={@form[:name]}
            id="action-name"
            phx-debounce="400"
            class="h-8 w-full rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none focus:border-base-content/30"
            wrapper_class="block"
          />
        </div>

        <div :for={{key, label, input, hint, required} <- @type.fields} class="block">
          <span class="mb-1 flex items-baseline justify-between text-xs font-medium text-base-content/70">
            {label}
            <span :if={!required} class="font-normal text-base-content/40">optional</span>
          </span>
          <.input
            :if={input in [:text, :env]}
            name={"action[config][#{key}]"}
            id={"action-config-#{key}"}
            value={@config[key]}
            placeholder={hint}
            phx-debounce="400"
            autocomplete="off"
            class={[
              "h-8 w-full rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none placeholder:text-base-content/35 focus:border-base-content/30",
              input == :env && "font-mono text-xs"
            ]}
            wrapper_class="block"
          />
          <.input
            :if={input == :textarea}
            type="textarea"
            name={"action[config][#{key}]"}
            id={"action-config-#{key}"}
            value={@config[key]}
            rows="3"
            placeholder={hint}
            phx-debounce="400"
            class="block w-full resize-y rounded-md border border-base-300 bg-base-100 px-2.5 py-1.5 text-sm outline-none placeholder:text-base-content/35 focus:border-base-content/30"
            wrapper_class="block"
          />
          <.input
            :if={match?({:select, _}, input)}
            type="select"
            name={"action[config][#{key}]"}
            id={"action-config-#{key}"}
            value={@config[key] || hint}
            options={elem(input, 1)}
            class="select select-sm w-full"
            wrapper_class="block"
          />
          <span :if={input == :env} class="mt-0.5 block text-[11px] text-base-content/45">
            The name of an environment variable; its value is read when the action runs, never saved.
          </span>
        </div>

        <p class="rounded-md bg-base-content/[0.04] px-2.5 py-2 text-[11px] leading-relaxed text-base-content/55">
          In any setting: <code class="code-inline">{"{{run}}"}</code>
          the run's title, <code class="code-inline">{"{{summary}}"}</code>
          what was done, <code class="code-inline">{"{{branch}}"}</code>
          the run's branch, <code class="code-inline">{"{{run_id}}"}</code>.
        </p>
      </.form>

      <div class="space-y-2 border-t border-base-content/10 px-4 py-3">
        <p :if={@missing != []} class="text-xs text-warning">
          Needs setup: {Enum.join(@missing, ", ")}
        </p>

        <div
          :if={@result}
          id="action-result"
          class={[
            "max-h-48 overflow-y-auto whitespace-pre-wrap rounded-md px-2.5 py-2 text-xs leading-relaxed",
            case @result do
              {:error, _} -> "bg-error/10 text-error"
              {:ok, _} -> "bg-success/10 text-base-content/80"
              _ -> "bg-base-content/[0.05] text-base-content/75"
            end
          ]}
        >
          <%= case @result do %>
            <% :running -> %>
              <span class="flex items-center gap-2">
                <span class="loading loading-spinner loading-xs"></span> Running…
              </span>
            <% {:plan, lines} -> %>
              <p class="mb-1 font-medium">It would, with sample values:</p>
              <ol class="list-decimal space-y-0.5 pl-4">
                <li :for={l <- lines}>{l}</li>
              </ol>
            <% {:ok, text} -> %>
              <p class="mb-1 font-medium text-success">Done</p>
              {text}
            <% {:error, text} -> %>
              {text}
          <% end %>
        </div>

        <div class="flex items-center gap-2">
          <button
            id="action-plan"
            type="button"
            phx-click="action_plan"
            disabled={@running}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-eye-mini" class="size-4" /> Dry run
          </button>
          <button
            id="action-run"
            type="button"
            phx-click="action_run"
            disabled={@missing != [] or @running}
            data-confirm={"Run “#{@action.name}” now? It really does it (#{@type && String.downcase(@type.label)}), with sample values for {{run}} and the like."}
            class="btn btn-sm border-warning/50 bg-warning/15 hover:bg-warning/25"
          >
            <.icon name="hero-play-mini" class="size-4 text-warning" /> Run now
          </button>
        </div>

        <div class="flex items-center gap-2 border-t border-base-content/10 pt-3">
          <button
            id="action-cancel"
            type="button"
            phx-click="action_cancel"
            class="btn btn-ghost btn-sm"
          >
            Cancel
          </button>
          <button
            id="action-save"
            type="submit"
            form="action-form"
            disabled={!@new and !@changed}
            class="btn btn-primary btn-sm ml-auto"
          >
            <.icon :if={@new} name="hero-plus-mini" class="size-4" />
            {if @new, do: "Add", else: "Save"}
          </button>
        </div>
      </div>
    </aside>
    """
  end
end
