defmodule FactoryWeb.WorkflowsLive do
  @moduledoc """
  The workflows: pick one, then arrange its agents and hand-offs on the canvas.
  Standard workflows (one per job on the start screen) can be changed and restored;
  custom ones can be made new or cloned, renamed and deleted.
  URLs: /workflows (the current one), /workflows/:workflow_id, …/agents/:id.
  """
  use FactoryWeb, :live_view
  import FactoryWeb.RunParts, only: [type_icon: 2]
  alias Factory.{Actions, Agents, FileBrowser, Kiro, Sources, Workflows}
  alias Factory.Agents.{Agent, Workflow}

  # Model and mode are switched per message, and prompt edits are re-sent, so only these
  # need a fresh session: its folder, or which session the agent talks in.
  @restart_fields [:session]

  def mount(_params, _session, socket) do
    if connected?(socket), do: Agents.subscribe()

    {:ok,
     assign(socket,
       page_title: "Workflows",
       workflow: nil,
       workflows: [],
       graph: nil,
       selected: nil,
       form: nil,
       editing_context: false,
       naming: nil,
       sources: [],
       sources_view: nil,
       source_kind: nil,
       source_form: nil,
       editing_source: nil,
       # Where the source form goes after Save or Back: the list it came from, or
       # nil to close (opened from its card on the canvas, or to add a source).
       source_return: nil,
       # The arrow whose hand-off prompt is being edited: %{link:, from:, to:}.
       link_prompt: nil,
       browser: nil,
       source_agents: [],
       attached: MapSet.new(),
       action_result: nil,
       running_actions: MapSet.new(),
       action_draft: nil,
       new_action_id: nil,
       # The window choosing the base specs this workflow's runs start with.
       base_window: false,
       base_specs: []
     )
     |> allow_upload(:source_file,
       accept: ~w(.md .markdown .txt),
       max_entries: 1,
       max_file_size: 1_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  # Another tab changed the graph. Close the panel if its agent was deleted there,
  # and leave a workflow that was deleted there.
  # An action run from its panel finished.
  def handle_info({:action_result, id, result}, socket) do
    socket = update(socket, :running_actions, &MapSet.delete(&1, id))

    if socket.assigns.selected && socket.assigns.selected.id == id,
      do: {:noreply, socket |> assign(action_result: result) |> refresh()},
      else: {:noreply, refresh(socket)}
  end

  # An agent's status or usage moved: patch its card in place, without reloading the
  # workflow (the canvas follows the graph attribute). Other workflows' agents are skipped.
  def handle_info({:agent_activity, agent}, socket) do
    case socket.assigns.graph && Agents.put_node(socket.assigns.graph, agent) do
      graph when is_map(graph) ->
        selected = socket.assigns.selected

        {:noreply,
         assign(socket,
           graph: graph,
           selected: if(selected && selected.id == agent.id, do: agent, else: selected)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:graph_changed}, socket) do
    socket = assign(socket, workflows: Workflows.list())

    socket =
      if socket.assigns.workflow,
        do: assign(socket, sources: Sources.list(socket.assigns.workflow.id)),
        else: socket

    if socket.assigns.workflow && !Workflows.get(socket.assigns.workflow.id) do
      {:noreply, push_navigate(socket, to: ~p"/workflows")}
    else
      graph_changed(socket)
    end
  end

  defp graph_changed(socket) do
    case socket.assigns.selected && Agents.get_agent(socket.assigns.selected.id) do
      nil when socket.assigns.selected != nil ->
        {:noreply,
         socket |> refresh() |> push_patch(to: ~p"/workflows/#{socket.assigns.workflow.id}")}

      _ ->
        {:noreply, refresh(socket)}
    end
  end

  # The workflow picked here is the one picked everywhere: the chat plans with it too.
  def handle_params(params, uri, socket) do
    workflow =
      case params["workflow_id"] do
        nil -> Workflows.picked()
        id -> Workflows.get(id)
      end

    workflow =
      if workflow && !workflow.current,
        do: elem(Workflows.set_current(workflow), 1),
        else: workflow

    if workflow do
      socket
      |> open_workflow(workflow)
      |> open_sources(params)
      |> agent_params(params, uri)
    else
      {:noreply,
       socket
       |> put_flash(:error, "That workflow doesn't exist.")
       |> push_navigate(to: ~p"/workflows")}
    end
  end

  # ?sources opens the data sources window, e.g. from a link.
  defp open_sources(socket, %{"sources" => _}),
    do: assign(socket, sources_view: if(socket.assigns.sources == [], do: :pick, else: :list))

  defp open_sources(socket, _params), do: socket

  # A different workflow gets a fresh canvas (its element id changes with it).
  defp open_workflow(socket, workflow) do
    if socket.assigns.workflow && socket.assigns.workflow.id == workflow.id do
      assign(socket, workflow: workflow)
    else
      assign(socket,
        workflow: workflow,
        workflows: Workflows.list(),
        sources: Sources.list(workflow.id),
        sources_view: nil,
        graph: canvas_graph(workflow.id, nil, Sources.list(workflow.id)),
        page_title: workflow.name,
        selected: nil,
        naming: nil
      )
    end
  end

  defp agent_params(socket, %{"id" => id} = params, _uri) do
    case Agents.get_agent(id) do
      %Agent{workflow_id: wid} = agent when wid == socket.assigns.workflow.id ->
        # ?prompt opens the editor for the agent's prompt.
        editing = Map.has_key?(params, "prompt")
        context_form = to_form(%{"prompt" => agent.prompt}, as: :context)

        {:noreply,
         socket |> select(agent) |> assign(editing_context: editing, context_form: context_form)}

      _ ->
        {:noreply, push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}")}
    end
  end

  defp agent_params(socket, _params, _uri) do
    {:noreply,
     socket
     |> discard_new_action(nil)
     |> assign(selected: nil, form: nil, editing_context: false)
     |> push_event("flow:select", %{id: nil})}
  end

  # Events from the Svelte Flow canvas

  def handle_event("select", %{"id" => id}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/agents/#{id}")}

  def handle_event("deselect", _, socket) do
    {:noreply,
     if(socket.assigns.selected,
       do: push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}"),
       else: socket
     )}
  end

  def handle_event("move", %{"nodes" => positions}, socket) do
    Agents.move_agents(positions)

    {:noreply,
     assign(socket,
       graph: canvas_graph(socket.assigns.workflow.id, nil, socket.assigns.sources)
     )}
  end

  def handle_event("connect", %{"source" => source, "target" => target} = params, socket) do
    Agents.link(int(source), int(target), handles(params))
    {:noreply, refresh(socket)}
  end

  # Action cards (commit, open a PR, email…): added from the palette on the right,
  # set up in their own side panel, tried with a dry run or run for real.

  # A new action is a draft until Add; Cancel (or leaving it) removes it. Changes to
  # an existing action are kept in `action_draft` until Save.
  def handle_event("add_action", %{"type" => type, "x" => x, "y" => y}, socket) do
    socket = discard_new_action(socket, nil)

    case Actions.get(type) && Agents.add_action(socket.assigns.workflow.id, type, x / 1, y / 1) do
      {:ok, card} ->
        {:noreply,
         socket |> assign(new_action_id: card.id) |> refresh() |> push_patch(to: agent_path(card))}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't add the action. Try again.")}
    end
  end

  def handle_event("action_change", %{"action" => params}, socket),
    do: {:noreply, assign(socket, action_draft: draft(socket.assigns.selected, params))}

  def handle_event("action_save", params, socket) do
    card = socket.assigns.selected
    draft = draft(card, params["action"] || %{}, socket.assigns.action_draft)
    new? = socket.assigns.new_action_id == card.id

    case Agents.update_agent(card, %{name: draft.name, action: draft.action}) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(selected: card, action_draft: nil, new_action_id: nil)
         |> put_flash(
           :info,
           if(new?,
             do: "Added “#{card.name}”. Draw an arrow from the agent it follows.",
             else: "Saved “#{card.name}”."
           )
         )
         |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Names can't be empty or over 40 characters.")}
    end
  end

  def handle_event("action_cancel", _, socket) do
    socket = assign(socket, action_draft: nil, action_result: nil)
    {:noreply, push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}")}
  end

  def handle_event(event, _, socket) when event in ["action_plan", "action_run"] do
    card = socket.assigns.action_draft || socket.assigns.selected

    cond do
      is_nil(card) or card.kind != "action" -> {:noreply, socket}
      MapSet.member?(socket.assigns.running_actions, card.id) -> {:noreply, socket}
      event == "action_plan" -> plan_action(socket, card)
      true -> run_action(socket, card)
    end
  end

  # Data source cards: an arrow from one to an agent attaches it; deleting the arrow
  # (or the card) undoes that. Card ids on the canvas are "source-ID".

  def handle_event("attach_source", %{"source" => sid, "agent" => aid}, socket) do
    with %Sources.Source{} = source <- Sources.get(source_id(sid)) do
      case Sources.attach(source, int(aid)) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    end

    {:noreply, socket |> reload_sources() |> refresh()}
  end

  def handle_event("detach_source", %{"source" => sid, "agent" => aid}, socket) do
    if source = Sources.get(source_id(sid)), do: Sources.detach(source, int(aid))
    {:noreply, socket |> reload_sources() |> refresh()}
  end

  def handle_event("move_sources", %{"nodes" => positions}, socket) do
    positions
    |> Enum.map(&Map.update!(&1, "id", fn id -> source_id(id) end))
    |> Sources.move()

    {:noreply, reload_sources(socket)}
  end

  def handle_event("delete_sources", %{"ids" => ids}, socket) do
    for id <- ids, source = Sources.get(source_id(id)), do: Sources.delete(source)
    {:noreply, socket |> reload_sources() |> refresh()}
  end

  def handle_event("reconnect", %{"old" => old, "new" => new}, socket) do
    with {:ok, old_pair} <- connection_ids(old),
         {:ok, new_pair} <- connection_ids(new),
         ids = Tuple.to_list(old_pair) ++ Tuple.to_list(new_pair),
         true <- Enum.all?(ids, &workflow_agent?(socket, &1)) do
      Agents.relink(old_pair, new_pair, handles(new))
    end

    {:noreply, refresh(socket)}
  end

  def handle_event("reconnect", _, socket), do: {:noreply, socket}

  def handle_event("delete", %{"nodes" => nodes, "edges" => edges}, socket) do
    for %{"source" => s, "target" => t} <- edges, do: Agents.unlink(int(s), int(t))
    ids = Enum.map(nodes, &int/1)
    Enum.each(ids, &Kiro.stop/1)
    Agents.delete_agents(ids)
    {:noreply, socket |> refresh() |> close_if_deleted(ids)}
  end

  def handle_event("add_agent", %{"x" => x, "y" => y} = params, socket) do
    opts = [from: params["from"] && int(params["from"]), to: params["to"] && int(params["to"])]

    case Agents.add_agent(socket.assigns.workflow.id, x, y, opts) do
      {:ok, agent} ->
        {:noreply, socket |> refresh() |> push_patch(to: agent_path(agent))}

      {:error, _} ->
        {:noreply, socket |> refresh() |> put_flash(:error, "Couldn't add the agent. Try again.")}
    end
  end

  # Workflows: pick, make, rename, clone, restore, delete, use in chat

  def handle_event("wf_naming", %{"what" => what}, socket),
    do: {:noreply, assign(socket, naming: if(what == "", do: nil, else: what))}

  def handle_event("wf_create", %{"name" => name}, socket) do
    case Workflows.create(name) do
      {:ok, w} ->
        {:noreply,
         socket
         |> put_flash(:info, "Made “#{w.name}”. Add agents with Add agent.")
         |> push_patch(to: ~p"/workflows/#{w.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Give the workflow a name.")}
    end
  end

  def handle_event("wf_rename", %{"name" => name}, socket) do
    case Workflows.rename(socket.assigns.workflow, name) do
      {:ok, w} ->
        {:noreply,
         assign(socket, workflow: w, workflows: Workflows.list(), naming: nil, page_title: w.name)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Names can't be empty or over 60 characters.")}
    end
  end

  # Base specs: the ones this workflow's runs start with.

  def handle_event("wf_base_specs", _, socket),
    do: {:noreply, assign(socket, base_window: true, base_specs: Factory.Specs.list_base_specs())}

  def handle_event("wf_base_close", _, socket), do: {:noreply, assign(socket, base_window: false)}

  def handle_event("wf_toggle_base", %{"id" => id}, socket) do
    id = String.to_integer(id)
    w = socket.assigns.workflow

    ids =
      if id in w.base_spec_ids,
        do: List.delete(w.base_spec_ids, id),
        else: w.base_spec_ids ++ [id]

    {:ok, w} = Workflows.set_base_specs(w, ids)
    {:noreply, assign(socket, workflow: w)}
  end

  def handle_event("wf_clone", _, socket) do
    {:ok, copy} = Workflows.clone(socket.assigns.workflow)

    {:noreply,
     socket
     |> put_flash(:info, "Cloned as “#{copy.name}”.")
     |> push_patch(to: ~p"/workflows/#{copy.id}")}
  end

  def handle_event("wf_restore", _, socket) do
    case Workflows.restore(socket.assigns.workflow) do
      {:ok, w} ->
        {:noreply,
         socket
         |> assign(workflow: w, workflows: Workflows.list(), selected: nil, page_title: w.name)
         |> refresh()
         |> put_flash(:info, "Restored “#{w.name}” to its default.")
         |> push_patch(to: ~p"/workflows/#{w.id}")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("wf_delete", _, socket) do
    case Workflows.delete(socket.assigns.workflow) do
      {:ok, w} ->
        {:noreply,
         socket |> put_flash(:info, "Deleted “#{w.name}”.") |> push_navigate(to: ~p"/workflows")}

      {:error, :in_use} ->
        {:noreply,
         put_flash(socket, :error, "Runs still use this workflow. Finish or cancel them first.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Standard workflows can be restored, not deleted.")}
    end
  end

  # An arrow's hand-off prompt: said to the receiving agent when work passes along it.
  # Canvas edge ids are "lID".

  def handle_event("link_prompt_edit", %{"id" => "l" <> id}, socket) do
    with %{} = link <- Agents.get_link(String.to_integer(id)),
         %{} = from <- Agents.get_agent(link.source_id),
         %{} = to <- Agents.get_agent(link.target_id),
         true <- from.workflow_id == socket.assigns.workflow.id do
      {:noreply, assign(socket, link_prompt: %{link: link, from: from, to: to})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("link_prompt_save", %{"prompt" => prompt}, socket),
    do: save_link_prompt(socket, prompt)

  def handle_event("link_prompt_remove", _, socket), do: save_link_prompt(socket, "")

  def handle_event("link_prompt_close", _, socket),
    do: {:noreply, assign(socket, link_prompt: nil)}

  # Data sources: the window lists them, offers the kinds to add, and edits one.

  def handle_event("sources_open", params, socket) do
    view = if params["add"] || socket.assigns.sources == [], do: :pick, else: :list
    {:noreply, assign(socket, sources_view: view)}
  end

  def handle_event("sources_close", _, socket),
    do: {:noreply, assign(socket, sources_view: nil, browser: nil)}

  def handle_event("source_view", %{"view" => view}, socket) when view in ["list", "pick"],
    do:
      {:noreply, assign(socket, sources_view: String.to_existing_atom(view), editing_source: nil)}

  def handle_event("source_pick", %{"kind" => kind}, socket) do
    form = Sources.change(%Sources.Source{kind: kind}) |> to_form(as: :source)

    {:noreply,
     assign(socket,
       sources_view: :form,
       source_return: if(socket.assigns.sources_view == :list, do: :list),
       source_kind: kind,
       source_form: form,
       editing_source: nil,
       source_agents: Agents.list_agents(socket.assigns.workflow.id),
       attached: MapSet.new()
     )}
  end

  def handle_event("source_edit", %{"id" => id}, socket) do
    source = Sources.get(id)
    form = source |> Sources.change() |> to_form(as: :source)

    {:noreply,
     assign(socket,
       sources_view: :form,
       source_return: if(socket.assigns.sources_view == :list, do: :list),
       source_kind: source.kind,
       source_form: form,
       editing_source: source,
       source_agents: Agents.list_agents(socket.assigns.workflow.id),
       attached: MapSet.new(Sources.agent_ids(source))
     )}
  end

  def handle_event("source_validate", %{"source" => params}, socket) do
    base = socket.assigns.editing_source || %Sources.Source{kind: socket.assigns.source_kind}

    form =
      base
      |> Sources.change(source_attrs(socket, params))
      |> Map.put(:action, :validate)
      |> to_form(as: :source)

    # Ticks only come with the form itself (not with a browsed path or an upload).
    attached =
      if Map.has_key?(params, "agents"),
        do: MapSet.new(agent_ticks(params)),
        else: socket.assigns.attached

    {:noreply, assign(socket, source_form: form, attached: attached)}
  end

  def handle_event("source_save", %{"source" => params}, socket) do
    attrs = source_attrs(socket, params)

    result =
      case socket.assigns.editing_source do
        # New sources start unattached; arrows attach them.
        nil -> Sources.create(socket.assigns.workflow.id, Map.delete(attrs, "agents"))
        source -> Sources.update(source, attrs)
      end

    case result do
      {:ok, source} ->
        {:noreply,
         socket
         |> assign(
           sources: Sources.list(socket.assigns.workflow.id),
           sources_view: socket.assigns.source_return,
           editing_source: nil
         )
         |> refresh()
         |> put_flash(
           :info,
           if(socket.assigns.editing_source,
             do: "Saved #{source.name}.",
             else: "#{source.name} is a data source of #{socket.assigns.workflow.name}."
           )
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, source_form: to_form(changeset, as: :source))}
    end
  end

  # Back from the form: to where it was opened from, or the kinds when adding.
  def handle_event("source_back", _, socket) do
    view =
      cond do
        socket.assigns.source_return -> socket.assigns.source_return
        socket.assigns.editing_source -> nil
        true -> :pick
      end

    {:noreply, assign(socket, sources_view: view, editing_source: nil)}
  end

  def handle_event("source_toggle", %{"id" => id}, socket) do
    if s = Sources.get(id), do: Sources.toggle(s)
    {:noreply, socket |> assign(sources: Sources.list(socket.assigns.workflow.id)) |> refresh()}
  end

  def handle_event("source_sync", %{"id" => id}, socket) do
    if s = Sources.get(id), do: Sources.sync(s)
    {:noreply, socket |> assign(sources: Sources.list(socket.assigns.workflow.id)) |> refresh()}
  end

  def handle_event("source_delete", %{"id" => id}, socket) do
    if s = Sources.get(id), do: Sources.delete(s)
    sources = Sources.list(socket.assigns.workflow.id)

    {:noreply,
     socket
     |> assign(sources: sources, sources_view: if(sources == [], do: :pick, else: :list))
     |> refresh()}
  end

  # The folder browser: picking a path for a source's folder or file field.

  def handle_event("browse_open", %{"field" => field, "mode" => mode}, socket)
      when mode in ["dir", "file", "json", "any"] do
    current = form_params(socket.assigns.source_form)["config"][field]
    browser = %{field: field, mode: mode, hidden: false, listing: nil, error: nil}
    {:noreply, assign(socket, browser: browse(browser, FileBrowser.start_dir(current)))}
  end

  def handle_event("browse_go", %{"path" => path}, socket),
    do: {:noreply, update(socket, :browser, &browse(&1, path))}

  def handle_event("browse_hidden", _, socket) do
    browser = %{socket.assigns.browser | hidden: !socket.assigns.browser.hidden}
    {:noreply, assign(socket, browser: browse(browser, browser.listing && browser.listing.dir))}
  end

  def handle_event("browse_cancel", _, socket), do: {:noreply, assign(socket, browser: nil)}

  # The chosen path fills the field; a source without a name is named after it.
  def handle_event("browse_pick", %{"path" => path}, socket) do
    %{field: field} = socket.assigns.browser
    params = form_params(socket.assigns.source_form)
    params = put_in(params, ["config", field], path)

    params =
      if String.trim(params["name"] || "") == "" and field == "path",
        do: Map.put(params, "name", path |> Path.basename() |> Path.rootname()),
        else: params

    socket = assign(socket, browser: nil)
    handle_event("source_validate", %{"source" => params}, socket)
  end

  # Events from the side panel

  def handle_event("save", %{"agent" => params}, socket) do
    old = socket.assigns.selected

    case Agents.update_agent(old, params) do
      {:ok, agent} ->
        # Its own session was started in the old folder (or it now talks elsewhere).
        if Map.take(old, @restart_fields) != Map.take(agent, @restart_fields),
          do: Kiro.stop(old.id)

        if agent.prompt != old.prompt, do: Kiro.forget(agent)

        {:noreply,
         socket |> assign(selected: agent, form: to_form(Agents.change_agent(agent))) |> refresh()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
    end
  end

  # Role picked from the menu on an agent card's icon.
  def handle_event("kind", %{"id" => id, "kind" => kind}, socket) do
    with %Agent{} = agent <- Agents.get_agent(id),
         {:ok, _} <- Agents.update_agent(agent, %{kind: kind}) do
      socket = refresh(socket)

      # Keep the side panel's form in step if it shows this agent.
      socket =
        if socket.assigns.selected && socket.assigns.selected.id == agent.id,
          do: assign(socket, form: to_form(Agents.change_agent(socket.assigns.selected))),
          else: socket

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  # The context button on an agent card.
  def handle_event("context", %{"id" => id}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}/agents/#{id}?prompt")}

  # Keeps the character count current while typing.
  def handle_event("context_change", %{"context" => params}, socket),
    do: {:noreply, assign(socket, context_form: to_form(params, as: :context))}

  def handle_event("save_context", %{"context" => %{"prompt" => prompt}}, socket) do
    old = socket.assigns.selected

    case Agents.update_agent(old, %{prompt: prompt}) do
      {:ok, agent} ->
        # The session already has the old prompt; send the new one with the next message.
        if agent.prompt != old.prompt, do: Kiro.forget(agent)

        {:noreply,
         socket
         |> put_flash(:info, "Saved #{agent.name}'s prompt.")
         |> refresh()
         |> push_patch(to: agent_path(agent))}

      {:error, changeset} ->
        {:noreply,
         assign(socket, context_form: to_form(changeset, as: :context, action: :validate))}
    end
  end

  # The red compact button on an agent's context bar, or in its side panel.
  def handle_event("compact", %{"id" => id}, socket) do
    agent = Agents.get_agent(id)

    message =
      case agent && Kiro.compact(agent) do
        :ok ->
          {:info,
           "Compacted #{agent.name}'s conversation. Its next message starts a fresh Kiro session with the summary; the new size shows after the reply."}

        {:error, :no_gain} ->
          {:info, "#{agent.name}'s conversation is already small: compacting wouldn't save room."}

        {:error, :busy} ->
          {:error, "#{agent.name} is answering right now. Compact when it's idle."}

        {:error, :starting} ->
          {:error, "Kiro is still starting. Try again in a moment."}

        _ ->
          {:error, "Nothing to compact: #{agent && agent.name} has no Kiro session running."}
      end

    {:noreply, put_flash(socket, elem(message, 0), elem(message, 1))}
  end

  # Stops the session this agent talks in: its own, or the shared one.
  def handle_event("stop_kiro", _, socket) do
    Kiro.stop(Kiro.session_key(socket.assigns.selected))
    {:noreply, refresh(socket)}
  end

  def handle_event("delete_agent", _, socket) do
    Kiro.stop(socket.assigns.selected.id)
    Agents.delete_agents([socket.assigns.selected.id])

    {:noreply,
     socket |> refresh() |> push_patch(to: ~p"/workflows/#{socket.assigns.workflow.id}")}
  end

  # "Chat" on an agent card opens the chat with just that agent.
  def handle_event("chat", %{"id" => id}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/chat?#{[agent: id]}")}

  def handle_event("close", _, socket),
    do: {:noreply, push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}")}

  defp browse(browser, dir) do
    case FileBrowser.list(dir || System.user_home!(),
           files: browser.mode != "dir",
           ext:
             case browser.mode do
               "json" -> [".json"]
               "any" -> :any
               _ -> nil
             end,
           hidden: browser.hidden
         ) do
      {:ok, listing} -> %{browser | listing: listing, error: nil}
      {:error, reason} -> %{browser | error: reason}
    end
  end

  # What the source form holds now, typed or not.
  defp form_params(form) do
    %{
      "name" => form[:name].value || "",
      "content" => form[:content].value || "",
      "config" => form[:config].value || %{}
    }
    |> Map.merge(form.params || %{})
    |> Map.update("config", %{}, &(&1 || %{}))
  end

  # The kind comes from the window, not the form; config keeps only filled-in keys.
  defp source_attrs(socket, params) do
    config =
      (params["config"] || %{})
      |> Enum.map(fn {k, v} -> {k, String.trim(v)} end)
      |> Enum.reject(fn {_, v} -> v == "" end)
      |> Map.new()

    %{
      "kind" => socket.assigns.source_kind,
      "name" => params["name"] || "",
      "content" => params["content"] || "",
      "config" => config,
      "agents" =>
        if(Map.has_key?(params, "agents"),
          do: agent_ticks(params),
          else: MapSet.to_list(socket.assigns.attached)
        )
    }
  end

  defp agent_ticks(params),
    do:
      params
      |> Map.get("agents", [])
      |> List.wrap()
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&int/1)

  # An uploaded file fills the text box, and names the source if it has no name yet.
  defp handle_progress(:source_file, entry, socket) do
    if entry.done? do
      text =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      if String.valid?(text) do
        form = socket.assigns.source_form
        params = form.params || %{}
        name = params["name"] || form[:name].value || ""
        name = if String.trim(name) == "", do: Path.rootname(entry.client_name), else: name

        params =
          params
          |> Map.put("content", text)
          |> Map.put("name", name)
          |> Map.put_new("config", form[:config].value || %{})

        handle_event("source_validate", %{"source" => params}, socket)
      else
        {:noreply, put_flash(socket, :error, "#{entry.client_name} isn't a text file.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp plan_action(socket, card) do
    result =
      case Actions.plan(card) do
        {:ok, lines} -> {:plan, lines}
        error -> error
      end

    {:noreply, assign(socket, action_result: result)}
  end

  defp run_action(socket, card) do
    lv = self()
    Agents.set_activity(card.id, "running", "Running")

    Task.Supervisor.start_child(Factory.TaskSupervisor, fn ->
      result = Actions.run(card)

      {status, text} =
        if match?({:ok, _}, result), do: {"done", "Done"}, else: {"error", elem(result, 1)}

      Agents.set_activity(card.id, status, String.slice(text, 0, 200))
      send(lv, {:action_result, card.id, result})
    end)

    {:noreply,
     socket
     |> update(:running_actions, &MapSet.put(&1, card.id))
     |> assign(action_result: :running)}
  end

  # The card with the form's unsaved values (name and settings).
  defp draft(card, params, base \\ nil) do
    base = base || card
    config = Map.merge(base.action["config"] || %{}, params["config"] || %{})
    name = params["name"] || base.name
    %{base | name: name, action: Map.put(base.action, "config", config)}
  end

  # A new action that was never added (Add) goes when you leave it.
  defp discard_new_action(%{assigns: %{new_action_id: id}} = socket, keep)
       when not is_nil(id) and id != keep do
    Agents.delete_agents([id])
    socket |> assign(new_action_id: nil, action_draft: nil) |> refresh()
  end

  defp discard_new_action(socket, _keep), do: socket

  defp select(socket, agent) do
    socket = discard_new_action(socket, agent.id)

    socket
    |> assign(
      action_result:
        if(socket.assigns.selected && socket.assigns.selected.id == agent.id,
          do: socket.assigns.action_result
        ),
      action_draft:
        if(socket.assigns.selected && socket.assigns.selected.id == agent.id,
          do: socket.assigns.action_draft
        ),
      selected: agent,
      form: to_form(Agents.change_agent(agent)),
      neighbours: Agents.neighbours(agent.id)
    )
    |> push_event("flow:select", %{id: to_string(agent.id)})
  end

  # The agents and arrows, plus the workflow's data sources for the card beside them.
  defp canvas_graph(workflow_id, selected_id, sources) do
    workflow_id
    |> Agents.graph(selected_id)
    |> Map.put(
      :sources,
      for s <- sources do
        %{
          id: to_string(s.id),
          name: s.name,
          kind: s.kind,
          label: Sources.label(s.kind),
          status: s.status,
          enabled: s.enabled,
          detail: FactoryWeb.SourceParts.detail(s),
          x: s.x,
          y: s.y
        }
      end
    )
    |> Map.put(
      :action_types,
      Enum.map(Actions.types(), &Map.take(&1, [:type, :label, :group, :blurb]))
    )
    |> Map.put(
      :source_links,
      for {sid, aid} <- Sources.links(workflow_id) do
        %{source: "source-#{sid}", target: to_string(aid)}
      end
    )
  end

  defp source_id("source-" <> id), do: String.to_integer(id)
  defp source_id(id), do: int(id)

  defp connection_ids(%{"source" => source, "target" => target}) do
    with {:ok, source} <- node_id(source),
         {:ok, target} <- node_id(target),
         true <- source != target do
      {:ok, {source, target}}
    else
      _ -> :error
    end
  end

  defp connection_ids(_), do: :error

  defp node_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp node_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> node_id(id)
      _ -> :error
    end
  end

  defp node_id(_), do: :error

  defp workflow_agent?(socket, id) do
    case Agents.get_agent(id) do
      %Agent{workflow_id: workflow_id} -> workflow_id == socket.assigns.workflow.id
      _ -> false
    end
  end

  defp reload_sources(socket),
    do: assign(socket, sources: Sources.list(socket.assigns.workflow.id))

  defp agent_path(%Agent{workflow_id: wid, id: id}), do: ~p"/workflows/#{wid}/agents/#{id}"

  # Sends the saved graph back to the canvas so it always matches the database.
  defp refresh(socket) do
    graph =
      canvas_graph(
        socket.assigns.workflow.id,
        socket.assigns.selected && socket.assigns.selected.id,
        socket.assigns.sources
      )

    socket = socket |> assign(graph: graph) |> push_event("flow:graph", graph)

    if agent = socket.assigns.selected && Agents.get_agent(socket.assigns.selected.id),
      do: assign(socket, selected: agent, neighbours: Agents.neighbours(agent.id)),
      else: socket
  end

  defp close_if_deleted(%{assigns: %{selected: %Agent{id: id}}} = socket, ids) do
    if id in ids,
      do: push_patch(socket, to: ~p"/workflows/#{socket.assigns.workflow.id}"),
      else: socket
  end

  defp close_if_deleted(socket, _ids), do: socket

  # Circle names from the canvas ("top", "right", ...); anything else means "facing sides".
  defp handles(params) do
    %{source: side(params["sourceHandle"]), target: side(params["targetHandle"])}
  end

  defp side(s) when s in ~w(top right bottom left), do: s
  defp side(_), do: nil

  defp int(id) when is_integer(id), do: id
  defp int(id) when is_binary(id), do: String.to_integer(id)

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      usage={@usage_meter}
      active_runs={@active_runs}
      active={:workflows}
      full
    >
      <div class="flex h-full flex-col">
        <.workflow_bar
          workflow={@workflow}
          workflows={@workflows}
          naming={@naming}
          sources={@sources}
        />
        <FactoryWeb.SourceParts.window
          :if={@sources_view}
          workflow={@workflow}
          sources={@sources}
          view={@sources_view}
          kind={@source_kind}
          form={@source_form}
          editing={@editing_source}
          upload={@uploads.source_file}
          browser={@browser}
          agents={@source_agents}
          attached={@attached}
        />
        <.link_prompt_window :if={@link_prompt} {@link_prompt} />
        <div
          :if={@base_window}
          id="workflow-base-specs"
          class="fixed inset-0 z-50 grid place-items-center bg-base-content/25 p-4 backdrop-blur-[2px]"
          role="dialog"
          aria-modal="true"
          aria-label="Base specs"
          phx-window-keydown="wf_base_close"
          phx-key="Escape"
        >
          <div class="absolute inset-0" phx-click="wf_base_close" aria-hidden="true"></div>
          <div class="relative flex max-h-full w-full max-w-lg flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl">
            <header class="border-b border-base-300 px-5 py-4">
              <h2 class="font-semibold">Base specs for {@workflow.name}</h2>
              <p class="text-sm text-base-content/55">
                Every run on this workflow starts with these. A run can still add or leave
                out any of them in its chat.
              </p>
            </header>
            <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
              <FactoryWeb.SpecParts.base_picker
                id="workflow-base-picker"
                specs={@base_specs}
                selected={@workflow.base_spec_ids}
                event="wf_toggle_base"
              />
            </div>
            <footer class="flex items-center gap-2 border-t border-base-300 px-5 py-3">
              <.link
                navigate={~p"/specs"}
                class="text-sm text-base-content/55 hover:text-base-content"
              >
                Write base specs →
              </.link>
              <button type="button" phx-click="wf_base_close" class="btn btn-primary btn-sm ml-auto">
                Done
              </button>
            </footer>
          </div>
        </div>
        <div class="flex min-h-0 flex-1">
          <div
            class="relative min-h-0 min-w-0 flex-1 bg-base-200 dark:bg-base-100"
            phx-window-keydown={@selected && !@editing_context && "close"}
            phx-key="Escape"
          >
            <div
              id={"agent-flow-#{@workflow.id}"}
              phx-hook="Flow"
              phx-update="ignore"
              data-graph={JSON.encode!(%{@graph | selected: @selected && to_string(@selected.id)})}
              class="absolute inset-0"
            >
            </div>

            <FactoryWeb.ActionParts.panel
              :if={@selected && @selected.kind == "action"}
              action={@action_draft || @selected}
              result={@action_result}
              running={MapSet.member?(@running_actions, @selected.id)}
              new={@new_action_id == @selected.id}
              changed={@action_draft != nil}
            />
            <aside
              :if={@selected && @selected.kind != "action"}
              id={"panel-#{@selected.id}"}
              class="drawer-in absolute inset-x-3 bottom-3 flex max-h-[70%] flex-col overflow-hidden rounded-2xl border border-base-content/10 bg-surface shadow-xl sm:inset-x-auto sm:right-3 sm:top-3 sm:max-h-none sm:w-[340px]"
            >
              <.form
                for={@form}
                id="agent-form"
                phx-change="save"
                phx-submit="save"
                class="flex min-h-0 flex-1 flex-col"
              >
                <div class="min-h-0 flex-1 overflow-y-auto px-4 pb-4 pt-3.5">
                  <div class="flex items-center gap-2">
                    <.icon
                      name={FactoryWeb.AgentKinds.icon(@selected.kind)}
                      class="size-5 shrink-0 text-base-content/60"
                    />
                    <input
                      type="text"
                      id="agent-name"
                      name={@form[:name].name}
                      value={@form[:name].value}
                      phx-debounce="300"
                      aria-label="Name"
                      class="-mx-1 min-w-0 flex-1 rounded-md border border-transparent bg-transparent px-1 py-0.5 text-base font-semibold outline-none hover:border-base-content/10 focus:border-base-content/25 focus-visible:outline-none"
                    />
                    <.link
                      navigate={~p"/chat?#{[agent: @selected.id]}"}
                      title="Chat with this agent"
                      class="flex h-7 items-center gap-1 rounded-md px-2 text-xs text-base-content/60 hover:bg-base-content/[0.06] hover:text-base-content"
                    >
                      <.icon name="hero-chat-bubble-left-right-mini" class="size-4" /> Chat
                    </.link>
                    <.link
                      patch={~p"/workflows/#{@selected.workflow_id}"}
                      class="grid size-7 place-items-center rounded-md text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
                      aria-label="Close"
                    >
                      <.icon name="hero-x-mark-mini" class="size-4" />
                    </.link>
                  </div>
                  <p :for={{msg, _} <- @form[:name].errors} class="mt-1 text-xs text-error">{msg}</p>

                  <div class="ml-7 mt-0.5 flex items-center gap-1.5 text-xs text-base-content/50">
                    <span class={["size-1.5 rounded-full", Layouts.status_dot(@selected.status)]}></span>
                    {Layouts.status_label(@selected.status)}
                    <span :if={@selected.activity} class="truncate">· {@selected.activity}</span>
                  </div>

                  <textarea
                    id="agent-role"
                    name={@form[:role].name}
                    phx-debounce="300"
                    rows="2"
                    placeholder="Add a description…"
                    aria-label="Description"
                    class="mt-3 block w-full resize-none rounded-md border border-transparent bg-transparent px-1 py-1 text-[13px] leading-5 text-base-content/80 outline-none placeholder:text-base-content/35 hover:border-base-content/10 focus:border-base-content/25 focus-visible:outline-none"
                  >{Phoenix.HTML.Form.normalize_value("textarea", @form[:role].value)}</textarea>

                  <dl class="mt-3 border-t border-base-content/10 pt-2 text-[13px]">
                    <.prop label="Role">
                      <.plain_select
                        field={@form[:kind]}
                        options={for {k, l, _} <- FactoryWeb.AgentKinds.all(), do: {l, k}}
                      />
                    </.prop>
                    <.prop label="Model">
                      <.plain_select field={@form[:model]} options={Kiro.models()} />
                    </.prop>
                    <.prop label="Mode">
                      <.plain_select field={@form[:kiro_mode]} options={Kiro.modes()} />
                    </.prop>
                    <.prop label="Session">
                      <.plain_select
                        field={@form[:session]}
                        options={[{"Own session", "own"}, {"Shared session", "shared"}]}
                      />
                    </.prop>
                    <.prop label="Kiro">
                      <span :if={!Kiro.running?(@selected)} class="px-1.5 text-base-content/50">
                        Starts on first message
                      </span>
                      <span :if={Kiro.running?(@selected)} class="flex items-center gap-2 px-1.5">
                        <span class="size-1.5 rounded-full bg-success"></span>
                        {if @selected.session == "shared",
                          do: "Shared session running",
                          else: "Running"}
                        <button
                          id="stop-kiro"
                          type="button"
                          phx-click="stop_kiro"
                          class="text-xs text-base-content/50 underline-offset-2 hover:text-base-content hover:underline"
                        >
                          Stop
                        </button>
                      </span>
                    </.prop>
                    <.prop label="Usage">
                      <div id="agent-usage" class="space-y-1.5 px-1.5 py-1">
                        <span :if={!@selected.usage["turns"]} class="text-base-content/40">
                          No turns yet
                        </span>
                        <div :if={@selected.usage["turns"]} class="flex items-center gap-3 text-xs">
                          <span class="flex items-center gap-1" title="Turns with Kiro">
                            <.icon
                              name="hero-arrow-path-rounded-square-mini"
                              class="size-4 opacity-50"
                            />
                            {@selected.usage["turns"]} {if @selected.usage["turns"] == 1,
                              do: "turn",
                              else: "turns"}
                          </span>
                          <span class="flex items-center gap-1" title="Kiro credits used">
                            <.icon name="hero-bolt-mini" class="size-4 opacity-50" />
                            {FactoryWeb.Usage.credits(@selected.usage["credits"])} credits
                          </span>
                        </div>
                        <div
                          :if={@selected.usage["context_pct"]}
                          title="Current Kiro session. The window size is estimated from Kiro's numbers."
                        >
                          <div class="relative h-1 rounded-full bg-base-content/10">
                            <div
                              class={[
                                "h-full rounded-full",
                                case FactoryWeb.Usage.level(@selected.usage["context_pct"]) do
                                  "high" -> "bg-error"
                                  "mid" -> "bg-warning"
                                  _ -> "bg-info"
                                end
                              ]}
                              style={"width: #{min(max(@selected.usage["context_pct"], 2), 100)}%"}
                            >
                            </div>
                            <%!-- Where the session compacts before its next message. --%>
                            <span
                              id="compact-at"
                              class="absolute -top-0.5 h-2 w-px bg-base-content/40"
                              style={"left: #{FactoryWeb.Usage.compact_at()}%"}
                              title={"Compacts before the next message from #{FactoryWeb.Usage.compact_at()}%"}
                            ></span>
                          </div>
                          <p class="mt-1 flex items-center justify-between gap-2 text-[11px] text-base-content/50">
                            <span>Context {FactoryWeb.Usage.context(@selected.usage)}</span>
                            <button
                              :if={Kiro.running?(@selected)}
                              id="compact-context"
                              type="button"
                              phx-click="compact"
                              phx-value-id={@selected.id}
                              title="Summarize the conversation by fixed rules (the latest messages stay word for word) and continue in a fresh Kiro session"
                              class="flex shrink-0 items-center gap-0.5 rounded px-1 text-error/80 hover:bg-error/10 hover:text-error"
                            >
                              <.icon name="hero-document-minus-mini" class="size-3.5" /> Compact
                            </button>
                          </p>
                        </div>
                      </div>
                    </.prop>
                    <.prop label="Prompt">
                      <.link
                        id="edit-context"
                        patch={~p"/workflows/#{@selected.workflow_id}/agents/#{@selected.id}?prompt"}
                        class="flex w-full items-center justify-between rounded-md px-1.5 py-1 hover:bg-base-content/[0.06]"
                      >
                        <span class={String.trim(@selected.prompt) == "" && "text-base-content/40"}>
                          {prompt_summary(@selected.prompt)}
                        </span>
                        <span class="text-xs text-base-content/50">
                          {if String.trim(@selected.prompt) == "", do: "Add", else: "Edit"}
                        </span>
                      </.link>
                    </.prop>
                    <.prop label="Hands off to">
                      <div class="flex flex-wrap gap-1 px-1.5 py-0.5">
                        <.agent_links agents={@neighbours.hands_off_to} />
                      </div>
                    </.prop>
                    <.prop label="Receives from">
                      <div class="flex flex-wrap gap-1 px-1.5 py-0.5">
                        <.agent_links agents={@neighbours.receives_from} />
                      </div>
                    </.prop>
                  </dl>
                </div>

                <div class="flex items-center justify-between border-t border-base-content/10 px-4 py-2">
                  <span class="text-[11px] text-base-content/40">Saved automatically</span>
                  <button
                    id="delete-agent"
                    type="button"
                    phx-click="delete_agent"
                    data-confirm={"Delete #{@selected.name} and its arrows?"}
                    class="rounded-md px-1.5 py-1 text-xs text-base-content/45 hover:bg-error/10 hover:text-error"
                  >
                    Delete agent
                  </button>
                </div>
              </.form>
            </aside>

            <.context_editor
              :if={@selected && @editing_context}
              agent={@selected}
              form={@context_form}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :agent, :map, required: true
  attr :form, :any, required: true

  # Editor for an agent's prompt, laid out like a file in a code editor.
  defp context_editor(assigns) do
    text = assigns.form[:prompt].value || ""

    # The agent's own role first in the Templates menu.
    kinds =
      Enum.sort_by(FactoryWeb.AgentKinds.all(), fn {kind, _, _} -> kind != assigns.agent.kind end)

    assigns =
      assign(assigns,
        kinds: kinds,
        text: text,
        chars: String.length(text),
        lines: max(length(String.split(text, "\n")), 1),
        dirty: text != (assigns.agent.prompt || ""),
        close: JS.patch(agent_path(assigns.agent))
      )

    ~H"""
    <div
      id="context-editor"
      class="absolute inset-0 z-40 flex items-center justify-center bg-black/50 p-3 sm:p-6"
      phx-window-keydown={!@dirty && @close}
      phx-key="Escape"
    >
      <.form
        for={@form}
        id="context-form"
        phx-change="context_change"
        phx-submit="save_context"
        phx-click-away={!@dirty && @close}
        class="flex h-full max-h-[760px] w-full max-w-3xl flex-col overflow-hidden rounded-2xl border border-base-content/10 bg-surface shadow-2xl"
      >
        <header class="flex h-14 shrink-0 items-center gap-2 border-b border-base-content/10 pl-4 pr-3">
          <.icon name={FactoryWeb.AgentKinds.icon(@agent.kind)} class="size-4 shrink-0 opacity-60" />
          <p class="min-w-0 truncate text-xs">
            <span class="text-base-content/60">{@agent.name}</span>
            <span class="mx-1 text-base-content/30">/</span>
            <span class="font-semibold">Prompt</span>
          </p>
          <span
            :if={@dirty}
            class="flex shrink-0 items-center gap-1.5 text-xs text-base-content/50"
          >
            <span class="size-1.5 rounded-full bg-amber-300/80"></span> Unsaved
          </span>

          <div class="ml-auto flex shrink-0 items-center gap-1.5">
            <details
              id="prompt-templates"
              class="relative"
              phx-click-away={JS.remove_attribute("open", to: "#prompt-templates")}
            >
              <summary class="flex h-8 cursor-pointer list-none items-center gap-1 rounded-lg px-2.5 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content">
                Templates <.icon name="hero-chevron-down-mini" class="size-4 opacity-60" />
              </summary>
              <div class="absolute right-0 z-10 mt-1 w-72 rounded-xl border border-base-content/10 bg-surface p-1 shadow-xl">
                <p class="px-3 pb-1 pt-2 text-xs text-base-content/45">
                  Replaces the current text
                </p>
                <button
                  :for={{kind, label, icon} <- @kinds}
                  type="button"
                  phx-click={
                    JS.dispatch("factory:fill",
                      to: "#context-prompt",
                      detail: %{text: FactoryWeb.AgentKinds.template(kind, @agent.name)}
                    )
                    |> JS.remove_attribute("open", to: "#prompt-templates")
                  }
                  class="flex w-full items-start gap-2.5 rounded-lg px-3 py-2 text-left hover:bg-base-content/[0.06]"
                >
                  <.icon name={icon} class="mt-0.5 size-4 shrink-0 opacity-60" />
                  <span class="min-w-0 flex-1">
                    <span class="flex items-center gap-1.5 text-[13px]">
                      {label}
                      <span
                        :if={kind == @agent.kind}
                        class="rounded bg-base-200 px-1 text-[10px] text-base-content/55"
                      >
                        this agent
                      </span>
                    </span>
                    <span class="block text-[11px] text-base-content/50">
                      {FactoryWeb.AgentKinds.blurb(kind)}
                    </span>
                  </span>
                </button>
              </div>
            </details>
            <.link
              patch={agent_path(@agent)}
              data-confirm={@dirty && "Discard your changes to #{@agent.name}'s prompt?"}
              class="flex h-8 items-center rounded-lg px-3 text-xs text-base-content/70 hover:bg-base-content/[0.06] hover:text-base-content"
            >
              Cancel
            </.link>
            <button
              type="submit"
              class="flex h-8 items-center rounded-lg bg-base-content px-3.5 text-xs font-medium text-base-100 hover:opacity-90"
            >
              Save
            </button>
          </div>
        </header>

        <div class="relative min-h-0 flex-1 overflow-y-auto bg-base-200/40">
          <div class="flex min-h-full">
            <div
              class="w-10 shrink-0 select-none border-r border-base-content/10 py-3.5 pr-2 text-right font-mono text-[10px] leading-[18px] text-base-content/25"
              aria-hidden="true"
            >
              <div :for={n <- 1..@lines}>{n}</div>
            </div>
            <textarea
              id="context-prompt"
              name={@form[:prompt].name}
              phx-hook="PromptEditor"
              phx-debounce="150"
              spellcheck="false"
              aria-label={"#{@agent.name}'s prompt"}
              class="block min-h-full w-full resize-none overflow-hidden bg-transparent px-4 py-3.5 font-mono text-[11px] leading-[18px] outline-none focus-visible:outline-none"
            >{Phoenix.HTML.Form.normalize_value("textarea", @text)}</textarea>
          </div>

          <div
            :if={String.trim(@text) == ""}
            class="pointer-events-none absolute inset-0 flex items-center justify-center p-6"
          >
            <div class="max-w-sm text-center">
              <p class="text-[13px] font-medium">Write how {@agent.name} should work</p>
              <p class="mt-1.5 text-[11px] leading-[18px] text-base-content/55">
                What it's responsible for, how it should work, and what it must never do.
                Kiro reads this before your first message in each session.
              </p>
              <button
                type="button"
                phx-click={
                  JS.dispatch("factory:fill",
                    to: "#context-prompt",
                    detail: %{text: FactoryWeb.AgentKinds.template(@agent.kind, @agent.name)}
                  )
                }
                class="pointer-events-auto mt-4 inline-flex items-center gap-1.5 rounded-lg border border-base-content/15 bg-base-100 px-3 py-1.5 text-xs hover:bg-base-content/[0.06]"
              >
                <.icon name={FactoryWeb.AgentKinds.icon(@agent.kind)} class="size-4 opacity-70" />
                Start from the {FactoryWeb.AgentKinds.label(@agent.kind)} template
              </button>
              <p class="mt-2 text-[11px] text-base-content/40">or just start typing</p>
            </div>
          </div>
        </div>

        <p
          :for={{msg, _} <- @form[:prompt].errors}
          class="border-t border-error/30 bg-error/10 px-4 py-2 text-xs text-error"
        >
          {msg}
        </p>

        <footer class="flex h-9 shrink-0 items-center gap-4 border-t border-base-content/10 px-4 text-[10px] text-base-content/45">
          <span>Markdown</span>
          <span id="context-count" class="tabular-nums">
            {@lines} {if @lines == 1, do: "line", else: "lines"}, {@chars} characters
          </span>
          <span class="hidden sm:inline">Saving restarts {@agent.name}'s Kiro</span>
          <span class="ml-auto hidden sm:inline">⌘S to save</span>
        </footer>
      </.form>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  # One row in the side panel: label on the left, value on the right.
  defp prop(assigns) do
    ~H"""
    <div class="flex min-h-9 items-center gap-2">
      <dt class="w-24 shrink-0 text-base-content/50">{@label}</dt>
      <dd class="min-w-0 flex-1">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true

  # A select that reads as plain text until hovered.
  defp plain_select(assigns) do
    ~H"""
    <select
      name={@field.name}
      class="w-full cursor-pointer appearance-none truncate rounded-md border border-transparent bg-transparent px-1.5 py-1 outline-none hover:bg-base-content/[0.06] focus:border-base-content/25 focus-visible:outline-none"
    >
      {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
    </select>
    """
  end

  defp prompt_summary(prompt) do
    case String.trim(prompt || "") do
      "" ->
        "Not set"

      text ->
        case length(String.split(text, "\n")) do
          1 -> "1 line"
          n -> "#{n} lines"
        end
    end
  end

  attr :workflow, :map, required: true
  attr :workflows, :list, required: true
  attr :naming, :string, default: nil
  attr :sources, :list, default: []

  # Above the canvas: which workflow this is, a menu to pick another, and what to do with it.
  defp workflow_bar(assigns) do
    {standard, custom} = Enum.split_with(assigns.workflows, &Workflow.standard?/1)

    assigns =
      assign(assigns,
        standard: standard,
        custom: custom,
        modified: Workflows.modified?(assigns.workflow)
      )

    ~H"""
    <div
      id="workflow-bar"
      class="flex min-h-13 flex-wrap items-center gap-x-3 gap-y-2 border-b border-base-300 bg-base-100 px-4 py-2 sm:px-6"
    >
      <details
        id="workflow-picker"
        class="relative"
        phx-click-away={JS.remove_attribute("open", to: "#workflow-picker")}
      >
        <summary class="flex cursor-pointer list-none items-center gap-2 rounded-lg border border-base-300 px-3 py-1.5 text-sm hover:border-base-content/25 [&::-webkit-details-marker]:hidden">
          <.icon name="hero-squares-2x2-mini" class="size-4 text-base-content/50" />
          <span class="text-base-content/55">Select workflow</span>
          <.icon name="hero-chevron-down-mini" class="size-4 text-base-content/40" />
        </summary>
        <div class="absolute left-0 z-40 mt-1.5 w-80 rounded-xl border border-base-content/10 bg-surface p-1.5 shadow-xl">
          <p class="px-2.5 pb-1 pt-1.5 text-[11px] font-medium uppercase tracking-wide text-base-content/45">
            Standard
          </p>
          <.workflow_item :for={w <- @standard} w={w} open={w.id == @workflow.id} />
          <p class="px-2.5 pb-1 pt-3 text-[11px] font-medium uppercase tracking-wide text-base-content/45">
            Custom
          </p>
          <p :if={@custom == []} class="px-2.5 pb-2 text-xs text-base-content/50">
            None yet. Make one, or clone a standard one to change it freely.
          </p>
          <.workflow_item :for={w <- @custom} w={w} open={w.id == @workflow.id} />
        </div>
      </details>

      <div :if={@naming != "rename"} class="flex min-w-0 items-center gap-2">
        <.icon
          :if={@workflow.key}
          name={type_icon(@workflow.key, :micro)}
          class="size-4 shrink-0 text-primary"
        />
        <h1 id="workflow-name" class="truncate text-[15px] font-semibold">{@workflow.name}</h1>
        <span
          :if={@workflow.key}
          class="rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-base-content/60"
        >
          Standard
        </span>
        <span
          :if={@modified}
          id="workflow-modified"
          class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-warning"
        >
          Modified
        </span>
        <span
          :if={@workflow.current}
          title="Plain chats talk to this workflow's agents"
          class="rounded bg-success/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-success"
        >
          Used in chat
        </span>
      </div>

      <form
        :if={@naming in ["rename", "new"]}
        id="workflow-name-form"
        phx-submit={if @naming == "new", do: "wf_create", else: "wf_rename"}
        phx-keydown="wf_naming"
        phx-key="Escape"
        phx-value-what=""
        class="flex items-center gap-2"
      >
        <input
          name="name"
          value={if @naming == "rename", do: @workflow.name, else: ""}
          placeholder="Workflow name"
          maxlength="60"
          phx-mounted={JS.focus()}
          class="h-8 w-60 rounded-md border border-base-300 bg-base-100 px-2.5 text-sm outline-none focus:border-base-content/30"
        />
        <button class="btn btn-primary btn-xs">
          {if @naming == "new", do: "Create", else: "Rename"}
        </button>
        <button type="button" phx-click="wf_naming" phx-value-what="" class="btn btn-ghost btn-xs">
          Cancel
        </button>
      </form>

      <div class="ml-auto flex flex-wrap items-center gap-1">
        <.bar_button
          :if={@naming == nil}
          id="wf-rename"
          event="wf_naming"
          value="rename"
          icon="hero-pencil-mini"
        >
          Rename
        </.bar_button>
        <.bar_button id="wf-base-specs" event="wf_base_specs" icon="hero-building-library-mini">
          Base specs{if @workflow.base_spec_ids != [], do: " · #{length(@workflow.base_spec_ids)}"}
        </.bar_button>
        <.bar_button id="wf-clone" event="wf_clone" icon="hero-document-duplicate-mini">
          Clone
        </.bar_button>
        <.bar_button
          :if={@workflow.key}
          id="wf-restore"
          event="wf_restore"
          icon="hero-arrow-uturn-left-mini"
          confirm={"Restore “#{@workflow.name}” to its default? Its agents, prompts and arrows are replaced. Clone it first to keep your changes."}
          disabled={!@modified}
        >
          Restore default
        </.bar_button>
        <.bar_button
          :if={!@workflow.key}
          id="wf-delete"
          event="wf_delete"
          icon="hero-trash-mini"
          confirm={"Delete “#{@workflow.name}” and its agents?"}
          danger
        >
          Delete
        </.bar_button>
        <span class="mx-1 h-5 w-px bg-base-300"></span>
        <button
          id="wf-new"
          type="button"
          phx-click="wf_naming"
          phx-value-what="new"
          class="btn btn-primary btn-sm"
        >
          <.icon name="hero-plus-mini" class="size-4" /> Add new workflow
        </button>
      </div>
    </div>
    """
  end

  attr :w, :map, required: true
  attr :open, :boolean, required: true

  defp workflow_item(assigns) do
    ~H"""
    <.link
      patch={~p"/workflows/#{@w.id}"}
      id={"pick-workflow-#{@w.id}"}
      class={[
        "flex items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm hover:bg-base-content/[0.06]",
        @open && "bg-base-content/[0.06] font-medium"
      ]}
    >
      <.icon :if={@w.key} name={type_icon(@w.key, :micro)} class="size-4 shrink-0 text-primary" />
      <.icon :if={!@w.key} name="hero-squares-2x2-micro" class="size-4 shrink-0 text-base-content/45" />
      <span class="min-w-0 flex-1 truncate">{@w.name}</span>
      <span :if={@w.current} class="size-1.5 rounded-full bg-success" title="Used in chat"></span>
      <span class="text-xs tabular-nums text-base-content/45">
        {length(@w.agents)} {if length(@w.agents) == 1, do: "agent", else: "agents"}
      </span>
      <.icon :if={@open} name="hero-check-mini" class="size-4 text-base-content/60" />
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value, :string, default: nil
  attr :icon, :string, required: true
  attr :confirm, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :danger, :boolean, default: false
  slot :inner_block, required: true

  defp bar_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-what={@value}
      data-confirm={@confirm}
      disabled={@disabled}
      class={[
        "inline-flex h-8 items-center gap-1.5 rounded-md px-2.5 text-sm text-base-content/70 transition-colors hover:bg-base-content/[0.06] hover:text-base-content disabled:pointer-events-none disabled:opacity-40",
        @danger && "hover:bg-error/10 hover:text-error"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :agents, :list, required: true

  defp agent_links(assigns) do
    ~H"""
    <span :if={@agents == []} class="text-base-content/40">None</span>
    <.link
      :for={a <- @agents}
      patch={agent_path(a)}
      class="rounded-md bg-base-200 px-1.5 py-0.5 text-xs hover:bg-base-300"
    >
      {a.name}
    </.link>
    """
  end

  defp save_link_prompt(
         %{assigns: %{link_prompt: %{link: link, from: from, to: to}}} = socket,
         prompt
       ) do
    case Agents.set_link_prompt(link, prompt) do
      {:ok, link} ->
        message =
          if link.prompt == "",
            do: "Removed the hand-off prompt from #{from.name} to #{to.name}.",
            else: "#{to.name} gets this prompt when #{from.name} hands over."

        {:noreply, socket |> assign(link_prompt: nil) |> refresh() |> put_flash(:info, message)}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "That prompt is too long (20,000 characters at most).")}
    end
  end

  defp save_link_prompt(socket, _prompt), do: {:noreply, socket}

  attr :link, :map, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true

  # Editing what an arrow says on its hand-off.
  defp link_prompt_window(assigns) do
    ~H"""
    <div
      id="link-prompt-window"
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 backdrop-blur-sm sm:items-center"
      phx-window-keydown="link_prompt_close"
      phx-key="Escape"
    >
      <.form
        for={%{}}
        id="link-prompt-form"
        phx-submit="link_prompt_save"
        phx-click-away="link_prompt_close"
        class="drawer-in w-full max-w-xl overflow-hidden rounded-2xl border border-base-content/10 bg-surface shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-labelledby="link-prompt-title"
      >
        <header class="flex items-center gap-3 border-b border-base-content/10 px-5 py-4">
          <span class="grid size-9 place-items-center rounded-xl bg-info/15 text-info">
            <.icon name="hero-chat-bubble-bottom-center-text" class="size-5" />
          </span>
          <div class="min-w-0 flex-1">
            <h2 id="link-prompt-title" class="truncate font-semibold">
              {@from.name}
              <.icon name="hero-arrow-long-right-mini" class="size-4 text-base-content/40" />
              {@to.name}
            </h2>
            <p class="text-xs text-base-content/55">
              Added to {@to.name}'s context each time {@from.name} hands work over.
            </p>
          </div>
          <button
            type="button"
            phx-click="link_prompt_close"
            aria-label="Close"
            class="grid size-8 place-items-center rounded-lg text-base-content/50 hover:bg-base-content/[0.06] hover:text-base-content"
          >
            <.icon name="hero-x-mark-mini" class="size-5" />
          </button>
        </header>
        <div class="px-5 py-4">
          <textarea
            id="link-prompt-text"
            name="prompt"
            rows="7"
            phx-mounted={JS.focus()}
            placeholder={"e.g. Only pass on the tasks that touch the API, and list the files you changed so #{@to.name} can start there."}
            class="textarea w-full text-sm leading-relaxed"
          >{@link.prompt}</textarea>
        </div>
        <footer class="flex items-center gap-2 border-t border-base-content/10 px-5 py-3">
          <button type="submit" class="btn btn-primary btn-sm">Save prompt</button>
          <button type="button" phx-click="link_prompt_close" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            :if={@link.prompt != ""}
            id="link-prompt-remove"
            type="button"
            phx-click="link_prompt_remove"
            class="btn btn-ghost btn-sm ml-auto text-error"
          >
            <.icon name="hero-trash-micro" class="size-4" /> Remove
          </button>
        </footer>
      </.form>
    </div>
    """
  end
end
