defmodule FactoryWeb.WorkflowsLive do
  @moduledoc """
  The workflows: pick one, then arrange its agents and hand-offs on the canvas.
  Standard workflows (one per job on the start screen) can be changed and restored;
  custom ones can be made new or cloned, renamed and deleted.
  URLs: /workflows (the current one), /workflows/:workflow_id, …/agents/:id.
  """
  use FactoryWeb, :live_view
  import FactoryWeb.WorkflowParts
  alias Factory.{Actions, Agents, FileBrowser, Kiro, Sources, Workflows}
  alias Factory.Agents.Agent

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

  # An action run from its panel finished (`run_action/2`), or crashed: either way the
  # card stops running and its panel shows the outcome.
  def handle_async({:action, id}, {:ok, result}, socket),
    do: {:noreply, action_finished(socket, id, result)}

  def handle_async({:action, id}, {:exit, reason}, socket) do
    result = {:error, "The action crashed: #{Exception.format_exit(reason)}"}
    Agents.set_activity(id, "error", String.slice(elem(result, 1), 0, 200))
    {:noreply, action_finished(socket, id, result)}
  end

  defp action_finished(socket, id, result) do
    socket = update(socket, :running_actions, &MapSet.delete(&1, id))

    if socket.assigns.selected && socket.assigns.selected.id == id,
      do: socket |> assign(action_result: result) |> refresh(),
      else: refresh(socket)
  end

  # Another tab changed the graph. Close the panel if its agent was deleted there,
  # and leave a workflow that was deleted there.
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
    case Workflows.clone(socket.assigns.workflow) do
      {:ok, copy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cloned as “#{copy.name}”.")
         |> push_patch(to: ~p"/workflows/#{copy.id}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't clone the workflow. Try again.")}
    end
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
    case Sources.get(id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "That source is gone.") |> reload_sources()}

      source ->
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

  # Runs the action in the background; `handle_async/3` takes the result, or the
  # crash, so the card never stays "running".
  defp run_action(socket, card) do
    Agents.set_activity(card.id, "running", "Running")

    {:noreply,
     socket
     |> update(:running_actions, &MapSet.put(&1, card.id))
     |> assign(action_result: :running)
     |> start_async({:action, card.id}, fn ->
       result = Actions.run(card)

       {status, text} =
         if match?({:ok, _}, result), do: {"done", "Done"}, else: {"error", elem(result, 1)}

       Agents.set_activity(card.id, status, String.slice(text, 0, 200))
       result
     end)}
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
          <div class="relative flex max-h-full w-full max-w-lg flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-2xl">
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
            <.agent_panel
              :if={@selected && @selected.kind != "action"}
              selected={@selected}
              form={@form}
              neighbours={@neighbours}
            />

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
end
