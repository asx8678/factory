defmodule FactoryWeb.ChatComposer do
  @moduledoc """
  The chat's message box (`FactoryWeb.ChatLive`): attachments, the message, then a
  toolbar with attach, who it goes to, how full that agent's context is, and send.
  Events from it go to the chat LiveView.
  """
  use FactoryWeb, :html
  import FactoryWeb.ChatParts

  attr :agent, :any, required: true

  # How full the addressed agent's Kiro context is, and a button to compact it. Shown
  # while its session runs, or right after a compaction until the next reply.
  defp context_chip(%{agent: %{usage: usage}} = assigns) when is_map(usage) do
    pct = usage["context_pct"]
    assigns = assign(assigns, pct: pct, usage: usage, level: FactoryWeb.Usage.level(pct))

    ~H"""
    <%!-- Only once it matters: the context filling up, or just compacted. --%>
    <div
      :if={@level in ["mid", "high"] or @usage["compacted_from"]}
      id="context-chip"
      class={[
        "ctx-chip flex h-7 items-center overflow-hidden rounded-full border text-xs tabular-nums",
        @level && "is-#{@level}"
      ]}
    >
      <span
        class="flex items-center gap-1.5 pl-2.5 pr-2"
        title={
          "#{@agent.name}'s context: #{FactoryWeb.Usage.context(@usage)}. " <>
            "It's compacted automatically before the next message at #{FactoryWeb.Usage.compact_at()}%."
        }
      >
        <svg :if={@pct} viewBox="0 0 16 16" class="ctx-ring size-4 -rotate-90" aria-hidden="true">
          <circle cx="8" cy="8" r="6" pathLength="100" class="ctx-track" />
          <circle
            cx="8"
            cy="8"
            r="6"
            pathLength="100"
            class="ctx-fill"
            stroke-dasharray={"#{min(@pct, 100)} 100"}
          />
        </svg>
        <.icon :if={!@pct} name="hero-arrows-pointing-in-mini" class="size-4 opacity-60" />
        <span :if={@pct}>{FactoryWeb.Usage.pct(@pct)}</span>
        <span :if={!@pct} class="text-base-content/55">Compacted</span>
      </span>
      <button
        :if={@pct}
        id="compact-chip"
        type="button"
        phx-click="compact"
        phx-value-id={@agent.id}
        class="flex h-full items-center gap-1 border-l border-current/15 px-2.5 font-medium transition-colors hover:bg-base-content/[0.07]"
        title="Summarize the conversation by fixed rules (the latest messages stay word for word) and continue in a fresh Kiro session"
      >
        <.icon name="hero-arrows-pointing-in-mini" class="size-3.5" /> Compact
      </button>
    </div>
    """
  end

  defp context_chip(assigns), do: ~H""

  attr :form, :any,
    required: true,
    doc: "the message's form: to_form(%{\"body\" => draft}, as: :chat)"

  attr :uploads, :map, required: true
  attr :draft, :string, required: true
  attr :commands, :list, required: true
  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :run, :any, required: true

  attr :planner, :any,
    default: nil,
    doc: "the agent that plans the run (Factory.Chat.planner_for/1)"

  attr :job, :string, default: nil, doc: "the workflow's kind (Factory.Workflows.kind/1)"
  attr :glow, :boolean, default: false

  # Rounded card: attachments, the message, then a toolbar with attach, recipient and send.
  def composer(assigns) do
    matches =
      if String.match?(assigns.draft, ~r{^/\S*$}),
        do:
          Enum.filter(assigns.commands, fn {c, _} ->
            String.starts_with?(c, String.downcase(assigns.draft))
          end),
        else: []

    ready = String.trim(assigns.draft) != "" or assigns.uploads.spec.entries != []
    assigns = assign(assigns, matches: matches, ready: ready)

    ~H"""
    <.form
      for={@form}
      id="chat-form"
      phx-change="validate"
      phx-submit="send"
      class="pointer-events-auto relative mx-auto w-full max-w-3xl"
    >
      <ul
        :if={@matches != []}
        class="absolute inset-x-0 bottom-full mb-2 overflow-hidden rounded-xl border border-base-content/10 bg-surface p-1 text-sm shadow-xl"
      >
        <li :for={{cmd, desc} <- @matches}>
          <button
            type="button"
            phx-click="use_command"
            phx-value-cmd={cmd}
            class="flex w-full gap-3 rounded-xl px-3 py-2 text-left hover:bg-base-content/[0.06]"
          >
            <span class="w-24 shrink-0 font-mono text-xs">{cmd}</span>
            <span class="text-base-content/60">{desc}</span>
          </button>
        </li>
      </ul>

      <div class={[
        "composer-box rounded-xl border border-base-content/15 shadow-[0_1px_2px_rgb(0_0_0/0.05),0_6px_20px_-10px_rgb(0_0_0/0.22)] transition-[border-color,box-shadow] focus-within:border-base-content/30 focus-within:shadow-[0_1px_2px_rgb(0_0_0/0.05),0_8px_24px_-10px_rgb(0_0_0/0.3)]",
        @glow && "is-glow"
      ]}>
        <div :if={@uploads.spec.entries != []} class="flex flex-wrap gap-2 px-4 pt-4">
          <span
            :for={entry <- @uploads.spec.entries}
            class={[
              "inline-flex items-center gap-1.5 rounded-xl border px-2.5 py-1.5 text-xs",
              if(upload_errors(@uploads.spec, entry) != [],
                do: "border-error/40 bg-error/10 text-error",
                else: "border-base-300 bg-base-200"
              )
            ]}
          >
            <.icon name="hero-document-text-mini" class="size-4 opacity-60" />
            {entry.client_name}
            <span :for={err <- upload_errors(@uploads.spec, entry)}>
              : {upload_error(err, @uploads.spec)}
            </span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="-mr-1 rounded-full p-0.5 opacity-60 hover:bg-base-content/[0.06] hover:opacity-100"
              aria-label={"Remove #{entry.client_name}"}
            >
              <.icon name="hero-x-mark-mini" class="size-3.5" />
            </button>
          </span>
        </div>
        <p :for={err <- upload_errors(@uploads.spec)} class="px-4 pt-2 text-xs text-error">
          {upload_error(err, @uploads.spec)}
        </p>

        <.input
          field={@form[:body]}
          type="textarea"
          id="chat-input"
          phx-hook="ChatInput"
          phx-debounce="100"
          rows="1"
          placeholder={placeholder(recipient(@focus, @to), @run, @planner, @job)}
          aria-label="Message"
          class="block max-h-[240px] min-h-[40px] w-full resize-none bg-transparent px-4 pb-1 pt-3 text-[14px] leading-6 outline-none placeholder:text-base-content/40 focus-visible:outline-none"
          wrapper_class="block"
        />

        <div class="flex items-center gap-1.5 px-2.5 pb-2.5 pt-0.5">
          <label
            for={@uploads.spec.ref}
            class="grid size-8 cursor-pointer place-items-center rounded-full border border-base-300 text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content"
            title="Attach spec files (.md, .txt)"
          >
            <.icon name="hero-plus-mini" class="size-5" />
            <span class="sr-only">Attach spec files</span>
          </label>
          <.live_file_input upload={@uploads.spec} class="sr-only" />

          <.recipient_picker agents={@agents} focus={@focus} to={@to} run={@run} />
          <.context_chip agent={recipient(@focus, @to)} />

          <span class="ml-auto"></span>
          <span class="composer-hint pr-1 text-xs text-base-content/35">
            Enter to send · Shift+Enter for a new line
          </span>
          <button
            id="send"
            type="submit"
            disabled={!@ready}
            class={[
              "grid size-7 place-items-center rounded-full transition",
              if(@ready,
                do: "bg-base-content text-base-100 hover:opacity-85",
                else: "cursor-not-allowed bg-base-content/15 text-base-content/40"
              )
            ]}
            aria-label="Send"
          >
            <.icon name="hero-arrow-up-mini" class="size-5" />
          </button>
        </div>
      </div>
    </.form>
    """
  end

  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :run, :any, required: true

  # "To: Planner ▾" — who the message goes to: the planner unless another is picked.
  defp recipient_picker(assigns) do
    assigns =
      assign(assigns,
        current: recipient(assigns.focus, assigns.to),
        run_draft: settable?(assigns.run)
      )

    ~H"""
    <details
      id="recipient"
      class="relative"
      phx-click-away={JS.remove_attribute("open", to: "#recipient")}
    >
      <summary class={[
        "flex h-8 cursor-pointer list-none items-center gap-1.5 rounded-full px-3 text-sm transition-colors hover:bg-base-content/[0.06] hover:text-base-content",
        if(@current, do: "bg-base-content/[0.06] text-base-content", else: "text-base-content/70")
      ]}>
        <.icon
          name={if @current, do: FactoryWeb.RunParts.kind_icon(@current.kind), else: "hero-bolt-mini"}
          class={["size-4", @current && "text-base-content/65"]}
        />
        <span class="max-w-40 truncate">{if @current, do: @current.name, else: "Factory"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute bottom-full left-0 z-30 mb-2 w-72 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <p class="px-3 pb-1 pt-1.5 text-xs text-base-content/45">Send to</p>
        <button
          :for={a <- @agents}
          type="button"
          phx-click={
            JS.push("to", value: %{id: a.id}) |> JS.remove_attribute("open", to: "#recipient")
          }
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            @current && @current.id == a.id && "bg-base-200"
          ]}
        >
          <span class={["size-2 rounded-full", Layouts.status_dot(a.status)]}></span>
          <span class="flex-1 truncate">
            {a.name}
            <span class="text-base-content/45">
              {if a.kind == "planner" and @run_draft, do: "plans the tasks", else: a.model}
            </span>
          </span>
          <.icon :if={@current && @current.id == a.id} name="hero-check-mini" class="size-4" />
        </button>
        <button
          type="button"
          phx-click={JS.push("to", value: %{id: ""}) |> JS.remove_attribute("open", to: "#recipient")}
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            @current == nil && "bg-base-200"
          ]}
        >
          <.icon name="hero-bolt-mini" class="size-4" />
          <span class="flex-1">Factory <span class="text-base-content/45">commands, specs</span></span>
          <.icon :if={@current == nil} name="hero-check-mini" class="size-4" />
        </button>
      </div>
    </details>
    """
  end
end
