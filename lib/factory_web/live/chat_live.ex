defmodule FactoryWeb.ChatLive do
  use FactoryWeb, :live_view
  alias Factory.{Agents, Chat, Runs}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runs.subscribe()
      Agents.subscribe()
    end

    {:ok,
     socket
     |> assign(runs: Runs.list_runs(), run: nil, draft: "", view: "chat")
     |> assign(graph: Agents.graph(), agents: Agents.list_agents(), commands: Chat.commands())
     |> assign(form: to_form(%{"body" => ""}, as: :chat))
     |> allow_upload(:spec,
       accept: ~w(.md .markdown .txt),
       max_entries: 5,
       max_file_size: 2_000_000
     )}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Runs.get_run(id) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, "That chat no longer exists.") |> push_navigate(to: ~p"/")}

      run ->
        {:noreply,
         socket |> watch(run) |> assign(page_title: run.title, run: run) |> load_messages()}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> watch(nil)
     |> assign(page_title: "Chat", run: nil)
     |> stream(:messages, [], reset: true)}
  end

  # Follow only the open run's messages.
  defp watch(socket, run) do
    old = socket.assigns.run

    if connected?(socket) and (old && old.id) != (run && run.id) do
      if old, do: Runs.unsubscribe(old.id)
      if run, do: Runs.subscribe(run.id)
    end

    socket
  end

  defp load_messages(socket),
    do: stream(socket, :messages, Runs.list_messages(socket.assigns.run.id), reset: true)

  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, draft: get_in(params, ["chat", "body"]) || "")}
  end

  def handle_event("send", %{"chat" => %{"body" => body}}, socket) do
    files =
      consume_uploaded_entries(socket, :spec, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    if String.trim(body) == "" and files == [] do
      {:noreply, socket}
    else
      {run, socket} = current_or_new_run(socket)
      Chat.handle(run, body, files)
      socket = socket |> assign(draft: "") |> push_event("chat:sent", %{})

      if socket.assigns.run,
        do: {:noreply, socket},
        else: {:noreply, push_patch(socket, to: ~p"/chat/#{run.id}")}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :spec, ref)}

  def handle_event("action", %{"action" => action}, socket) do
    Chat.action(Runs.get_run(socket.assigns.run.id), action)
    {:noreply, socket}
  end

  def handle_event("use_command", %{"cmd" => cmd}, socket) do
    {:noreply,
     socket |> assign(draft: cmd <> " ") |> push_event("chat:fill", %{text: cmd <> " "})}
  end

  def handle_event("view", %{"view" => view}, socket) when view in ["chat", "graph"],
    do: {:noreply, assign(socket, view: view)}

  # A click on an agent in the read-only workflow graph opens it in the editor.
  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/workflows/#{id}")}

  def handle_event(_flow_event, _params, socket), do: {:noreply, socket}

  defp current_or_new_run(%{assigns: %{run: nil}} = socket) do
    {:ok, run} = Runs.create_run()
    {run, socket}
  end

  defp current_or_new_run(socket), do: {Runs.get_run(socket.assigns.run.id), socket}

  def handle_info({:runs_changed}, socket), do: {:noreply, assign(socket, runs: Runs.list_runs())}

  def handle_info({:message, message}, socket),
    do: {:noreply, stream_insert(socket, :messages, message)}

  # Re-render messages when the status changes so buttons like "Start run" disappear once used.
  def handle_info({:run_updated, run}, socket) do
    status_changed = socket.assigns.run && socket.assigns.run.status != run.status
    socket = assign(socket, run: run, page_title: run.title)
    {:noreply, if(status_changed, do: load_messages(socket), else: socket)}
  end

  def handle_info({:graph_changed}, socket) do
    graph = Agents.graph()

    {:noreply,
     socket
     |> assign(graph: graph, agents: Agents.list_agents())
     |> push_event("flow:graph", graph)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:chat} full>
      <div class="flex h-full flex-col">
        <div class="flex h-12 shrink-0 items-center gap-3 border-b border-base-300 px-4">
          <.chat_switcher runs={@runs} run={@run} />
          <Layouts.status_badge :if={@run} status={@run.status} />
          <span :if={@run && @run.tasks != []} class="hidden text-sm text-base-content/55 sm:inline">
            {Enum.count(@run.tasks, &(&1.status == "done"))} of {length(@run.tasks)} tasks done
          </span>
          <div class="ml-auto flex rounded-field bg-base-300 p-0.5" role="tablist" aria-label="View">
            <button
              :for={
                {key, label, icon} <- [
                  {"chat", "Chat", "hero-chat-bubble-left-right"},
                  {"graph", "Graph", "hero-share"}
                ]
              }
              role="tab"
              aria-selected={to_string(@view == key)}
              phx-click="view"
              phx-value-view={key}
              class={[
                "flex items-center gap-1.5 rounded-field px-3 py-1 text-sm",
                if(@view == key,
                  do: "bg-base-100 font-medium shadow-sm",
                  else: "text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              <.icon name={icon} class="size-4" /> {label}
            </button>
          </div>
        </div>

        <.agent_strip agents={@agents} />

        <%!-- Hidden rather than removed: the message stream isn't kept on the server, so re-adding it would come back empty. --%>
        <section
          class={[
            "group relative min-h-0 flex-1 flex-col",
            if(@view == "chat", do: "flex", else: "hidden")
          ]}
          phx-drop-target={@uploads.spec.ref}
        >
          <div class="flex-1 overflow-y-auto" data-scroll>
            <div
              id="messages"
              phx-update="stream"
              phx-hook="ChatScroll"
              class="mx-auto max-w-3xl space-y-5 px-4 py-6"
            >
              <div id="messages-empty" class="hidden only:block">
                <.welcome uploads={@uploads} />
              </div>
              <.message :for={{id, m} <- @streams.messages} id={id} message={m} run={@run} />
            </div>
          </div>

          <.composer form={@form} uploads={@uploads} draft={@draft} commands={@commands} />

          <div class="pointer-events-none absolute inset-2 z-10 hidden place-items-center rounded-box border-2 border-dashed border-primary bg-base-100/90 group-[.phx-drop-target-active]:grid">
            <p class="text-lg font-semibold">Drop spec files to attach them</p>
          </div>
        </section>

        <section :if={@view == "graph"} class="relative min-h-0 flex-1">
          <div
            id="chat-flow"
            phx-hook="Flow"
            phx-update="ignore"
            data-readonly="true"
            data-graph={JSON.encode!(@graph)}
            class="h-full"
          >
          </div>
          <.link navigate={~p"/workflows"} class="btn btn-sm absolute right-4 top-4">
            <.icon name="hero-pencil-square-mini" class="size-4" /> Edit workflow
          </.link>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :runs, :list, required: true
  attr :run, :any, required: true

  # The chat title doubles as the menu for switching chats.
  defp chat_switcher(assigns) do
    ~H"""
    <details
      id="chat-switcher"
      class="dropdown min-w-0"
      phx-click-away={JS.remove_attribute("open", to: "#chat-switcher")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-1 rounded-field px-2 py-1 hover:bg-base-300">
        <span class="truncate font-semibold">{if @run, do: @run.title, else: "New chat"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 shrink-0 opacity-60" />
      </summary>
      <div class="dropdown-content z-30 mt-1 w-72 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
        <.link navigate={~p"/"} class="btn btn-primary btn-sm mb-2 w-full">
          <.icon name="hero-plus-mini" class="size-4" /> New chat
        </.link>
        <nav class="max-h-80 space-y-0.5 overflow-y-auto" aria-label="Chats">
          <.link
            :for={r <- @runs}
            navigate={~p"/chat/#{r.id}"}
            class={[
              "block rounded-md px-3 py-2 text-sm",
              if(@run && @run.id == r.id, do: "bg-base-200", else: "hover:bg-base-200")
            ]}
          >
            <span class="block truncate font-medium">{r.title}</span>
            <span class="flex items-center gap-1.5 text-xs text-base-content/55">
              <span class={["size-1.5 rounded-full", Layouts.status_dot(r.status)]}></span>
              {Layouts.status_label(r.status) <>
                if(r.tasks != [], do: ", #{length(r.tasks)} tasks", else: "")}
            </span>
          </.link>
          <p :if={@runs == []} class="px-3 py-2 text-sm text-base-content/50">No other chats yet.</p>
        </nav>
      </div>
    </details>
    """
  end

  attr :agents, :list, required: true

  # One chip per agent: who is busy and with what.
  defp agent_strip(assigns) do
    ~H"""
    <div
      class="flex shrink-0 items-center gap-2 overflow-x-auto border-b border-base-300 bg-base-200 px-4 py-2"
      aria-label="Agents"
    >
      <button
        :for={a <- @agents}
        phx-click="view"
        phx-value-view="graph"
        title={a.role}
        class={[
          "flex shrink-0 items-center gap-2 rounded-full border px-3 py-1 text-sm",
          if(a.status in ["running", "waiting", "error"],
            do: "border-base-content/20 bg-base-100",
            else: "border-transparent"
          )
        ]}
      >
        <span class="relative flex size-2">
          <span
            :if={a.status == "running"}
            class="absolute inline-flex size-full animate-ping rounded-full bg-info opacity-60 motion-reduce:hidden"
          ></span>
          <span class={["relative inline-flex size-2 rounded-full", Layouts.status_dot(a.status)]}></span>
        </span>
        <span class="font-medium">{a.name}</span>
        <span class={["max-w-64 truncate", Layouts.status_text(a.status)]}>{agent_activity(a)}</span>
      </button>
      <.link
        :if={@agents == []}
        navigate={~p"/workflows"}
        class="text-sm text-base-content/55 hover:underline"
      >
        No agents yet. Add them in Workflows.
      </.link>
    </div>
    """
  end

  defp agent_activity(%{status: "idle"}), do: "Idle"

  defp agent_activity(%{activity: activity, status: status}),
    do: activity || Layouts.status_label(status)

  attr :uploads, :map, required: true

  defp welcome(assigns) do
    ~H"""
    <div class="py-10 text-center">
      <h2 class="text-3xl font-semibold tracking-tight font-stretch-semi-condensed">
        What should the factory build?
      </h2>
      <p class="mx-auto mt-2 max-w-md text-base-content/60">
        Drop your spec here (requirements.md, design.md, tasks.md) and I'll read the tasks from it.
        Then start the run with /run.
      </p>
      <div class="mt-6 flex flex-wrap justify-center gap-2">
        <label for={@uploads.spec.ref} class="btn btn-sm">
          <.icon name="hero-paper-clip-mini" class="size-4" /> Attach a spec
        </label>
        <button phx-click="use_command" phx-value-cmd="/help" class="btn btn-sm btn-ghost">/help</button>
        <button phx-click="use_command" phx-value-cmd="/workflow" class="btn btn-sm btn-ghost">/workflow</button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :run, :any, required: true

  defp message(%{message: %{role: "user"}} = assigns) do
    ~H"""
    <div id={@id} class="flex justify-end">
      <div class="max-w-[85%] rounded-box rounded-br-sm bg-base-300 px-4 py-2.5">
        <.attachments names={@message.attachments} />
        <p :if={@message.body != ""} class="whitespace-pre-wrap break-words" phx-no-format>{rich(@message.body)}</p>
      </div>
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div id={@id} class="flex gap-3">
      <span class="grid size-7 shrink-0 place-items-center rounded-full bg-primary text-primary-content">
        <.icon name="hero-bolt-solid" class="size-4" />
      </span>
      <div class="min-w-0 flex-1 pt-0.5">
        <p class="whitespace-pre-wrap break-words" phx-no-format>{rich(@message.body)}</p>
        <div :if={"start" in @message.actions and startable?(@run)} class="mt-3 flex gap-2">
          <button phx-click="action" phx-value-action="start" class="btn btn-primary btn-sm">Start run</button>
        </div>
      </div>
    </div>
    """
  end

  defp startable?(run), do: run && run.status == "draft" && run.tasks != []

  attr :names, :list, required: true

  defp attachments(assigns) do
    ~H"""
    <div :if={@names != []} class="mb-1.5 flex flex-wrap gap-1.5">
      <span
        :for={n <- @names}
        class="inline-flex items-center gap-1 rounded-md bg-base-100 px-2 py-1 text-xs"
      >
        <.icon name="hero-document-text-mini" class="size-4 opacity-60" /> {n}
      </span>
    </div>
    """
  end

  # Message text with `code` spans. Built as a string (not a template) because messages keep their
  # line breaks, so any whitespace from template formatting would show up in the bubble.
  defp rich(text) do
    ~r/(`[^`\n]+`)/
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn
      "`" <> rest = part when byte_size(part) > 2 ->
        code = rest |> String.trim_trailing("`") |> escape()
        ~s(<code class="rounded bg-base-300 px-1 py-0.5 font-mono text-[0.85em]">#{code}</code>)

      part ->
        escape(part)
    end)
    |> Phoenix.HTML.raw()
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  attr :form, :any, required: true
  attr :uploads, :map, required: true
  attr :draft, :string, required: true
  attr :commands, :list, required: true

  defp composer(assigns) do
    matches =
      if String.match?(assigns.draft, ~r{^/\S*$}),
        do:
          Enum.filter(assigns.commands, fn {c, _} ->
            String.starts_with?(c, String.downcase(assigns.draft))
          end),
        else: []

    assigns = assign(assigns, :matches, matches)

    ~H"""
    <div class="shrink-0 px-4 pb-4">
      <.form
        for={@form}
        id="chat-form"
        phx-change="validate"
        phx-submit="send"
        class="mx-auto max-w-3xl"
      >
        <ul
          :if={@matches != []}
          class="mb-2 overflow-hidden rounded-box border border-base-300 bg-base-100 text-sm"
        >
          <li :for={{cmd, desc} <- @matches}>
            <button
              type="button"
              phx-click="use_command"
              phx-value-cmd={cmd}
              class="flex w-full gap-3 px-3 py-2 text-left hover:bg-base-200"
            >
              <span class="w-24 shrink-0 font-mono text-[13px]">{cmd}</span>
              <span class="text-base-content/60">{desc}</span>
            </button>
          </li>
        </ul>

        <div class="rounded-box border border-base-300 bg-base-100 focus-within:border-primary">
          <div :if={@uploads.spec.entries != []} class="flex flex-wrap gap-1.5 px-3 pt-3">
            <span
              :for={entry <- @uploads.spec.entries}
              class={[
                "inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs",
                if(upload_errors(@uploads.spec, entry) != [],
                  do: "bg-error/15 text-error",
                  else: "bg-base-200"
                )
              ]}
            >
              <.icon name="hero-document-text-mini" class="size-4 opacity-60" />
              {entry.client_name}
              <span :for={err <- upload_errors(@uploads.spec, entry)}>: {upload_error(err)}</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="ml-0.5 opacity-60 hover:opacity-100"
                aria-label={"Remove #{entry.client_name}"}
              >
                <.icon name="hero-x-mark-mini" class="size-4" />
              </button>
            </span>
          </div>
          <p :for={err <- upload_errors(@uploads.spec)} class="px-3 pt-2 text-xs text-error">
            {upload_error(err)}
          </p>

          <div class="flex items-end gap-1 p-2">
            <label
              for={@uploads.spec.ref}
              class="btn btn-ghost btn-sm btn-square cursor-pointer"
              title="Attach spec files (.md, .txt)"
            >
              <.icon name="hero-paper-clip" class="size-5" />
              <span class="sr-only">Attach spec files</span>
            </label>
            <.live_file_input upload={@uploads.spec} class="sr-only" />
            <textarea
              id="chat-input"
              name="chat[body]"
              phx-hook="ChatInput"
              phx-debounce="100"
              rows="1"
              placeholder="Type a command like /help, or drop a spec here"
              class="max-h-[200px] min-h-9 flex-1 resize-none bg-transparent px-1 py-1.5 outline-none focus-visible:outline-none"
              aria-label="Message"
            ></textarea>
            <button type="submit" class="btn btn-primary btn-sm btn-square" aria-label="Send">
              <.icon name="hero-arrow-up-mini" class="size-5" />
            </button>
          </div>
        </div>
        <p class="mt-1.5 hidden text-xs text-base-content/45 sm:block">
          Enter to send, Shift+Enter for a new line. Type / to see commands.
        </p>
      </.form>
    </div>
    """
  end

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"
  defp upload_error(:too_many_files), do: "up to 5 files at a time"
  defp upload_error(err), do: to_string(err)
end
