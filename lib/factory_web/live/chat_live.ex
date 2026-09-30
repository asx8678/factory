defmodule FactoryWeb.ChatLive do
  use FactoryWeb, :live_view
  import Ecto.Query, only: [from: 2]
  alias Factory.{Agents, Chat, Engine, FileBrowser, Kiro, Runs, Specs, Workflows}
  alias Factory.Repo
  alias Factory.Runs.Message
  import FactoryWeb.ChatParts

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
     |> assign(
       plan_spec: nil,
       plan_sub: nil,
       plan_editing: nil,
       plan_asking: nil,
       plan_improve: %{},
       plan_inline: nil,
       plan_checking: false,
       plan_check: nil,
       plan_before: nil
     )
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
         |> load_plan()
         # A new chat works in the folder picked last, until another is picked.
         |> set_dir(Factory.Prefs.project_dir())
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
             |> load_messages()
             |> load_plan()}
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

    # The agent a draft's plain text is planned by (Factory.Chat.planner_for/1).
    planner =
      Chat.planner_for(
        run || %Factory.Runs.Run{settings: %{"workflow_id" => workflow.id}, status: "draft"}
      )

    assign(socket,
      workflow: workflow,
      planner: planner,
      graph: Agents.graph(workflow.id),
      agents: agents,
      to: to,
      steps: if(run, do: Engine.steps(run), else: Engine.workflow_steps(workflow.id))
    )
  end

  # Specs on this run: its base specs, and its own spec once something is written in it.
  defp spec_count(assigns) do
    own = if assigns.run && assigns.run.spec_files != [], do: 1, else: 0
    length(assigns.base_ids) + own
  end

  defp default_to(agents),
    do: Enum.find(agents, &(&1.kind == "planner")) || List.first(agents) || :factory

  # A run keeps its folder. One still being planned that has none yet takes the folder
  # picked last, like a new chat.
  defp keep_dir(socket, run) do
    dir = run.settings["project_dir"] || (settable?(run) && Factory.Prefs.project_dir())
    set_dir(socket, dir || "")
  end

  defp set_dir(socket, dir) do
    dir = String.trim(dir || "")
    assign(socket, dir: dir, dir_ok: dir != "" and File.dir?(Path.expand(dir)))
  end

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
      socket =
        if String.starts_with?(String.trim(body), "/"), do: socket, else: remember_plan(socket)

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

  # Options picked under a planner's questions: sent to that planner as one message,
  # each question with its answer.
  def handle_event("answer", %{"message_id" => id} = params, socket) do
    message = socket.assigns.run && Repo.get(Message, id)
    agent = message && message.meta["agent_id"] && Agents.get_agent(message.meta["agent_id"])
    picked = params["answers"] || %{}
    own = params["others"] || %{}

    # The option picked, with what was written beside it: an answer of your own, or the
    # details an option asks for.
    text =
      for {q, i} <- Enum.with_index((message && message.meta["questions"]) || []),
          answer =
            [picked["#{i}"], own["#{i}"]]
            |> Enum.map(&String.trim(to_string(&1 || "")))
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(": "),
          answer != "" do
        "#{q["question"]} #{answer}"
      end
      |> Enum.join("\n")

    if agent && text != "" && message.run_id == socket.assigns.run.id do
      Chat.handle(Runs.get_run(socket.assigns.run.id), text, [], to: agent)
      {:noreply, push_event(socket, "chat:sent", %{})}
    else
      {:noreply, socket}
    end
  end

  # The answer to a question a tool asked mid-turn: back to that agent's Kiro session.
  def handle_event("elicit_answer", %{"key" => key, "agent_id" => agent_id} = params, socket) do
    action = if params["action"] == "decline", do: "decline", else: "accept"
    agent = Agents.get_agent(agent_id)
    content = if action == "accept", do: typed(params["fields"] || %{}, key, socket), else: %{}

    case agent && Kiro.answer_elicitation(agent, key, action, content) do
      :ok -> {:noreply, socket}
      _ -> {:noreply, put_flash(socket, :error, "That question is no longer open.")}
    end
  end

  # The plan being made (FactoryWeb.PlanPanel): each task edited, removed, or handed to
  # Kiro to flesh out from the code or change as asked; or the whole plan reviewed again.

  def handle_event("plan_edit", %{"i" => i}, socket),
    do: {:noreply, assign(socket, plan_editing: String.to_integer(i), plan_asking: nil)}

  def handle_event("plan_edit_cancel", _, socket),
    do: {:noreply, assign(socket, plan_editing: nil)}

  # Editing in place (double-click): a task's title or objective, one of its steps or
  # checks, or a new step or check.
  def handle_event("plan_inline", %{"i" => i, "part" => part}, socket)
      when part in ["title", "objective", "new", "newcheck"] or
             binary_part(part, 0, 5) == "step-" or binary_part(part, 0, 6) == "check-" do
    {:noreply,
     assign(socket,
       plan_inline: {String.to_integer("#{i}"), part},
       plan_editing: nil,
       plan_asking: nil
     )}
  end

  def handle_event("plan_inline_cancel", _, socket),
    do: {:noreply, assign(socket, plan_inline: nil)}

  # Saved by Enter or by leaving the field; only the field that's open counts, so the
  # blur after an Enter doesn't save twice.
  def handle_event("plan_inline_save", %{"i" => i, "part" => part} = params, socket) do
    i = String.to_integer("#{i}")
    value = String.trim(params["value"] || "")

    with {^i, ^part} <- socket.assigns.plan_inline,
         %{} = task <- Enum.at(plan_tasks(socket), i),
         {:ok, changed} <- inline_change(task, part, value) do
      socket
      |> assign(plan_inline: nil)
      |> own_change(i, :edit, Specs.edit_plan_task(plan_spec(socket), i, changed))
    else
      _ -> {:noreply, assign(socket, plan_inline: nil)}
    end
  end

  def handle_event("plan_save", %{"i" => i, "task" => params}, socket) do
    socket
    |> assign(plan_editing: nil)
    |> own_change(
      String.to_integer(i),
      :edit,
      Specs.edit_plan_task(plan_spec(socket), String.to_integer(i), params)
    )
  end

  def handle_event("plan_remove", %{"i" => i}, socket) do
    socket
    |> assign(plan_editing: nil, plan_asking: nil)
    |> own_change(
      String.to_integer(i),
      :remove,
      Specs.remove_plan_task(plan_spec(socket), String.to_integer(i))
    )
  end

  # The gold marks on what the planner changed: cleared once they've been read.
  def handle_event("plan_changes_clear", _, socket),
    do: {:noreply, assign(socket, plan_before: nil)}

  def handle_event("plan_check_dismiss", _, socket),
    do: {:noreply, assign(socket, plan_check: nil)}

  def handle_event("plan_refine", %{"i" => i}, socket),
    do: {:noreply, ask_kiro(socket, String.to_integer(i), "")}

  # Scope: the planner checks the plan against what was asked and the code, and reports
  # above the plan; nothing changes (Factory.Specs.Planner has the prompt).
  def handle_event("plan_scope", _, socket) do
    run = socket.assigns.run && Runs.get_run(socket.assigns.run.id)
    planner = socket.assigns.planner

    if run && planner && run.status == "draft" do
      Factory.ChatPlanner.start(run, planner, action: :scope)
      {:noreply, assign(socket, plan_checking: true)}
    else
      {:noreply, put_flash(socket, :error, "This run has no planner to check its plan.")}
    end
  end

  # Refine (and "Refine with this"): the planner reworks the plan in place from the
  # code, acting on the scope check shown with it. The request goes to the planner
  # only, not into the chat; its reply does.
  def handle_event("plan_review", _, socket) do
    run = socket.assigns.run && Runs.get_run(socket.assigns.run.id)
    planner = socket.assigns.planner

    if run && planner && run.status == "draft" do
      findings = socket.assigns.plan_check && socket.assigns.plan_check.body
      Factory.ChatPlanner.start(run, planner, action: :refine, findings: findings)
      {:noreply, socket |> remember_plan() |> assign(plan_checking: false)}
    else
      {:noreply, put_flash(socket, :error, "This run has no planner to review its plan.")}
    end
  end

  def handle_event("plan_ask_open", %{"i" => ""}, socket),
    do: {:noreply, assign(socket, plan_asking: nil)}

  def handle_event("plan_ask_open", %{"i" => i}, socket) do
    task = socket |> plan_tasks() |> Enum.at(String.to_integer(i))
    {:noreply, assign(socket, plan_asking: task && task.title, plan_editing: nil)}
  end

  def handle_event("plan_ask", %{"i" => i, "instruction" => instruction}, socket) do
    {:noreply, socket |> assign(plan_asking: nil) |> ask_kiro(String.to_integer(i), instruction)}
  end

  # Kiro's version replaces the task.
  def handle_event("plan_use", %{"title" => title}, socket) do
    with %{status: :done, suggestion: s} <- socket.assigns.plan_improve[title],
         i when is_integer(i) <- Enum.find_index(plan_tasks(socket), &(&1.title == title)) do
      params = Specs.task_params(s)

      socket
      |> update(:plan_improve, &Map.delete(&1, title))
      |> own_change(i, :edit, Specs.edit_plan_task(plan_spec(socket), i, params))
    else
      _ -> {:noreply, update(socket, :plan_improve, &Map.delete(&1, title))}
    end
  end

  def handle_event("plan_discard", %{"title" => title}, socket),
    do: {:noreply, update(socket, :plan_improve, &Map.delete(&1, title))}

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

  # Form values typed as the question's schema asks: numbers and yes/no as such.
  defp typed(fields, key, socket) do
    schema =
      with %{} = run <- socket.assigns.run,
           %Message{} = m <-
             Repo.one(
               from m in Message,
                 where:
                   m.run_id == ^run.id and fragment("?->'elicitation'->>'key'", m.meta) == ^key,
                 limit: 1
             ) do
        get_in(m.meta, ["elicitation", "schema", "properties"]) || %{}
      else
        _ -> %{}
      end

    Map.new(fields, fn {name, value} ->
      {name,
       case {get_in(schema, [name, "type"]), value} do
         {"boolean", v} -> v == "true"
         {"integer", v} -> with {n, _} <- Integer.parse(v), do: n, else: (_ -> v)
         {"number", v} -> with {n, _} <- Float.parse(v), do: n, else: (_ -> v)
         {_, v} -> v
       end}
    end)
  end

  # A task with one line changed in place, as edit_plan_task/3 takes it; :same when
  # nothing changed. An emptied step goes; an empty title or new step changes nothing.
  defp inline_change(task, part, value) do
    params = Specs.task_params(task)
    objective = params["objective"]
    steps = task.details
    checks = Map.get(task, :verify) || []

    case part do
      "title" when value in ["", task.title] -> :same
      "title" -> {:ok, %{params | "title" => value}}
      "objective" when value == objective -> :same
      "objective" -> {:ok, %{params | "objective" => value}}
      "new" when value == "" -> :same
      "new" -> {:ok, %{params | "details" => Enum.join(steps ++ [value], "\n")}}
      "newcheck" when value == "" -> :same
      "newcheck" -> {:ok, %{params | "verify" => Enum.join(checks ++ [value], "\n")}}
      "step-" <> j -> line_change(params, "details", steps, String.to_integer(j), value)
      "check-" <> j -> line_change(params, "verify", checks, String.to_integer(j), value)
    end
  end

  # One line of a task's steps or checks changed in place; emptied, it goes.
  defp line_change(params, field, lines, j, value) do
    cond do
      Enum.at(lines, j) == value -> :same
      value == "" -> {:ok, %{params | field => Enum.join(List.delete_at(lines, j), "\n")}}
      true -> {:ok, %{params | field => Enum.join(List.replace_at(lines, j, value), "\n")}}
    end
  end

  # The run's spec, where its plan lives; followed while the chat is open, so Kiro's
  # work on a task and every change to the plan show here.
  defp load_plan(socket) do
    run = socket.assigns.run

    {run, spec} =
      cond do
        run == nil ->
          {nil, nil}

        run.spec_id ->
          {run, Specs.get_spec(run.spec_id)}

        # A plan whose spec was deleted (on the Specs page) comes back from the chat's
        # own copy of it, so its tasks aren't lost while the chat is being planned.
        run.status == "draft" and run.tasks != [] ->
          spec = Specs.for_run(run)
          {Runs.get_run(run.id), spec}

        true ->
          {run, nil}
      end

    socket = assign(socket, run: run)
    old = socket.assigns.plan_sub

    if connected?(socket) and old != (spec && spec.id) do
      if old, do: Phoenix.PubSub.unsubscribe(Factory.PubSub, "spec:#{old}")
      if spec, do: Specs.subscribe(spec.id)
    end

    assign(socket,
      plan_check: latest_check(run, socket.assigns[:planner]),
      plan_before: if(old == (spec && spec.id), do: socket.assigns[:plan_before]),
      plan_spec: spec,
      plan_sub: spec && spec.id,
      plan_editing: nil,
      plan_asking: nil,
      plan_improve: %{},
      plan_inline: nil
    )
  end

  # The planner's latest reply, when it's a scope check: the report the plan shows.
  defp latest_check(nil, _planner), do: nil
  defp latest_check(_run, nil), do: nil

  defp latest_check(run, planner) do
    last =
      Repo.one(
        from m in Message,
          where:
            m.run_id == ^run.id and not is_nil(m.author) and
              fragment("?->>'agent_id'", m.meta) == ^to_string(planner.id),
          order_by: [desc: m.id],
          limit: 1
      )

    if last && last.meta["check"], do: last
  end

  defp plan_spec(socket),
    do: socket.assigns.plan_spec && Specs.get_spec(socket.assigns.plan_spec.id)

  defp plan_tasks(%{assigns: %{plan_spec: nil}}), do: []

  defp plan_tasks(%{assigns: %{plan_spec: spec}}),
    do: spec.tasks |> Kernel.||("") |> Factory.Spec.blocks() |> elem(1)

  defp plan_changed(socket, {:ok, spec}), do: {:noreply, assign(socket, plan_spec: spec)}

  defp plan_changed(socket, {:error, :locked}),
    do:
      {:noreply,
       put_flash(
         socket,
         :error,
         "The tasks are approved on the Spec page: reopen them there to change them."
       )}

  defp plan_changed(socket, {:error, :blank_title}),
    do: {:noreply, put_flash(socket, :error, "A task needs a title.")}

  defp plan_changed(socket, _error),
    do: {:noreply, put_flash(socket, :error, "That task changed meanwhile. Try again.")}

  # The plan as it was before the planner reworks it (FactoryWeb.PlanDiff), so the
  # panel can mark in gold what it changed. Only a plan that has tasks is kept.
  defp remember_plan(socket) do
    case plan_tasks(socket) do
      [] -> socket
      tasks -> assign(socket, plan_before: FactoryWeb.PlanDiff.snapshot(tasks))
    end
  end

  # A change the person made to task `i`: saved, and taken into the snapshot, so it
  # isn't marked as the planner's.
  defp own_change(socket, i, how, {:ok, spec} = result) do
    after_tasks = spec.tasks |> Kernel.||("") |> Factory.Spec.blocks() |> elem(1)

    before =
      FactoryWeb.PlanDiff.accept(
        socket.assigns.plan_before,
        plan_tasks(socket),
        after_tasks,
        i,
        how
      )

    socket |> assign(plan_before: before) |> plan_changed(result)
  end

  defp own_change(socket, _i, _how, result), do: plan_changed(socket, result)

  defp ask_kiro(socket, i, instruction) do
    with %{} = spec <- plan_spec(socket),
         {:ok, title} <- Specs.improve_task(spec, i, instruction) do
      entry = %{status: :thinking, activity: nil, suggestion: nil, error: nil}
      update(socket, :plan_improve, &Map.put(&1, title, entry))
    else
      _ -> put_flash(socket, :error, "That task changed meanwhile. Try again.")
    end
  end

  # The plan panel shows while the run is being planned, in the All view, once there are
  # tasks. It stays while the planner reworks them, showing what it's doing.
  defp show_plan?(assigns) do
    run = assigns.run

    run != nil and run.status == "draft" and assigns.focus == nil and
      assigns.plan_spec != nil and run.tasks != []
  end

  # What the planner is doing right now, for the panel's header; nil when it's idle.
  defp planner_activity(assigns) do
    with %{id: id} <- assigns.planner,
         %{} = chunk <- assigns.streaming[id] do
      chunk[:activity] || "Working on the plan…"
    else
      _ -> nil
    end
  end

  # No base specs and no requirements of its own: offer to add some.
  defp plan_spec_hint?(assigns),
    do: assigns.base_ids == [] and String.trim(assigns.plan_spec.requirements || "") == ""

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
  # The run's spec (FactoryWeb.PlanPanel): the plan changed, or Kiro is working on a task.
  def handle_info({:spec_updated, %{id: id} = spec}, %{assigns: %{plan_sub: id}} = socket),
    do: {:noreply, assign(socket, plan_spec: spec)}

  def handle_info({:task_activity, title, text}, socket) do
    {:noreply,
     update(socket, :plan_improve, fn improve ->
       if improve[title], do: put_in(improve, [title, :activity], text), else: improve
     end)}
  end

  def handle_info({:task_improved, title, result}, socket) do
    {:noreply,
     update(socket, :plan_improve, fn improve ->
       case {improve[title], result} do
         {nil, _} -> improve
         {e, {:ok, s}} -> Map.put(improve, title, %{e | status: :done, suggestion: s})
         {e, {:error, why}} -> Map.put(improve, title, %{e | status: :error, error: why})
       end
     end)}
  end

  # The spec's other news is for the Spec page.
  def handle_info({event, _}, socket) when event in [:spec_updated, :plan_activity],
    do: {:noreply, socket}

  def handle_info({event, _, _}, socket) when event in [:draft_activity, :task_drafted],
    do: {:noreply, socket}

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
    # An agent's final reply replaces its live bubble; the planner's ends a scope check.
    socket = update(socket, :streaming, &Map.delete(&1, message.meta["agent_id"]))

    # The planner's latest reply: a scope check shows in the plan until the next one.
    socket =
      if socket.assigns.planner && message.author &&
           message.meta["agent_id"] == socket.assigns.planner.id,
         do:
           assign(socket,
             plan_checking: false,
             plan_check: if(message.meta["check"], do: message)
           ),
         else: socket

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
    # A draft's spec is made when planning starts: follow it from then on.
    socket = if run.spec_id != socket.assigns.plan_sub, do: load_plan(socket), else: socket
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
        # The planner's live bubble gives way to the plan panel, which shows its work.
        live:
          for(
            {id, s} <- assigns.streaming,
            assigns.focus == nil or assigns.focus.id == id,
            not (show_plan?(assigns) and assigns.planner != nil and assigns.planner.id == id),
            do: s
          )
      )

    ~H"""
    <Layouts.app flash={@flash} usage={@usage_meter} active_runs={@active_runs} active={:chat} full>
      <div id="chat-page" phx-hook="ChatKeys" class="flex h-full flex-col bg-base-100">
        <header class="flex min-h-11 shrink-0 flex-wrap items-center gap-x-2 gap-y-1 border-b border-base-300 px-4 py-1.5 sm:px-6">
          <.chat_switcher runs={@runs} run={@run} />
          <.folder_button dir={@dir} ok={@dir_ok} warn={@folder_warn} locked={!settable?(@run)} />
          <.workflow_picker
            workflows={@workflows}
            workflow={@workflow}
            locked={!settable?(@run)}
          />
          <%!-- The run's spec: its base specs and its own requirements, design and tasks. --%>
          <button
            id="specs-button"
            type="button"
            phx-click="specs"
            title="Base specs to follow, and this run's own spec and tasks"
            class={[
              "flex h-6 items-center gap-1.5 rounded-md border px-2 text-[13px] transition-colors hover:bg-base-content/[0.06]",
              if(spec_count(assigns) > 0 or (@run && @run.tasks != []),
                do: "border-base-300",
                else: "border-dashed border-base-300 text-base-content/60"
              )
            ]}
          >
            <.icon name="hero-document-text-micro" class="size-3.5 text-primary" /> Spec
            <span
              :if={@run && @run.tasks != []}
              class="tabular-nums text-base-content/50"
              title="Tasks done, of all"
            >
              {Enum.count(@run.tasks, &(&1.status == "done"))}/{length(@run.tasks)}
            </span>
          </button>

          <div class="ml-auto flex min-w-0 items-center gap-2">
            <.run_steps steps={@steps} focus={@focus} run={@run} />
            <Layouts.status_badge :if={@run && @run.status != "draft"} status={@run.status} />
            <.run_control run={@run} />
            <.more_menu view={@view} run={@run} workflow={@workflow} />
          </div>
        </header>

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
              class="mx-auto flex max-w-3xl flex-col gap-5 px-5 pt-6"
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
            <div :if={show_plan?(assigns)} class="mx-auto max-w-3xl px-5 pt-5">
              <FactoryWeb.PlanPanel.panel
                run={@run}
                tasks={plan_tasks(%{assigns: assigns})}
                editing={@plan_editing}
                asking={@plan_asking}
                improve={@plan_improve}
                inline={@plan_inline}
                working={planner_activity(assigns)}
                checking={@plan_checking}
                check={@plan_check}
                before={@plan_before}
                spec_hint={plan_spec_hint?(assigns)}
              />
            </div>
            <div :if={@live != []} class="mx-auto flex max-w-3xl flex-col gap-5 px-5 pt-5">
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
              planner={@planner}
              glow={@empty and @dir_ok and @focus == nil}
            />
          </div>

          <div class="pointer-events-none absolute inset-3 z-20 hidden place-items-center rounded-xl border-2 border-dashed border-primary/60 bg-base-100/85 backdrop-blur-sm group-[.phx-drop-target-active]:grid">
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
          class="relative w-full max-w-xl overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-2xl"
        >
          <FactoryWeb.SourceParts.browser browser={@browser} />
        </.focus_wrap>
      </div>
    </Layouts.app>
    """
  end
end
