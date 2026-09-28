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
     |> assign(runs: Runs.list_runs(), run: nil, focus: nil, count: 0)
     |> assign(run_usage: %{turns: 0, credits: 0})
     |> assign(draft: "", view: "chat", streaming: %{})
     |> assign(commands: Chat.commands())
     |> load_agents()
     |> assign(form: to_form(%{"body" => ""}, as: :chat))
     |> allow_upload(:spec,
       accept: ~w(.md .markdown .txt),
       max_entries: 5,
       max_file_size: 2_000_000
     )}
  end

  def handle_params(params, _uri, socket) do
    focus = params["agent"] && Agents.get_agent(params["agent"])

    case params["id"] do
      nil ->
        {:noreply,
         socket
         |> watch(nil)
         |> FactoryWeb.UsageMeter.scope(:today)
         |> assign(run: nil)
         |> load_agents()
         |> assign(page_title: (focus && focus.name) || "Chat", run: nil, focus: focus, count: 0)
         |> assign(run_usage: %{turns: 0, credits: 0})
         |> assign(streaming: %{})
         |> stream(:messages, [], reset: true)}

      id ->
        case Runs.get_run(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That chat no longer exists.")
             |> push_navigate(to: ~p"/chat")}

          run ->
            {:noreply,
             socket
             |> watch(run)
             |> FactoryWeb.UsageMeter.scope({:run, run.id})
             |> assign(run: run)
             |> load_agents()
             |> assign(page_title: run.title, run: run, focus: focus, streaming: %{})
             |> load_messages()}
        end
    end
  end

  # The agents this chat talks to: the run's workflow, or the current one.
  defp load_agents(socket) do
    workflow = Factory.Workflows.for_run(socket.assigns[:run])

    assign(socket,
      workflow: workflow,
      graph: Agents.graph(workflow.id),
      agents: workflow.id |> Agents.list_agents() |> Enum.reject(&Factory.Agents.Agent.action?/1)
    )
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

  defp load_messages(socket) do
    messages = socket.assigns.run.id |> Runs.list_messages() |> Enum.filter(&visible?(&1, socket))

    socket
    |> assign(count: length(messages), run_usage: Runs.usage(socket.assigns.run.id))
    |> stream(:messages, messages, reset: true)
  end

  # In an agent's view, show only what was sent to it and what it (or the factory about it) replied.
  defp visible?(_message, %{assigns: %{focus: nil}}), do: true

  defp visible?(%{meta: meta}, %{assigns: %{focus: agent}}),
    do: meta["agent_id"] == agent.id or meta["to_agent_id"] == agent.id

  defp chat_path(nil, nil), do: ~p"/chat"
  defp chat_path(nil, agent), do: ~p"/chat?#{[agent: agent.id]}"
  defp chat_path(run, nil), do: ~p"/chat/#{run.id}"
  defp chat_path(run, agent), do: ~p"/chat/#{run.id}?#{[agent: agent.id]}"

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
      run = if socket.assigns.run, do: Runs.get_run(socket.assigns.run.id), else: new_run()
      Chat.handle(run, body, files, to: socket.assigns.focus)
      socket = socket |> assign(draft: "") |> push_event("chat:sent", %{})

      if socket.assigns.run,
        do: {:noreply, socket},
        else: {:noreply, push_patch(socket, to: chat_path(run, socket.assigns.focus))}
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

  # A click on an agent in the graph opens a chat with just that agent.
  def handle_event("select", %{"id" => id}, socket) do
    agent = Agents.get_agent(id)

    {:noreply,
     socket |> assign(view: "chat") |> push_patch(to: chat_path(socket.assigns.run, agent))}
  end

  def handle_event(_flow_event, _params, socket), do: {:noreply, socket}

  defp new_run do
    {:ok, run} = Runs.create_run()
    run
  end

  def handle_info({:runs_changed}, socket), do: {:noreply, assign(socket, runs: Runs.list_runs())}

  def handle_info({:message, message}, socket) do
    # An agent's final reply replaces its live bubble.
    socket = update(socket, :streaming, &Map.delete(&1, message.meta["agent_id"]))

    socket =
      if message.author && socket.assigns.run,
        do: assign(socket, run_usage: Runs.usage(socket.assigns.run.id)),
        else: socket

    if visible?(message, socket),
      do: {:noreply, socket |> update(:count, &(&1 + 1)) |> stream_insert(:messages, message)},
      else: {:noreply, socket}
  end

  def handle_info({:agent_stream, %{agent_id: id} = chunk}, socket) do
    {:noreply, update(socket, :streaming, &Map.put(&1, id, chunk))}
  end

  # Re-render messages when the status changes so buttons like "Start run" disappear once used.
  def handle_info({:run_updated, run}, socket) do
    status_changed = socket.assigns.run && socket.assigns.run.status != run.status
    socket = assign(socket, run: run, page_title: run.title)
    {:noreply, if(status_changed, do: load_messages(socket), else: socket)}
  end

  def handle_info({:graph_changed}, socket) do
    %{assigns: %{graph: graph, agents: agents}} = socket = load_agents(socket)
    focus = socket.assigns.focus && Enum.find(agents, &(&1.id == socket.assigns.focus.id))

    {:noreply,
     socket
     |> assign(graph: graph, agents: agents, focus: focus)
     |> push_event("flow:graph", graph)}
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        empty: assigns.count == 0 and assigns.streaming == %{},
        live:
          for(
            {id, s} <- assigns.streaming,
            assigns.focus == nil or assigns.focus.id == id,
            do: s
          )
      )

    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active={:chat} full>
      <div class="flex h-full flex-col bg-base-100">
        <header class="flex min-h-13 shrink-0 items-center gap-3 px-4 pt-2 sm:px-6">
          <.chat_switcher runs={@runs} run={@run} />
          <Layouts.status_badge :if={@run} status={@run.status} />
          <span
            :if={@run_usage.turns > 0}
            id="run-usage"
            class="hidden items-center gap-1 text-sm text-base-content/50 sm:flex"
            title="Agent replies in this chat and the Kiro credits they used"
          >
            <.icon name="hero-chart-bar-mini" class="size-4" />
            {@run_usage.turns} {if @run_usage.turns == 1, do: "turn", else: "turns"} · {FactoryWeb.Usage.credits(
              @run_usage.credits
            )} credits
          </span>
          <span :if={@run && @run.tasks != []} class="hidden text-sm text-base-content/50 sm:inline">
            {Enum.count(@run.tasks, &(&1.status == "done"))} of {length(@run.tasks)} tasks done
          </span>
          <.view_switch view={@view} />
        </header>

        <.agent_strip agents={@agents} focus={@focus} run={@run} />

        <%!-- Hidden rather than removed: the message stream isn't kept on the server, so re-adding it would come back empty. --%>
        <section
          id="chat"
          class={[
            "group relative min-h-0 flex-1 flex-col",
            if(@view == "chat", do: "flex", else: "hidden")
          ]}
          phx-drop-target={@uploads.spec.ref}
        >
          <div class={["min-h-0 flex-1 overflow-y-auto", @empty && "hidden"]} data-scroll>
            <div
              id="messages"
              phx-update="stream"
              phx-hook="ChatScroll"
              class="mx-auto flex max-w-3xl flex-col gap-7 px-5 pt-8"
            >
              <.message
                :for={{id, m} <- @streams.messages}
                id={id}
                message={m}
                run={@run}
                agents={@agents}
                focus={@focus}
              />
            </div>
            <div :if={@live != []} class="mx-auto flex max-w-3xl flex-col gap-7 px-5 pt-7">
              <.agent_reply :for={s <- @live} name={s.name} body={s.text} live />
            </div>
            <%!-- Room to scroll the last message above the floating message box. --%>
            <div class="h-48"></div>
          </div>

          <div
            :if={@empty}
            class="flex min-h-0 flex-1 items-center justify-center overflow-hidden px-4 pb-40"
          >
            <.greeting focus={@focus} />
          </div>

          <div class="pointer-events-none absolute inset-x-0 bottom-0 bg-linear-to-t from-base-200 from-60% to-transparent px-4 pb-4 pt-10">
            <.composer
              form={@form}
              uploads={@uploads}
              draft={@draft}
              commands={@commands}
              agents={@agents}
              focus={@focus}
              run={@run}
            />
          </div>

          <div class="pointer-events-none absolute inset-3 z-20 hidden place-items-center rounded-3xl border-2 border-dashed border-primary/60 bg-base-100/85 backdrop-blur-sm group-[.phx-drop-target-active]:grid">
            <div class="text-center">
              <.icon name="hero-document-arrow-up" class="size-8 text-primary" />
              <p class="mt-2 font-medium">Drop spec files to attach them</p>
            </div>
          </div>
        </section>

        <section :if={@view == "graph"} class="relative min-h-0 flex-1">
          <div
            id={"chat-flow-#{@workflow.id}"}
            phx-hook="Flow"
            phx-update="ignore"
            data-readonly="true"
            data-graph={JSON.encode!(@graph)}
            class="h-full"
          >
          </div>
          <p class="absolute left-4 top-4 rounded-full bg-base-100/90 px-3 py-1.5 text-sm text-base-content/60 shadow-sm">
            Click an agent to chat with it
          </p>
          <.link
            navigate={~p"/workflows"}
            class="absolute right-4 top-4 flex items-center gap-1.5 rounded-full border border-base-content/10 bg-surface px-3 py-1.5 text-sm shadow-sm hover:bg-base-content/[0.06]"
          >
            <.icon name="hero-pencil-square-mini" class="size-4" /> Edit workflow
          </.link>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :view, :string, required: true

  defp view_switch(assigns) do
    ~H"""
    <div
      class="ml-auto flex rounded-lg border border-base-300 p-0.5"
      role="tablist"
      aria-label="View"
    >
      <button
        :for={
          {key, label, icon} <- [
            {"chat", "Chat", "hero-chat-bubble-left-right-mini"},
            {"graph", "Graph", "hero-share-mini"}
          ]
        }
        id={"view-#{key}"}
        role="tab"
        aria-selected={to_string(@view == key)}
        phx-click="view"
        phx-value-view={key}
        class={[
          "flex items-center gap-1.5 rounded-md px-3 py-1 text-sm transition-colors",
          if(@view == key,
            do: "bg-base-content/10 font-medium text-base-content",
            else: "text-base-content/55 hover:text-base-content"
          )
        ]}
      >
        <.icon name={icon} class="size-4" /> {label}
      </button>
    </div>
    """
  end

  attr :runs, :list, required: true
  attr :run, :any, required: true

  # The chat title doubles as the menu for switching chats.
  defp chat_switcher(assigns) do
    ~H"""
    <details
      id="chat-switcher"
      class="relative min-w-0"
      phx-click-away={JS.remove_attribute("open", to: "#chat-switcher")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-1 rounded-lg px-2 py-1 hover:bg-base-content/[0.06]">
        <span class="truncate font-semibold">{if @run, do: @run.title, else: "New chat"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 shrink-0 opacity-50" />
      </summary>
      <div class="absolute left-0 z-30 mt-1 w-72 rounded-2xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <.link
          navigate={~p"/chat"}
          class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm font-medium hover:bg-base-content/[0.06]"
        >
          <.icon name="hero-pencil-square-mini" class="size-4" /> New chat
        </.link>
        <p :if={@runs != []} class="px-3 pb-1 pt-2 text-xs text-base-content/45">Recent</p>
        <nav class="max-h-80 overflow-y-auto" aria-label="Chats">
          <.link
            :for={r <- @runs}
            navigate={~p"/chat/#{r.id}"}
            class={[
              "block rounded-xl px-3 py-2 text-sm",
              if(@run && @run.id == r.id, do: "bg-base-200", else: "hover:bg-base-content/[0.06]")
            ]}
          >
            <span class="block truncate">{r.title}</span>
            <span class="flex items-center gap-1.5 text-xs text-base-content/50">
              <span class={["size-1.5 rounded-full", Layouts.status_dot(r.status)]}></span>
              {Layouts.status_label(r.status) <>
                if(r.tasks != [], do: ", #{length(r.tasks)} tasks", else: "")}
            </span>
          </.link>
        </nav>
      </div>
    </details>
    """
  end

  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :run, :any, required: true

  # Who is busy with what. Click an agent to chat with just that agent; "All" shows everything.
  defp agent_strip(assigns) do
    ~H"""
    <nav
      class="flex shrink-0 items-center gap-1.5 overflow-x-auto border-b border-base-300 px-4 pb-2.5 pt-1 sm:px-6"
      aria-label="Agents"
    >
      <.link
        id="agent-all"
        patch={chat_path(@run, nil)}
        class={[
          "flex shrink-0 items-center gap-1.5 rounded-full px-3 py-1 text-sm transition-colors",
          if(@focus == nil,
            do: "bg-base-content/10 font-medium text-base-content",
            else: "text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
          )
        ]}
      >
        All
      </.link>
      <span class="mx-1 h-4 w-px shrink-0 bg-base-300"></span>
      <.link
        :for={a <- @agents}
        id={"agent-chip-#{a.id}"}
        patch={chat_path(@run, if(@focus && @focus.id == a.id, do: nil, else: a))}
        title={if a.role != "", do: a.role, else: "Chat with #{a.name}"}
        class={[
          "flex shrink-0 items-center gap-2 rounded-full border px-3 py-1 text-sm transition-colors",
          cond do
            @focus && @focus.id == a.id ->
              "border-primary/50 bg-primary/10 text-base-content"

            a.status in ["running", "waiting", "error"] ->
              "border-base-content/15 hover:bg-base-content/[0.06]"

            true ->
              "border-transparent hover:bg-base-content/[0.06]"
          end
        ]}
      >
        <span class="relative flex size-2">
          <span
            :if={a.status == "running"}
            class="absolute inline-flex size-full animate-ping rounded-full bg-info opacity-60 motion-reduce:hidden"
          ></span>
          <span class={["relative inline-flex size-2 rounded-full", Layouts.status_dot(a.status)]}></span>
        </span>
        <.icon name={FactoryWeb.AgentKinds.icon(a.kind)} class="-mx-0.5 size-4 opacity-70" />
        <span class="font-medium">{a.name}</span>
        <span
          :if={a.usage["context_pct"]}
          class="rounded-full bg-base-content/10 px-1.5 text-[11px] tabular-nums text-base-content/60"
          title={"Context: " <> (FactoryWeb.Usage.context(a.usage) || "")}
        >
          {FactoryWeb.Usage.pct(a.usage["context_pct"])}
        </span>
        <span class={[
          "max-w-56 truncate",
          if(@focus && @focus.id == a.id, do: "opacity-70", else: Layouts.status_text(a.status))
        ]}>
          {agent_activity(a)}
        </span>
      </.link>
      <.link
        :if={@agents == []}
        navigate={~p"/workflows"}
        class="text-sm text-base-content/55 hover:underline"
      >
        No agents yet. Add them in Workflows.
      </.link>
    </nav>
    """
  end

  defp agent_activity(%{status: "idle"}), do: "Idle"

  defp agent_activity(%{activity: activity, status: status}),
    do: activity || Layouts.status_label(status)

  attr :focus, :any, required: true

  defp greeting(%{focus: nil} = assigns) do
    ~H"""
    <div class="mb-8 max-w-xl text-center">
      <h1 class="text-4xl font-semibold tracking-tight font-stretch-semi-condensed">
        What should the factory build?
      </h1>
      <p class="mt-3 text-base-content/60">
        Drop a spec (requirements.md, design.md, tasks.md) and I'll read the tasks from it.
        Pick an agent above to talk to it directly.
      </p>
    </div>
    """
  end

  defp greeting(assigns) do
    ~H"""
    <div class="mb-8 max-w-xl text-center">
      <span class="mx-auto grid size-12 place-items-center rounded-2xl bg-base-content/[0.06]">
        <.icon name="hero-cpu-chip" class="size-6" />
      </span>
      <h1 class="mt-4 text-4xl font-semibold tracking-tight font-stretch-semi-condensed">
        Chat with {@focus.name}
      </h1>
      <p :if={@focus.runtime == "kiro_v3"} class="mt-3 text-base-content/60">
        Runs on Kiro v3 with {@focus.model} in {@focus.kiro_mode} mode. {if @focus.role != "",
          do: @focus.role <> "."}
      </p>
      <p :if={@focus.runtime != "kiro_v3"} class="mt-3 text-base-content/60">
        {@focus.name} isn't connected to Kiro yet.
        <.link navigate={~p"/workflows/#{@focus.id}"} class="text-primary hover:underline">
          Connect it in Workflows
        </.link>
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :map, required: true
  attr :run, :any, required: true
  attr :agents, :list, required: true
  attr :focus, :any, required: true

  defp message(%{message: %{role: "user"}} = assigns) do
    assigns = assign(assigns, :to, to_agent_name(assigns.message, assigns.agents, assigns.focus))

    ~H"""
    <div id={@id} class="flex flex-col items-end gap-1">
      <span :if={@to} class="text-xs text-base-content/45">To {@to}</span>
      <div class="max-w-[85%] rounded-3xl border border-base-300/70 bg-base-200 px-4 py-2.5 text-[15px] leading-relaxed">
        <.attachments names={@message.attachments} />
        <p :if={@message.body != ""} class="whitespace-pre-wrap break-words" phx-no-format>{rich(@message.body)}</p>
      </div>
    </div>
    """
  end

  defp message(%{message: %{author: author}} = assigns) when is_binary(author) do
    ~H"""
    <div id={@id}>
      <.agent_reply id={"md-#{@id}"} name={@message.author} body={@message.body} meta={@message.meta} />
    </div>
    """
  end

  defp message(assigns) do
    ~H"""
    <div id={@id}>
      <p class="mb-1.5 flex items-center gap-2 text-sm">
        <span class="grid size-5 place-items-center rounded-md bg-primary text-primary-content">
          <.icon name="hero-bolt-solid" class="size-3" />
        </span>
        <span class="font-semibold">Factory</span>
      </p>
      <div id={"md-#{@id}"} class="md" phx-hook="Markdown" phx-update="ignore">
        {FactoryWeb.Markdown.render(@message.body)}
      </div>
      <button
        :if={"start" in @message.actions and startable?(@run)}
        id={"start-#{@message.id}"}
        phx-click="action"
        phx-value-action="start"
        class="mt-3 flex items-center gap-1.5 rounded-full bg-primary px-4 py-1.5 text-sm font-medium text-primary-content hover:opacity-90"
      >
        <.icon name="hero-play-mini" class="size-4" /> Start run
      </button>
    </div>
    """
  end

  # "To Coder" above a message sent to one agent, shown only in the All view.
  defp to_agent_name(_message, _agents, focus) when focus != nil, do: nil

  defp to_agent_name(%{body: "/" <> _}, _agents, _), do: nil

  defp to_agent_name(%{meta: %{"to_agent_id" => id}}, agents, _),
    do: Enum.find_value(agents, &(&1.id == id && &1.name))

  defp to_agent_name(_message, _agents, _focus), do: nil

  attr :id, :string,
    default: nil,
    doc: "set for stored replies; live ones re-render as text streams in"

  attr :name, :string, required: true
  attr :body, :string, required: true
  attr :meta, :map, default: %{}
  attr :live, :boolean, default: false

  # A reply written by an agent (via Kiro), or one still streaming in.
  defp agent_reply(assigns) do
    ~H"""
    <div class="group/reply">
      <p class="mb-1.5 flex items-center gap-2 text-sm">
        <span class="grid size-5 place-items-center rounded-md bg-base-content/[0.06]">
          <.icon name="hero-cpu-chip-mini" class="size-3.5" />
        </span>
        <span class="font-semibold">{@name}</span>
      </p>
      <div :if={@id} id={@id} class="md" phx-hook="Markdown" phx-update="ignore">
        {FactoryWeb.Markdown.render(@body)}
      </div>
      <div :if={!@id and @body != ""} class="md">{FactoryWeb.Markdown.render(@body)}</div>
      <span :if={@live} class="mt-2 inline-flex gap-1" aria-label="Writing">
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.3s]"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40 [animation-delay:-0.15s]"></span>
        <span class="size-1.5 animate-bounce rounded-full bg-base-content/40"></span>
      </span>
      <%!-- Usage is always shown; Copy appears on hover. --%>
      <div
        :if={@id}
        class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/45"
      >
        <span
          :if={@meta["credits"]}
          class="flex items-center gap-1"
          title="Kiro credits this reply used"
        >
          <.icon name="hero-bolt-mini" class="size-3.5" />
          {FactoryWeb.Usage.credits(@meta["credits"])} credits
        </span>
        <span :if={@meta["ms"]} class="flex items-center gap-1" title="Time Kiro took">
          <.icon name="hero-clock-mini" class="size-3.5" />
          {Float.round(@meta["ms"] / 1000, 1)} s
        </span>
        <span
          :if={FactoryWeb.Usage.context(@meta)}
          class="flex items-center gap-1"
          title="How full the agent's context window is after this reply. Kiro doesn't state the window size, so it is estimated."
        >
          <.icon name="hero-circle-stack-mini" class="size-3.5" />
          {FactoryWeb.Usage.context(@meta)}
        </span>
        <span
          :if={@meta["session"] == "shared"}
          class="flex items-center gap-1"
          title="Answered in the shared Kiro session, which all shared agents take part in"
        >
          <.icon name="hero-users-mini" class="size-3.5" /> shared session
        </span>
        <button
          id={"copy-#{@id}"}
          type="button"
          phx-click={JS.dispatch("factory:copy", to: "##{@id}", detail: %{button: "copy-#{@id}"})}
          class="flex items-center gap-1 rounded-md px-1.5 py-0.5 opacity-0 transition-opacity hover:bg-base-content/[0.06] hover:text-base-content focus:opacity-100 group-hover/reply:opacity-100"
        >
          <.icon name="hero-clipboard-document-mini" class="size-3.5" /> <span>Copy</span>
        </button>
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
        class="inline-flex items-center gap-1.5 rounded-xl bg-base-100 px-2.5 py-1.5 text-xs"
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
        ~s(<code class="code-inline">#{code}</code>)

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
  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :run, :any, required: true

  # Rounded card: attachments, the message, then a toolbar with attach, recipient and send.
  defp composer(assigns) do
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
        class="absolute inset-x-0 bottom-full mb-2 overflow-hidden rounded-2xl border border-base-content/10 bg-surface p-1 text-sm shadow-xl"
      >
        <li :for={{cmd, desc} <- @matches}>
          <button
            type="button"
            phx-click="use_command"
            phx-value-cmd={cmd}
            class="flex w-full gap-3 rounded-xl px-3 py-2 text-left hover:bg-base-content/[0.06]"
          >
            <span class="w-24 shrink-0 font-mono text-[13px]">{cmd}</span>
            <span class="text-base-content/60">{desc}</span>
          </button>
        </li>
      </ul>

      <div class="composer-box rounded-[26px] border border-base-content/15 shadow-[0_1px_2px_rgb(0_0_0/0.06),0_8px_28px_-8px_rgb(0_0_0/0.28)] transition-[border-color,box-shadow] focus-within:border-base-content/30 focus-within:shadow-[0_1px_2px_rgb(0_0_0/0.06),0_10px_32px_-8px_rgb(0_0_0/0.36)]">
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
            <span :for={err <- upload_errors(@uploads.spec, entry)}>: {upload_error(err)}</span>
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
          {upload_error(err)}
        </p>

        <textarea
          id="chat-input"
          name="chat[body]"
          phx-hook="ChatInput"
          phx-debounce="100"
          rows="1"
          placeholder={
            if @focus,
              do: "Message #{@focus.name}…",
              else: "Message the factory, or type / for commands"
          }
          class="block max-h-[240px] min-h-[52px] w-full resize-none bg-transparent px-5 pb-1 pt-4 text-[15px] leading-6 outline-none placeholder:text-base-content/40 focus-visible:outline-none"
          aria-label="Message"
        ></textarea>

        <div class="flex items-center gap-1.5 px-3 pb-3 pt-1">
          <label
            for={@uploads.spec.ref}
            class="grid size-8 cursor-pointer place-items-center rounded-full border border-base-300 text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content"
            title="Attach spec files (.md, .txt)"
          >
            <.icon name="hero-plus-mini" class="size-5" />
            <span class="sr-only">Attach spec files</span>
          </label>
          <.live_file_input upload={@uploads.spec} class="sr-only" />

          <.recipient_picker agents={@agents} focus={@focus} run={@run} />

          <span class="ml-auto hidden pr-1 text-xs text-base-content/35 sm:inline">
            Enter to send · Shift+Enter for a new line
          </span>
          <button
            id="send"
            type="submit"
            disabled={!@ready}
            class={[
              "grid size-8 place-items-center rounded-full transition",
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
  attr :run, :any, required: true

  # "To: Factory ▾" — who the message goes to.
  defp recipient_picker(assigns) do
    ~H"""
    <details
      id="recipient"
      class="relative"
      phx-click-away={JS.remove_attribute("open", to: "#recipient")}
    >
      <summary class="flex h-8 cursor-pointer list-none items-center gap-1.5 rounded-full px-3 text-sm text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content">
        <.icon
          name={if @focus, do: "hero-cpu-chip-mini", else: "hero-bolt-mini"}
          class="size-4"
        />
        <span class="max-w-40 truncate">{if @focus, do: @focus.name, else: "Factory"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute bottom-full left-0 z-30 mb-2 w-64 rounded-2xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <p class="px-3 pb-1 pt-1.5 text-xs text-base-content/45">Send to</p>
        <.link
          patch={chat_path(@run, nil)}
          class={[
            "flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm hover:bg-base-content/[0.06]",
            @focus == nil && "bg-base-200"
          ]}
        >
          <.icon name="hero-bolt-mini" class="size-4" />
          <span class="flex-1">Factory <span class="text-base-content/45">commands, specs</span></span>
          <.icon :if={@focus == nil} name="hero-check-mini" class="size-4" />
        </.link>
        <.link
          :for={a <- @agents}
          patch={chat_path(@run, a)}
          class={[
            "flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm hover:bg-base-content/[0.06]",
            @focus && @focus.id == a.id && "bg-base-200"
          ]}
        >
          <span class={["size-2 rounded-full", Layouts.status_dot(a.status)]}></span>
          <span class="flex-1 truncate">
            {a.name}
            <span class="text-base-content/45">
              {if a.runtime == "kiro_v3", do: a.model, else: "not connected"}
            </span>
          </span>
          <.icon :if={@focus && @focus.id == a.id} name="hero-check-mini" class="size-4" />
        </.link>
      </div>
    </details>
    """
  end

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"
  defp upload_error(:too_many_files), do: "up to 5 files at a time"
  defp upload_error(err), do: to_string(err)
end
