defmodule FactoryWeb.ChatLive do
  use FactoryWeb, :live_view
  import Ecto.Query, only: [from: 2]
  alias Factory.{Agents, Chat, Engine, FileBrowser, Kiro, Runs, Workflows}
  alias Factory.Repo
  alias Factory.Runs.Message
  alias FactoryWeb.WorkflowMap

  @message_limit 200
  @message_page 50

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runs.subscribe()
      Agents.subscribe()
      # Runs opened and left without a word or a task go after an hour.
      Runs.prune_empty()
    end

    # A new run starts clean: no folder and no specs until you choose them.
    {:ok,
     socket
     |> assign(runs: Runs.list_runs(), runs_reload: nil, run: nil, focus: nil, count: 0)
     |> assign(run_usage: %{turns: 0, credits: 0})
     |> assign(draft: "", view: "chat", streaming: %{})
     |> assign(message_ids: [], earlier?: false, history?: false)
     |> assign(commands: Chat.commands())
     |> assign(workflows: Workflows.list(), browser: nil, folder_warn: false, to: nil)
     |> assign(pick: Workflows.picked())
     |> assign(base_ids: [])
     |> set_dir("")
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
         |> assign(run: nil, pick: Workflows.picked())
         |> assign(base_ids: [])
         |> set_dir("")
         |> load_agents()
         |> assign(page_title: (focus && focus.name) || "Chat", run: nil, focus: focus, count: 0)
         |> assign(run_usage: %{turns: 0, credits: 0})
         |> assign(streaming: %{})
         |> assign(message_ids: [], earlier?: false, history?: false)
         |> stream(:messages, [], reset: true, limit: -@message_limit)}

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
             |> keep_dir(run)
             |> assign(base_ids: run.settings["base_spec_ids"] || [])
             |> load_agents()
             |> assign(page_title: run.title, run: run, focus: focus, streaming: %{})
             |> load_messages()}
        end
    end
  end

  # The agents this chat talks to: the run's workflow, or the current one. `steps` are
  # the workflow's steps as the run follows them, for the map above the chat.
  # Messages go to `to` (the workflow's planner unless another is picked), or to the
  # agent the chat is focused on.
  defp load_agents(socket) do
    run = socket.assigns[:run]
    # A finished run can outlive its workflow; show the current one (Chat refuses to run it).
    workflow =
      if run, do: Workflows.for_run(run) || Workflows.current(), else: socket.assigns.pick

    agents = workflow.id |> Agents.list_agents() |> Enum.reject(&Factory.Agents.Agent.action?/1)

    to =
      case socket.assigns[:to] do
        :factory -> :factory
        old -> (old && Enum.find(agents, &(&1.id == old.id))) || default_to(agents)
      end

    assign(socket,
      workflow: workflow,
      graph: Agents.graph(workflow.id),
      agents: agents,
      to: to,
      steps: if(run, do: Engine.steps(run), else: Engine.workflow_steps(workflow.id))
    )
  end

  defp placeholder(nil, _run), do: "Message the factory, or type / for commands"

  defp placeholder(%{kind: "planner"} = agent, run) do
    if settable?(run),
      do: "Describe a change, e.g. add an export button to the invoices page…",
      else: "Message #{agent.name}…"
  end

  defp placeholder(agent, _run), do: "Message #{agent.name}…"

  # Specs on this run: its base specs, and its own spec once something is written in it.
  defp spec_count(assigns) do
    own = if assigns.run && assigns.run.spec_files != [], do: 1, else: 0
    length(assigns.base_ids) + own
  end

  defp default_to(agents),
    do: Enum.find(agents, &(&1.kind == "planner")) || List.first(agents) || :factory

  # The agent a message goes to, or nil for the factory.
  defp recipient(focus, _to) when focus != nil, do: focus
  defp recipient(_focus, :factory), do: nil
  defp recipient(_focus, to), do: to

  # A run keeps its folder. One that has none yet waits for you to choose it.
  defp keep_dir(socket, run), do: set_dir(socket, run.settings["project_dir"])

  defp set_dir(socket, dir) do
    dir = String.trim(dir || "")
    assign(socket, dir: dir, dir_ok: dir != "" and File.dir?(Path.expand(dir)))
  end

  # The workflow and folder can change until the run starts.
  defp settable?(nil), do: true
  defp settable?(run), do: run.status == "draft"

  defp save_setting(%{assigns: %{run: nil}} = socket, _key, _value), do: socket

  defp save_setting(%{assigns: %{run: run}} = socket, key, value) do
    {:ok, run} = Runs.update_run(run, %{settings: Map.put(run.settings, key, value)})
    assign(socket, run: run)
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
    {messages, earlier?} = message_page(socket, @message_limit)

    socket
    |> assign(
      count: length(messages),
      message_ids: Enum.map(messages, & &1.id),
      earlier?: earlier?,
      history?: false,
      run_usage: Runs.usage(socket.assigns.run.id)
    )
    |> stream(:messages, messages, reset: true, limit: -@message_limit)
  end

  defp message_page(socket, limit, before_id \\ nil) do
    query = from m in Message, where: m.run_id == ^socket.assigns.run.id

    query =
      if agent = socket.assigns.focus do
        from m in query,
          where:
            fragment("?->>'agent_id'", m.meta) == ^to_string(agent.id) or
              fragment("?->>'to_agent_id'", m.meta) == ^to_string(agent.id)
      else
        query
      end

    query = if before_id, do: from(m in query, where: m.id < ^before_id), else: query
    messages = Repo.all(from m in query, order_by: [desc: m.id], limit: ^(limit + 1))
    {messages |> Enum.take(limit) |> Enum.reverse(), length(messages) > limit}
  end

  defp refresh_messages(socket) do
    messages =
      Repo.all(from m in Message, where: m.id in ^socket.assigns.message_ids, order_by: m.id)

    socket
    |> assign(run_usage: Runs.usage(socket.assigns.run.id))
    |> stream(:messages, messages, limit: -@message_limit)
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

  def handle_event("load_earlier", _, socket) do
    if socket.assigns.earlier? do
      {messages, earlier?} =
        message_page(socket, @message_page, List.first(socket.assigns.message_ids))

      ids = Enum.take(Enum.map(messages, & &1.id) ++ socket.assigns.message_ids, @message_limit)

      {:noreply,
       socket
       |> assign(message_ids: ids, count: length(ids), earlier?: earlier?, history?: true)
       |> stream(:messages, Enum.reverse(messages), at: 0, limit: @message_limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("latest", _, socket) do
    socket = if socket.assigns.run, do: load_messages(socket), else: socket
    {:noreply, push_event(socket, "chat:latest", %{})}
  end

  # Commands work anywhere; anything for the agents needs the folder they work in.
  def handle_event("send", %{"chat" => %{"body" => body}}, socket) do
    if socket.assigns.dir_ok or String.starts_with?(String.trim(body), "/") do
      send_message(socket, body)
    else
      {:noreply,
       socket
       |> assign(folder_warn: true)
       |> put_flash(
         :error,
         "Choose the project folder first: the agents need to know where to work."
       )}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :spec, ref)}

  # The workflow the chat plans for, and the folder its agents work in.

  def handle_event("pick_workflow", %{"id" => id}, socket) do
    # Read the run again so an event queued before its status update cannot change it.
    run = socket.assigns.run && Runs.get_run(socket.assigns.run.id)

    case settable?(run) && Workflows.get(id) do
      false ->
        {:noreply, socket}

      nil ->
        {:noreply, socket}

      workflow ->
        {:noreply,
         socket
         # Picked here, picked everywhere: the Workflows page opens on it too.
         |> assign(pick: elem(Workflows.set_current(workflow), 1), to: nil)
         |> assign(base_ids: workflow.base_spec_ids)
         |> save_setting("workflow_id", workflow.id)
         |> save_setting("base_spec_ids", workflow.base_spec_ids)
         |> load_agents()}
    end
  end

  # Who messages go to: an agent, or "" for the factory itself (commands, specs).
  def handle_event("to", %{"id" => id}, socket) do
    to = Enum.find(socket.assigns.agents, &(to_string(&1.id) == to_string(id))) || :factory
    socket = assign(socket, to: to)

    if socket.assigns.focus,
      do: {:noreply, push_patch(socket, to: chat_path(socket.assigns.run, recipient(nil, to)))},
      else: {:noreply, socket}
  end

  # The run's spec (requirements, design, tasks) opens on the Spec page: Specs at the
  # first step still to write, Plan at the tasks. A new chat is saved as a run first, so
  # its workflow and folder go with it.
  def handle_event("tasks", _, socket) do
    if socket.assigns.dir_ok do
      {:noreply, push_navigate(socket, to: spec_path(socket, step: "tasks"))}
    else
      {:noreply,
       socket
       |> assign(folder_warn: true)
       |> put_flash(:error, "Choose the project folder first: Kiro reads it to make the plan.")}
    end
  end

  def handle_event("specs", _, socket),
    do: {:noreply, push_navigate(socket, to: spec_path(socket, []))}

  def handle_event("browse", _, socket) do
    browser = %{mode: "dir", hidden: false, listing: nil, error: nil}
    # This chat's folder, else the one picked last.
    start =
      FileBrowser.start_dir(
        if(socket.assigns.dir_ok, do: socket.assigns.dir, else: Factory.Prefs.project_dir())
      )

    {:noreply, assign(socket, browser: browse(browser, start))}
  end

  def handle_event("browse_go", %{"path" => path}, socket),
    do: {:noreply, update(socket, :browser, &browse(&1, path))}

  def handle_event("browse_hidden", _, socket) do
    browser = %{socket.assigns.browser | hidden: !socket.assigns.browser.hidden}
    {:noreply, assign(socket, browser: browse(browser, browser.listing && browser.listing.dir))}
  end

  def handle_event("browse_cancel", _, socket), do: {:noreply, assign(socket, browser: nil)}

  def handle_event("browse_pick", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(browser: nil, folder_warn: false)
     |> tap(fn _ -> Factory.Prefs.remember_project_dir(path) end)
     |> set_dir(path)
     |> save_setting("project_dir", Path.expand(path))}
  end

  def handle_event("action", %{"action" => action}, socket) do
    Chat.action(Runs.get_run(socket.assigns.run.id), action)
    {:noreply, socket}
  end

  # Pause and Resume beside the workflow: the same as typing the command.
  def handle_event("control", %{"command" => command}, socket)
      when command in ["/pause", "/resume"] do
    Chat.handle(Runs.get_run(socket.assigns.run.id), command)
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

  # The Compact button on the context chip: /compact in this chat, which notes the result.
  def handle_event("compact", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &("#{&1.id}" == id))

    cond do
      agent == nil ->
        {:noreply, socket}

      socket.assigns.run ->
        Chat.handle(Runs.get_run(socket.assigns.run.id), "/compact", [], to: agent)
        {:noreply, socket}

      true ->
        {:noreply, compact_flash(socket, agent, Kiro.compact(agent))}
    end
  end

  def handle_event(_flow_event, _params, socket), do: {:noreply, socket}

  defp compact_flash(socket, agent, :ok),
    do: put_flash(socket, :info, "Compacted #{agent.name}'s conversation.")

  defp compact_flash(socket, agent, {:error, :no_gain}),
    do: put_flash(socket, :info, "#{agent.name}'s conversation is already small.")

  defp compact_flash(socket, agent, _error),
    do: put_flash(socket, :error, "Couldn't compact #{agent.name}'s conversation right now.")

  # The run's spec on the Spec page, at `query` (e.g. `step: "tasks"`).
  defp spec_path(socket, query) do
    spec = Factory.Specs.for_run(socket.assigns.run || new_run(socket))
    ~p"/specs/#{spec.id}?#{query}"
  end

  defp send_message(socket, body) do
    files =
      consume_uploaded_entries(socket, :spec, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    if String.trim(body) == "" and files == [] do
      {:noreply, socket}
    else
      run = if socket.assigns.run, do: Runs.get_run(socket.assigns.run.id), else: new_run(socket)
      Chat.handle(run, body, files, to: recipient(socket.assigns.focus, socket.assigns.to))
      socket = socket |> assign(draft: "", folder_warn: false) |> push_event("chat:sent", %{})

      if socket.assigns.run,
        do: {:noreply, socket},
        else: {:noreply, push_patch(socket, to: chat_path(run, socket.assigns.focus))}
    end
  end

  # A new chat keeps the workflow and folder chosen for it.
  # A run for this chat: the latest empty one if there is one (opening Specs or Tasks
  # from a fresh chat shouldn't pile up runs), else a new one named after the project.
  defp new_run(socket) do
    dir = if(socket.assigns.dir_ok, do: Path.expand(socket.assigns.dir))

    run =
      case Runs.latest_empty() do
        nil ->
          {:ok, run} = Runs.create_run(Runs.default_title(dir))
          run

        run ->
          run
      end

    title =
      if run.title in ["New run", "New chat"] or String.starts_with?(run.title, "New run ·"),
        do: Runs.default_title(dir),
        else: run.title

    {:ok, run} =
      Runs.update_run(run, %{
        title: title,
        settings: %{
          "workflow_id" => socket.assigns.pick.id,
          "base_spec_ids" => socket.assigns.base_ids,
          "project_dir" => if(socket.assigns.dir_ok, do: Path.expand(socket.assigns.dir))
        }
      })

    run
  end

  defp browse(browser, dir) do
    case FileBrowser.list(dir || System.user_home!(), hidden: browser.hidden) do
      {:ok, listing} -> %{browser | listing: listing, error: nil}
      {:error, reason} -> %{browser | error: reason}
    end
  end

  # The run list changes with every progress write of every run; reload it once per
  # short while rather than once per write.
  def handle_info({:runs_changed}, socket) do
    if socket.assigns[:runs_reload] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, runs_reload: Process.send_after(self(), :reload_runs, 250))}
    end
  end

  def handle_info(:reload_runs, socket),
    do: {:noreply, assign(socket, runs: Runs.list_runs(), runs_reload: nil)}

  def handle_info({:message, message}, socket) do
    # An agent's final reply replaces its live bubble.
    socket = update(socket, :streaming, &Map.delete(&1, message.meta["agent_id"]))

    socket =
      if message.author && socket.assigns.run,
        do: assign(socket, run_usage: Runs.usage(socket.assigns.run.id)),
        else: socket

    if visible?(message, socket) and not socket.assigns.history? do
      ids = socket.assigns.message_ids
      ids = if message.id in ids, do: ids, else: ids ++ [message.id]

      {:noreply,
       socket
       |> assign(
         count: min(length(ids), @message_limit),
         message_ids: Enum.take(ids, -@message_limit),
         earlier?: socket.assigns.earlier? or length(ids) > @message_limit
       )
       |> stream_insert(:messages, message, limit: -@message_limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_stream, %{agent_id: id} = chunk}, socket) do
    {:noreply, update(socket, :streaming, &Map.put(&1, id, chunk))}
  end

  # Re-render messages when the status changes so buttons like "Start run" disappear once used.
  # A new plan's tasks, too: only the latest plan offers to implement.
  def handle_info({:run_updated, run}, socket) do
    old = socket.assigns.run

    changed =
      old &&
        (old.status != run.status or
           Enum.map(old.tasks, & &1.title) != Enum.map(run.tasks, & &1.title))

    socket = assign(socket, run: run, page_title: run.title)
    {:noreply, if(changed, do: refresh_messages(socket), else: socket)}
  end

  # One agent's status or activity moved: patch it in place, without reloading the
  # workflow. The canvas follows the graph attribute; agents of other workflows are skipped.
  def handle_info({:agent_activity, agent}, socket) do
    case Agents.put_node(socket.assigns.graph, agent) do
      :unchanged ->
        {:noreply, socket}

      graph ->
        swap = fn list -> Enum.map(list, &if(&1.id == agent.id, do: agent, else: &1)) end
        focus = socket.assigns.focus

        steps =
          Enum.map(socket.assigns.steps, fn
            %{agent: %{id: id}} = step when id == agent.id -> %{step | agent: agent}
            step -> step
          end)

        {:noreply,
         assign(socket,
           graph: graph,
           agents: swap.(socket.assigns.agents),
           steps: steps,
           focus: if(focus && focus.id == agent.id, do: agent, else: focus)
         )}
    end
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
    <Layouts.app flash={@flash} usage={@usage_meter} active_runs={@active_runs} active={:chat} full>
      <div id="chat-page" phx-hook="ChatKeys" class="flex h-full flex-col bg-base-100">
        <header class="flex min-h-11 shrink-0 flex-wrap items-center gap-x-2 gap-y-1.5 px-4 pt-1.5 sm:px-6">
          <.chat_switcher runs={@runs} run={@run} />
          <.folder_button dir={@dir} ok={@dir_ok} warn={@folder_warn} locked={!settable?(@run)} />
          <.workflow_picker
            workflows={@workflows}
            workflow={@workflow}
            locked={!settable?(@run)}
          />
          <span class="mx-0.5 h-4 w-px bg-base-300" aria-hidden="true"></span>
          <button
            id="specs-button"
            type="button"
            phx-click="specs"
            title="Base specs to follow, and this run's own spec"
            class={[
              "flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[13px] transition-colors hover:bg-base-content/[0.06]",
              if(spec_count(assigns) > 0,
                do: "border-primary/40",
                else: "border-dashed border-base-300 text-base-content/65"
              )
            ]}
          >
            <.icon name="hero-document-text-mini" class="size-4 text-primary" /> Specs
            <span
              :if={spec_count(assigns) > 0}
              class="rounded-full bg-primary/15 px-1.5 text-xs tabular-nums text-primary"
            >
              {spec_count(assigns)}
            </span>
          </button>
          <button
            :if={settable?(@run)}
            id="tasks-button"
            type="button"
            phx-click="tasks"
            title="Describe it or upload a file; Kiro studies the code and specs and makes the plan"
            class={[
              "flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[13px] transition-colors hover:bg-base-content/[0.06]",
              if(@run && @run.tasks != [],
                do: "border-success/40",
                else: "border-dashed border-base-300 text-base-content/65"
              )
            ]}
          >
            <.icon name="hero-list-bullet-mini" class="size-4 text-success" /> Plan
            <span
              :if={@run && @run.tasks != []}
              class="rounded-full bg-success/15 px-1.5 text-xs tabular-nums text-success"
            >
              {length(@run.tasks)}
            </span>
          </button>
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
          <.link
            :if={@run && @run.kind}
            id="run-details"
            navigate={~p"/runs/#{@run.id}"}
            class="hidden text-sm text-base-content/50 hover:text-base-content sm:inline"
          >
            Run details
          </.link>
          <.view_switch view={@view} />
        </header>

        <.flow_strip steps={@steps} focus={@focus} run={@run} />

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
            <div :if={@earlier?} class="flex justify-center pt-4">
              <button
                id="load-earlier"
                type="button"
                phx-click="load_earlier"
                class="rounded-full border border-base-300 px-3 py-1 text-xs transition-colors hover:bg-base-content/[0.06]"
              >
                Load earlier messages
              </button>
            </div>
            <div
              id="messages"
              phx-update="stream"
              phx-hook="ChatScroll"
              data-history={to_string(@history?)}
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

          <button
            id="jump-to-latest"
            type="button"
            phx-update="ignore"
            hidden
            class="absolute bottom-40 left-1/2 z-10 -translate-x-1/2 rounded-full border border-base-300 bg-surface px-3 py-1.5 text-xs shadow-md transition-colors hover:bg-base-200"
          >
            Jump to latest <.icon name="hero-arrow-down-mini" class="ml-1 size-3" />
          </button>

          <div
            :if={@empty}
            class="flex min-h-0 flex-1 items-center justify-center overflow-hidden px-4 pb-40"
          >
            <.greeting
              focus={@focus}
              to={@to}
              dir={@dir}
              dir_ok={@dir_ok}
              workflow={@workflow}
              uploads={@uploads}
              specs={spec_count(assigns)}
              chain={for st <- @steps, st.kind != "action", do: st.name}
              last_run={last_run(@runs, @run)}
            />
          </div>

          <div class="pointer-events-none absolute inset-x-0 bottom-0 bg-linear-to-t from-base-200 from-60% to-transparent px-4 pb-4 pt-10">
            <.composer
              form={@form}
              uploads={@uploads}
              draft={@draft}
              commands={@commands}
              agents={@agents}
              focus={@focus}
              to={@to}
              run={@run}
              glow={@empty and @dir_ok and @focus == nil}
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

      <div
        :if={@browser}
        id="folder-picker"
        class="fixed inset-0 z-50 grid place-items-center bg-base-content/25 p-4 backdrop-blur-[2px]"
        role="dialog"
        aria-modal="true"
        aria-label="Choose the project folder"
        phx-window-keydown="browse_cancel"
        phx-key="Escape"
        phx-mounted={JS.push_focus(to: "#folder-button") |> JS.focus_first(to: "#folder-dialog")}
        phx-remove={JS.pop_focus()}
      >
        <div class="absolute inset-0" phx-click="browse_cancel" aria-hidden="true"></div>
        <.focus_wrap
          id="folder-dialog"
          class="relative w-full max-w-xl overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl"
        >
          <FactoryWeb.SourceParts.browser browser={@browser} />
        </.focus_wrap>
      </div>
    </Layouts.app>
    """
  end

  attr :dir, :string, required: true
  attr :ok, :boolean, required: true
  attr :warn, :boolean, required: true
  attr :locked, :boolean, required: true

  # Where the agents work: red until a folder is chosen, green once it is.
  defp folder_button(assigns) do
    ~H"""
    <button
      id="folder-button"
      type="button"
      phx-click={!@locked && "browse"}
      disabled={@locked}
      title={if @ok, do: @dir, else: "Choose the folder the agents work in"}
      class={[
        "flex max-w-64 items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-[13px] transition-colors disabled:cursor-default",
        if(@ok,
          do: "border-success/40 bg-success/[0.07] hover:border-success/70",
          else: "border-error/50 bg-error/[0.08] text-error hover:border-error"
        ),
        @warn && !@ok && "animate-pulse ring-2 ring-error/40"
      ]}
    >
      <span class={["size-2 shrink-0 rounded-full", if(@ok, do: "bg-success", else: "bg-error")]}></span>
      <.icon name="hero-folder-mini" class="size-4 shrink-0 opacity-70" />
      <span class="truncate">{if @ok, do: Path.basename(@dir), else: "Choose folder"}</span>
    </button>
    """
  end

  attr :workflows, :list, required: true
  attr :workflow, :map, required: true
  attr :locked, :boolean, required: true

  # The workflow the chat plans for: "Build a feature" unless another is picked.
  defp workflow_picker(assigns) do
    ~H"""
    <div
      :if={@locked}
      id="workflow-picker"
      aria-disabled="true"
      class="flex items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-0.5 text-[13px]"
    >
      <.icon name={FactoryWeb.RunParts.workflow_icon(@workflow, :micro)} class="size-4 text-primary" />
      <span class="max-w-48 truncate">{@workflow.name}</span>
    </div>
    <details
      :if={!@locked}
      id="workflow-picker"
      class="relative"
      phx-click-away={JS.remove_attribute("open", to: "#workflow-picker")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-1.5 rounded-full border border-base-300 px-2.5 py-0.5 text-[13px] hover:bg-base-content/[0.06]">
        <.icon
          name={FactoryWeb.RunParts.workflow_icon(@workflow, :micro)}
          class="size-4 text-primary"
        />
        <span class="max-w-48 truncate">{@workflow.name}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute left-0 z-30 mt-1 w-72 rounded-2xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <p class="px-3 pb-1 pt-1.5 text-xs text-base-content/45">Workflow</p>
        <button
          :for={w <- @workflows}
          type="button"
          phx-click={
            JS.push("pick_workflow", value: %{id: w.id})
            |> JS.remove_attribute("open", to: "#workflow-picker")
          }
          class={[
            "flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left text-sm hover:bg-base-content/[0.06]",
            w.id == @workflow.id && "bg-base-200"
          ]}
        >
          <.icon name={FactoryWeb.RunParts.workflow_icon(w, :micro)} class="size-4 text-primary" />
          <span class="flex-1 truncate">{w.name}</span>
          <.icon :if={w.id == @workflow.id} name="hero-check-mini" class="size-4" />
        </button>
      </div>
    </details>
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
          "flex items-center gap-1.5 rounded-md px-2.5 py-0.5 text-[13px] transition-colors",
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
      <summary class="flex cursor-pointer list-none items-center gap-1 rounded-full px-3 py-1 hover:bg-base-content/[0.06]">
        <span class="truncate text-[15px] font-semibold">{if @run, do: @run.title, else: "New run"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 shrink-0 opacity-50" />
      </summary>
      <div class="absolute left-0 z-30 mt-1 w-72 rounded-2xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
        <.link
          navigate={~p"/chat"}
          class="flex items-center gap-2 rounded-xl px-3 py-2 text-sm font-medium hover:bg-base-content/[0.06]"
        >
          <.icon name="hero-pencil-square-mini" class="size-4" /> New run
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

  attr :steps, :list, required: true
  attr :focus, :any, required: true
  attr :run, :any, required: true

  # The workflow drawn small and live: who's busy, what's done, where it stopped. Click
  # an agent to chat with just that agent (again to go back); "All" shows everything.
  defp flow_strip(assigns) do
    states = WorkflowMap.states(assigns.steps, assigns.run)

    assigns =
      assign(assigns, states: states, caption: caption(assigns.steps, states, assigns.run))

    ~H"""
    <nav
      id="flow-strip"
      class="flex shrink-0 items-center gap-3 border-b border-base-300 px-4 sm:px-6"
      aria-label="Workflow"
    >
      <.link
        id="agent-all"
        patch={chat_path(@run, nil)}
        class={[
          "flex shrink-0 items-center rounded-full px-3 py-1 text-sm transition-colors",
          if(@focus == nil,
            do: "bg-base-content/10 font-medium text-base-content",
            else: "text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
          )
        ]}
      >
        All
      </.link>
      <span class="h-5 w-px shrink-0 bg-base-300"></span>
      <div
        :if={@steps != []}
        class="min-w-0 flex-1 overflow-x-auto px-1.5 py-2 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        <WorkflowMap.map
          id="chat-map"
          steps={Enum.reject(@steps, &(&1.kind == "action"))}
          states={@states}
          focus={@focus && "agent-#{@focus.id}"}
          link={&agent_link(&1, @run, @focus)}
          patch
        />
      </div>
      <.link
        :if={@steps == []}
        navigate={~p"/workflows"}
        class="flex-1 py-3.5 text-sm text-base-content/55 hover:underline"
      >
        No agents yet. Add them in Workflows.
      </.link>
      <p
        :if={@caption}
        id="flow-caption"
        class="hidden max-w-sm shrink-0 items-center gap-2 text-sm text-base-content/65 lg:flex"
      >
        <span class={["size-1.5 shrink-0 rounded-full", caption_dot(elem(@caption, 0))]}></span>
        <span class="truncate">{elem(@caption, 1)}</span>
      </p>
      <button
        :if={@run && @run.status in ["queued", "running"]}
        id="pause-run"
        type="button"
        phx-click="control"
        phx-value-command="/pause"
        title="Pause after the step that's working now"
        class="btn btn-ghost btn-xs shrink-0 gap-1"
      >
        <.icon name="hero-pause-mini" class="size-4" /> Pause
      </button>
      <button
        :if={@run && @run.status == "paused"}
        id="resume-run"
        type="button"
        phx-click="control"
        phx-value-command="/resume"
        title="Go on from the step it stopped at"
        class="btn btn-xs shrink-0 gap-1"
      >
        <.icon name="hero-play-mini" class="size-4" /> Resume
      </button>
    </nav>
    """
  end

  # An agent's card opens the chat with it, or back with everyone if it's open already.
  defp agent_link(%{kind: "action"}, _run, _focus), do: nil
  defp agent_link(%{agent: nil}, _run, _focus), do: nil

  defp agent_link(%{agent: agent}, run, focus),
    do: chat_path(run, if(focus && focus.id == agent.id, do: nil, else: agent))

  # One line on where the workflow is: who's working on what, or where it stopped.
  defp caption(steps, states, run) do
    busy = Enum.find(steps, &(states[&1.id] == :busy))
    stuck = run && Enum.find(steps, &(states[&1.id] in [:error, :paused]))

    cond do
      busy ->
        {:busy, "#{busy.name}: #{(busy.agent && busy.agent.activity) || "working"}"}

      stuck && states[stuck.id] == :error ->
        {:error, "Stopped at #{stuck.name}. Fix the cause, then /resume."}

      stuck ->
        {:paused, "Paused at #{stuck.name}. /resume to go on."}

      run && run.status == "done" ->
        {:done, "Done: all #{length(steps)} steps ran."}

      run && run.status == "queued" ->
        {:queued, "Queued, starting…"}

      true ->
        nil
    end
  end

  defp caption_dot(:busy), do: "bg-primary animate-pulse"
  defp caption_dot(:error), do: "bg-error"
  defp caption_dot(:paused), do: "bg-warning"
  defp caption_dot(:done), do: "bg-success"
  defp caption_dot(_), do: "bg-base-content/30"

  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :dir, :string, default: ""
  attr :dir_ok, :boolean, default: false
  attr :workflow, :map, default: nil
  attr :uploads, :map, default: nil
  attr :specs, :integer, default: 0
  attr :chain, :list, default: []
  attr :last_run, :any, default: nil

  # A new chat: three quick steps, then describe the change and the planner plans it.
  # Set up (a folder is chosen): what the run is, in a small table you can change in
  # place, and the two ways to plan it. Left-aligned with the message box it leads to.
  defp greeting(%{focus: nil, dir_ok: true} = assigns) do
    ~H"""
    <div id="chat-ready" class="relative w-full max-w-3xl px-1">
      <p class="text-xs font-medium uppercase tracking-[0.12em] text-base-content/45">
        New run · {Calendar.strftime(Date.utc_today(), "%-d %b")}
      </p>
      <h1 class="mt-1.5 text-[28px] font-semibold leading-tight tracking-tight font-stretch-semi-condensed">
        What are we building in <span class="text-primary">{Path.basename(@dir)}</span>?
      </h1>

      <dl class="mt-6 space-y-0.5 text-sm">
        <div class="group/row -mx-2 grid grid-cols-[1.75rem_5rem_minmax(0,1fr)_auto] items-center gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-base-content/[0.03]">
          <span class="grid size-7 place-items-center rounded-md bg-success/12 text-success">
            <.icon name="hero-folder-mini" class="size-4" />
          </span>
          <dt class="text-base-content/50">Project</dt>
          <dd class="truncate font-mono text-[12.5px] text-base-content/80" title={@dir}>
            {short_dir(@dir)}
          </dd>
          <button
            type="button"
            phx-click="browse"
            class="rounded-md px-2 py-0.5 text-xs text-base-content/45 transition-colors hover:bg-base-content/[0.06] hover:text-base-content group-hover/row:text-base-content/70"
          >
            Change
          </button>
        </div>
        <div class="group/row -mx-2 grid grid-cols-[1.75rem_5rem_minmax(0,1fr)_auto] items-center gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-base-content/[0.03]">
          <span class="grid size-7 place-items-center rounded-md bg-primary/12 text-primary">
            <.icon name={FactoryWeb.RunParts.workflow_icon(@workflow, :micro)} class="size-4" />
          </span>
          <dt class="text-base-content/50">Workflow</dt>
          <dd class="min-w-0 truncate">
            {@workflow.name}
            <span :if={@chain != []} class="text-base-content/45">
              · {Enum.join(@chain, " → ")}
            </span>
          </dd>
          <button
            type="button"
            phx-click={JS.set_attribute({"open", ""}, to: "#workflow-picker")}
            class="rounded-md px-2 py-0.5 text-xs text-base-content/45 transition-colors hover:bg-base-content/[0.06] hover:text-base-content group-hover/row:text-base-content/70"
          >
            Change
          </button>
        </div>
        <div class="group/row -mx-2 grid grid-cols-[1.75rem_5rem_minmax(0,1fr)_auto] items-center gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-base-content/[0.03]">
          <span class={[
            "grid size-7 place-items-center rounded-md",
            if(@specs == 0, do: "bg-warning/12 text-warning", else: "bg-primary/12 text-primary")
          ]}>
            <.icon name="hero-document-text-mini" class="size-4" />
          </span>
          <dt class="text-base-content/50">Specs</dt>
          <dd :if={@specs == 0} class="min-w-0 truncate text-base-content/55">
            None. Agents follow only what you write; add your standards so they follow those too.
          </dd>
          <dd :if={@specs > 0} class="min-w-0 truncate">
            {@specs} attached
          </dd>
          <button
            type="button"
            phx-click="specs"
            class={[
              "text-xs hover:text-base-content",
              if(@specs == 0, do: "font-medium text-warning", else: "text-base-content/45")
            ]}
          >
            {if @specs == 0, do: "Add", else: "Change"}
          </button>
        </div>
      </dl>

      <p class="mt-6 max-w-2xl text-[15px] leading-relaxed text-base-content/65">
        Describe the change below. {if is_map(@to), do: @to.name, else: "The planner"} reads
        the code, asks about anything unclear, and lists the tasks for you to refine. Starting
        from a requirements document instead?
        <button
          id="open-plan"
          type="button"
          phx-click="tasks"
          class="font-medium text-base-content underline decoration-base-content/30 underline-offset-4 hover:decoration-base-content"
        >
          Open Plan
        </button>
      </p>

      <div :if={examples(@workflow) != []} id="examples" class="mt-5 flex flex-wrap gap-2">
        <button
          :for={ex <- examples(@workflow)}
          type="button"
          phx-click={JS.dispatch("factory:fill", to: "#chat-input", detail: %{text: ex})}
          class="rounded-full border border-base-300 px-3 py-1 text-[13px] text-base-content/70 transition-colors hover:border-primary/40 hover:bg-primary/[0.05] hover:text-base-content"
        >
          {ex}
        </button>
      </div>

      <div class="mt-8 flex flex-wrap items-center gap-3 border-t border-base-300/60 pt-4 text-xs text-base-content/50">
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
          <span><kbd class="launcher-kbd">P</kbd> Plan</span>
        </span>
      </div>
    </div>
    """
  end

  defp greeting(%{focus: nil} = assigns) do
    ~H"""
    <div id="chat-start" class="mb-8 w-full max-w-xl">
      <h1 class="text-center text-4xl font-semibold tracking-tight font-stretch-semi-condensed">
        What should we build?
      </h1>
      <p class="mt-3 text-center text-base-content/60">
        Describe the change and {if is_map(@to), do: @to.name, else: "the planner"} turns it into tasks.
        Refine them together, then implement.
      </p>

      <ol class="mt-8 space-y-2">
        <li>
          <button
            type="button"
            phx-click="browse"
            class={[
              "flex w-full items-center gap-3 rounded-2xl border px-4 py-3 text-left transition-colors",
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
        <li class="flex items-center gap-3 rounded-2xl border border-base-300/70 px-4 py-3">
          <span class="grid size-6 shrink-0 place-items-center rounded-full bg-success text-success-content">
            <.icon name="hero-check-micro" class="size-4" />
          </span>
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-medium">{@workflow && @workflow.name}</span>
            <span class="block text-xs text-base-content/55">
              The workflow. Change it at the top.
            </span>
          </span>
        </li>
        <li :if={@uploads}>
          <button
            id="add-spec"
            type="button"
            phx-click="specs"
            class="flex w-full cursor-pointer items-center gap-3 rounded-2xl border border-dashed border-base-300 px-4 py-3 text-left transition-colors hover:border-base-content/30"
          >
            <span class="grid size-6 shrink-0 place-items-center rounded-full border border-base-content/25 text-base-content/55">
              <.icon name="hero-document-plus-micro" class="size-3.5" />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block text-sm font-medium">Add a spec or requirements</span>
              <span class="block text-xs text-base-content/55">
                Optional: your base specs, or this run's own. Or just describe the change below.
              </span>
            </span>
          </button>
        </li>
      </ol>
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
      <p class="mt-3 text-base-content/60">
        Runs on Kiro with {@focus.model} in {@focus.kiro_mode} mode. {if @focus.role != "",
          do: @focus.role <> "."}
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
      <p
        :if={@message.meta["unclear"]}
        class="mb-2 inline-flex items-center gap-1.5 rounded-full bg-warning/12 px-2.5 py-0.5 text-xs font-medium text-warning"
      >
        <.icon name="hero-question-mark-circle-mini" class="size-4" />
        Not clear enough to plan yet: more information needed
      </p>
      <.agent_reply id={"md-#{@id}"} name={@message.author} body={@message.body} meta={@message.meta} />
      <p :if={@message.meta["unclear"]} class="mt-2 text-sm text-base-content/55">
        Answer below, and I'll make the tasks.
      </p>
      <.plan_card
        :if={@message.meta["tasks"] not in [nil, []]}
        id={"plan-#{@message.id}"}
        tasks={@message.meta["tasks"]}
        spec_hint={@message.meta["spec_hint"]}
        startable={
          "start" in @message.actions and startable?(@run) and
            Enum.map(@run.tasks, & &1.title) == @message.meta["tasks"]
        }
      />
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

  attr :id, :string, required: true
  attr :tasks, :list, required: true
  attr :spec_hint, :boolean, default: false
  attr :startable, :boolean, required: true

  # The planner's tasks, and the question whether to build them.
  defp plan_card(assigns) do
    ~H"""
    <div id={@id} class="task-card-active mt-3 rounded-2xl border p-4">
      <p class="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-base-content/55">
        <.icon name="hero-clipboard-document-list-mini" class="size-4 text-primary" />
        Created {length(@tasks)} {if length(@tasks) == 1, do: "task", else: "tasks"}
      </p>
      <ol class="mt-3 space-y-1.5">
        <li :for={{title, i} <- Enum.with_index(@tasks, 1)} class="flex gap-3 text-sm">
          <span class="w-5 shrink-0 text-right tabular-nums text-base-content/45">{i}.</span>
          <span>{title}</span>
        </li>
      </ol>
      <p
        :if={@spec_hint && @startable}
        class="mt-3 flex items-center gap-2 text-xs text-base-content/55"
      >
        <.icon name="hero-document-plus-mini" class="size-4" />
        Have a spec or requirements? Add them in Specs above and I'll plan again. Or go on without.
      </p>
      <div
        :if={@startable}
        class="mt-4 flex flex-wrap items-center gap-3 border-t border-base-content/10 pt-4"
      >
        <span class="mr-auto text-sm font-medium">Do you want to implement these changes?</span>
        <button
          type="button"
          phx-click={JS.focus(to: "#chat-input")}
          class="btn btn-ghost btn-sm"
        >
          Keep refining
        </button>
        <button
          id={"implement-#{@id}"}
          type="button"
          phx-click="action"
          phx-value-action="start"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-play-mini" class="size-4" /> Yes, implement
        </button>
      </div>
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

  attr :agent, :any, required: true

  # How full the addressed agent's Kiro context is, and a button to compact it. Shown
  # while its session runs, or right after a compaction until the next reply.
  defp context_chip(%{agent: %{usage: usage}} = assigns) when is_map(usage) do
    pct = usage["context_pct"]
    assigns = assign(assigns, pct: pct, usage: usage, level: FactoryWeb.Usage.level(pct))

    ~H"""
    <div
      :if={@pct || @usage["compacted_from"]}
      id="context-chip"
      class={[
        "ctx-chip flex h-8 items-center overflow-hidden rounded-full border text-xs tabular-nums",
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

  attr :form, :any, required: true
  attr :uploads, :map, required: true
  attr :draft, :string, required: true
  attr :commands, :list, required: true
  attr :agents, :list, required: true
  attr :focus, :any, required: true
  attr :to, :any, default: nil
  attr :run, :any, required: true
  attr :glow, :boolean, default: false

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

      <div class={[
        "composer-box rounded-[26px] border border-base-content/15 shadow-[0_1px_2px_rgb(0_0_0/0.06),0_8px_28px_-8px_rgb(0_0_0/0.28)] transition-[border-color,box-shadow] focus-within:border-base-content/30 focus-within:shadow-[0_1px_2px_rgb(0_0_0/0.06),0_10px_32px_-8px_rgb(0_0_0/0.36)]",
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
          placeholder={placeholder(recipient(@focus, @to), @run)}
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

          <.recipient_picker agents={@agents} focus={@focus} to={@to} run={@run} />
          <.context_chip agent={recipient(@focus, @to)} />

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
        if(@current, do: "bg-primary/10 text-base-content", else: "text-base-content/70")
      ]}>
        <.icon
          name={if @current, do: FactoryWeb.RunParts.kind_icon(@current.kind), else: "hero-bolt-mini"}
          class={["size-4", @current && "text-primary"]}
        />
        <span class="max-w-40 truncate">{if @current, do: @current.name, else: "Factory"}</span>
        <.icon name="hero-chevron-down-mini" class="size-4 opacity-50" />
      </summary>
      <div class="absolute bottom-full left-0 z-30 mb-2 w-72 rounded-2xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
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

  defp upload_error(:too_large), do: "larger than 2 MB"
  defp upload_error(:not_accepted), do: "only .md and .txt files"
  defp upload_error(:too_many_files), do: "up to 5 files at a time"
  defp upload_error(err), do: to_string(err)

  defp short_dir(dir) do
    home = System.user_home!()
    if String.starts_with?(dir, home), do: "~" <> String.replace_prefix(dir, home, ""), else: dir
  end

  # Starting points for the message box, by the kind of job the workflow does.
  @examples %{
    "feature" => [
      "Add a dark mode toggle to the settings page",
      "Let users export the list as CSV",
      "Add search with filters to the main list"
    ],
    "bug" => [
      "Saving the form logs the user out",
      "The page crashes when the list is empty",
      "Dates show in the wrong time zone"
    ],
    "issue" => [
      "Resolve this issue: (paste the link or the text)",
      "Triage the open issue about slow page loads"
    ],
    "deps" => [
      "Update all dependencies to their latest minor versions",
      "Upgrade the framework to its newest major version",
      "Fix the security advisories in our dependencies"
    ]
  }

  defp examples(workflow), do: Map.get(@examples, Workflows.kind(workflow), [])

  # The run worked on last, other than this one: one that has started or has tasks.
  defp last_run(runs, current) do
    Enum.find(runs, fn r ->
      (current == nil or r.id != current.id) and (r.status != "draft" or r.tasks != [])
    end)
  end
end
