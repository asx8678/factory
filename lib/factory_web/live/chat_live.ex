defmodule FactoryWeb.ChatLive do
  use FactoryWeb, :live_view
  import Ecto.Query, only: [from: 2]
  alias Factory.{Agents, Chat, Engine, FileBrowser, Kiro, Runs, Workflows}
  alias Factory.Repo
  alias Factory.Runs.Message
  alias FactoryWeb.ChatLive.Plan
  alias FactoryWeb.FolderBrowser
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

    # A new run starts clean: no folder and no specs until you choose them. What the
    # chat is on (its run, workflow, agents and folder) is loaded once, by handle_params.
    # The workflow list can make the standard workflows, so it waits for the connection.
    {:ok,
     socket
     |> assign(runs: Runs.list_runs(), runs_reload: nil, run: nil, focus: nil, count: 0)
     |> assign(draft: "", view: "chat", streaming: %{})
     |> assign(message_ids: [], earlier?: false, history?: false)
     |> assign(commands: Chat.commands())
     |> assign(workflows: if(connected?(socket), do: Workflows.list(), else: []))
     |> assign(browser: nil, folder_warn: false, to: nil)
     |> assign(scout: nil, ideas: nil, cloning: nil, clone_error: nil, folder_error: nil)
     |> assign(review_step: nil)
     |> assign(pick: nil, workflow: nil, planner: nil, graph: nil, agents: [], steps: [])
     |> assign(dir: "", dir_ok: false, base_ids: [])
     |> assign(
       plan_spec: nil,
       plan_tasks: [],
       plan_sub: nil,
       plan_editing: nil,
       plan_asking: nil,
       plan_improve: %{},
       plan_inline: nil,
       plan_checking: false,
       plan_check: nil,
       plan_before: nil
     )
     |> assign(empty: true, live: [], spec_count: 0, show_plan: false)
     |> assign(plan_working: nil, plan_spec_hint: false)
     |> assign(form: to_form(%{"body" => ""}, as: :chat))
     # Spec files; in troubleshooting, the logs and exports to search as well.
     |> allow_upload(:spec,
       accept: ~w(.md .markdown .txt .log .json .csv),
       max_entries: 5,
       max_file_size: 20_000_000
     )}
  end

  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        socket =
          socket
          |> watch(nil)
          |> FactoryWeb.UsageMeter.scope(:today)
          |> assign(run: nil, pick: picked(socket), base_ids: [])
          # A new chat works in the folder picked last, until another is picked.
          |> set_dir(Factory.Prefs.project_dir())
          |> load_agents()
          |> job_dir()

        focus = chat_agent(socket, params["agent"])

        {:noreply,
         socket
         |> assign(page_title: (focus && focus.name) || "Chat", focus: focus, count: 0)
         |> assign(streaming: %{})
         |> assign(message_ids: [], earlier?: false, history?: false)
         |> stream(:messages, [], reset: true, limit: -@message_limit)
         |> Plan.load()
         |> derive()
         |> scout()}

      id ->
        case Runs.get_run(id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "That chat no longer exists.")
             |> push_navigate(to: ~p"/chat")}

          run ->
            socket =
              socket
              |> watch(run)
              |> FactoryWeb.UsageMeter.scope({:run, run.id})
              |> assign(run: run)
              |> keep_dir(run)
              |> assign(base_ids: run.settings["base_spec_ids"] || [])
              |> load_agents()
              |> job_dir()

            {:noreply,
             socket
             |> assign(page_title: run.title, focus: chat_agent(socket, params["agent"]))
             |> assign(streaming: %{})
             |> load_messages()
             |> Plan.load()
             |> derive()
             |> scout()}
        end
    end
  end

  # The workflow a new chat plans for. Picking one can make it the current workflow
  # (Workflows.picked/0 writes), so the first, disconnected render only reads it.
  defp picked(socket),
    do: if(connected?(socket), do: Workflows.picked(), else: Workflows.current())

  # The agent the chat is narrowed to: one of its own agents, else none. Action cards
  # and agents of other workflows aren't agents to chat with here.
  defp chat_agent(_socket, nil), do: nil

  defp chat_agent(socket, id),
    do: Enum.find(socket.assigns.agents, &(to_string(&1.id) == to_string(id)))

  # The agents this chat talks to: the run's workflow, or the current one. `steps` are
  # the workflow's steps as the run follows them, for the map above the chat.
  # Messages go to `to` (the workflow's planner unless another is picked), or to the
  # agent the chat is focused on.
  defp load_agents(socket) do
    run = socket.assigns[:run]
    own = run && Workflows.for_run(run)
    # A finished run can outlive its workflow; show the current one (Chat refuses to run it).
    workflow = if run, do: own || Workflows.current(), else: socket.assigns.pick

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
      # A run whose workflow is gone has no steps to show (Engine.steps/1).
      steps: if(run && !own, do: [], else: Engine.workflow_steps(workflow.id))
    )
  end

  # What the page shows that follows from other assigns, kept as assigns of its own so
  # a render only redoes what changed: a streamed reply or a keystroke in the message
  # box doesn't redraw the plan. Called wherever one of its inputs changes: the run, the
  # focus, the message count, the replies streaming in, the base specs, the plan's
  # spec, the planner or the workflow.
  defp derive(socket) do
    a = socket.assigns
    show_plan = Plan.show?(a)

    assign(socket,
      empty: a.count == 0 and a.streaming == %{},
      review_step: review_step(a),
      spec_count: spec_count(a),
      show_plan: show_plan,
      plan_working: Plan.working(a),
      plan_spec_hint: show_plan and Plan.spec_hint?(a),
      # The planner's live bubble gives way to the plan panel, which shows its work.
      live:
        for(
          {id, s} <- a.streaming,
          a.focus == nil or a.focus.id == id,
          not (show_plan and a.planner != nil and a.planner.id == id),
          do: s
        )
    )
  end

  # Review a PR goes in steps: choose the repository (`:source`), see what's worth
  # reviewing in it (`:analysis`), then the review itself (`:review`, its messages).
  # Worked out from what's saved, so a reload lands on the same step. The folder new
  # chats remember isn't a choice: only a review run keeps the repository it's for.
  defp review_step(a) do
    cond do
      a.workflow == nil or Workflows.kind(a.workflow) != "review" -> nil
      # A chat with one agent is just that chat.
      a.focus != nil -> nil
      a.count > 0 -> :review
      a.run != nil and a.run.kind == "review" and a.dir_ok -> :analysis
      true -> :source
    end
  end

  # Specs on this run: its base specs, and its own spec once something is written in it.
  defp spec_count(assigns) do
    own = if assigns.run && assigns.run.spec_files != [], do: 1, else: 0
    length(assigns.base_ids) + own
  end

  defp default_to(agents),
    do: Enum.find(agents, &(&1.kind == "planner")) || List.first(agents) || :factory

  # A message that's only a repository's or pull request's link (not a local path), in
  # a review chat nothing has been said in yet.
  defp review_link?(socket, body) do
    text = String.trim(body || "")

    Workflows.kind(socket.assigns.workflow) == "review" and socket.assigns[:count] in [nil, 0] and
      socket.assigns.focus == nil and text != "" and not String.contains?(text, [" ", "\n"]) and
      not String.starts_with?(text, ["/", "~", "file://"]) and
      match?({:ok, _}, Factory.Repos.parse(text))
  end

  # A new chat looks at its folder in the background (Factory.Scout): for a review, what
  # there is to review; otherwise what there is to pick up (unfinished work, notes in the
  # code), for its suggestions.
  defp scout(socket) do
    review? = Workflows.kind(socket.assigns.workflow) == "review"
    fresh? = socket.assigns[:count] in [nil, 0]
    look? = connected?(socket) and fresh? and socket.assigns.dir_ok
    dir = Path.expand(socket.assigns.dir || "")

    cond do
      not look? ->
        assign(socket, scout: nil, ideas: nil)

      # Nothing's looked at before the repository is chosen.
      review? and socket.assigns.review_step != :analysis ->
        assign(socket, scout: nil, ideas: nil)

      # Troubleshooting starts from the problem, not from what the folder suggests.
      incident?(socket) ->
        assign(socket, scout: nil, ideas: nil)

      review? ->
        socket
        |> assign(scout: :loading, ideas: nil)
        |> start_async(:scout, fn -> {dir, Factory.Scout.scout(dir)} end)

      true ->
        socket
        |> assign(scout: nil)
        |> start_async(:ideas, fn -> {dir, Factory.Scout.ideas(dir)} end)
    end
  end

  # A run keeps its folder. One still being planned that has none yet takes the folder
  # picked last, like a new chat.
  defp keep_dir(socket, run) do
    dir = run.settings["project_dir"] || (settable?(run) && Factory.Prefs.project_dir())
    set_dir(socket, dir || "")
  end

  # The folder follows the workflow. Troubleshooting works from what's pasted (logs
  # only) until a repository is chosen for it, so it doesn't take the folder picked
  # last; the others start a new chat in that one (`keep_dir/2`).
  defp job_dir(socket) do
    run = socket.assigns.run
    saved = run && String.trim(run.settings["project_dir"] || "")
    saved = if saved in [nil, ""], do: nil, else: saved

    cond do
      incident?(socket) -> set_dir(socket, saved || "")
      saved != nil -> socket
      socket.assigns.dir == "" and settable?(run) -> set_dir(socket, Factory.Prefs.project_dir())
      true -> socket
    end
  end

  defp incident?(socket),
    do: socket.assigns.workflow != nil and Workflows.kind(socket.assigns.workflow) == "incident"

  defp set_dir(socket, dir) do
    dir = String.trim(dir || "")
    assign(socket, dir: dir, dir_ok: dir != "" and File.dir?(Path.expand(dir)))
  end

  defp save_setting(%{assigns: %{run: nil}} = socket, _key, _value), do: socket

  defp save_setting(%{assigns: %{run: run}} = socket, key, value) do
    {:ok, run} = Runs.update_run(run, %{settings: Map.put(run.settings, key, value)})
    assign(socket, run: run)
  end

  # Follow only the open run's messages. What was open for the last run doesn't come
  # along to the next: a clone under way, the folder window, the folder warning.
  defp watch(socket, run) do
    old = socket.assigns.run

    if (old && old.id) != (run && run.id) do
      if connected?(socket) do
        if old, do: Runs.unsubscribe(old.id)
        if run, do: Runs.subscribe(run.id)
      end

      assign(socket,
        cloning: nil,
        clone_error: nil,
        folder_error: nil,
        browser: nil,
        folder_warn: false
      )
    else
      socket
    end
  end

  defp load_messages(socket) do
    {messages, earlier?} = message_page(socket, @message_limit)

    socket
    |> assign(
      count: length(messages),
      message_ids: Enum.map(messages, & &1.id),
      earlier?: earlier?,
      history?: false
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

    stream(socket, :messages, messages, limit: -@message_limit)
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
       |> derive()
       |> stream(:messages, Enum.reverse(messages), at: 0, limit: @message_limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("latest", _, socket) do
    socket = if socket.assigns.run, do: socket |> load_messages() |> derive(), else: socket
    {:noreply, push_event(socket, "chat:latest", %{})}
  end

  # Commands work anywhere; anything for the agents needs the folder they work in.
  # In a review that hasn't started, a repository or pull request link in the message
  # box is cloned (or fetched) like one pasted in the card, rather than sent on.
  def handle_event("send", %{"chat" => %{"body" => body}} = params, socket) do
    if review_link?(socket, body) do
      socket = socket |> assign(draft: "") |> push_event("chat:sent", %{})
      handle_event("review_link", %{"link" => String.trim(body)}, socket)
    else
      send_chat(params, socket)
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
         |> load_agents()
         |> job_dir()
         |> derive()
         |> scout()}
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

  # Review a PR: a pull request's link, or a branch the scout found, goes to the Scout
  # as a message, as if it were typed.
  def handle_event("review_pr", %{"url" => url}, socket) do
    url = String.trim(url || "")

    cond do
      not socket.assigns.dir_ok ->
        {:noreply,
         socket
         |> assign(folder_warn: true)
         |> put_flash(:error, "Choose the project folder first: the review reads its code.")}

      Regex.match?(~r{^https?://\S+/pull/\d+}, url) or Regex.match?(~r/^#?\d+$/, url) ->
        send_message(socket, "Review the pull request #{url}.")

      true ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Paste a pull request's link, like https://github.com/owner/repo/pull/12."
         )}
    end
  end

  # A repository's link: Factory clones it with SSH (or fetches it again) into its own
  # folder, then the chat opens on it with its branches listed (Factory.Repos).
  def handle_event("review_link", %{"link" => link}, socket) do
    case Factory.Repos.parse(link) do
      {:ok, repo} ->
        {:noreply,
         socket
         |> assign(cloning: repo.label, clone_error: nil)
         |> start_async(:clone, fn -> Factory.Repos.clone(link) end)}

      {:error, reason} ->
        {:noreply, assign(socket, clone_error: reason)}
    end
  end

  # Another repository: back to the first step, in a new chat. The one left behind
  # has no messages, so it's reused for that repository or cleared away later.
  def handle_event("review_change", _, socket) do
    if socket.assigns.workflow, do: Workflows.set_current(socket.assigns.workflow)
    {:noreply, push_navigate(socket, to: ~p"/chat")}
  end

  def handle_event("review_branch", %{"branch" => branch}, socket) do
    with {:ok, %{branches: branches}} <- socket.assigns.scout,
         %{} = b <- Enum.find(branches, &(&1.name == branch)) do
      against = if b.base && b.base != branch, do: " against `#{b.base}`", else: ""

      latest =
        if b.ahead && b.ahead > 0,
          do:
            ": #{b.ahead} #{if b.ahead == 1, do: "commit", else: "commits"}, the latest “#{b.subject}”",
          else: ""

      what =
        case Regex.run(~r/^pr-(\d+)$/, b.label) do
          [_, n] -> "Review pull request ##{n}, fetched as the branch `#{branch}`"
          _ -> "Review the branch `#{branch}`"
        end

      send_message(socket, "#{what}#{against}#{latest}.")
    else
      _ -> {:noreply, put_flash(socket, :error, "That branch isn't there any more. Scout again.")}
    end
  end

  # The work in the folder itself: what isn't committed yet, or the latest commits.
  def handle_event("review_local", %{"what" => what}, socket) do
    case {what, socket.assigns.scout} do
      {"changes", {:ok, scout}} ->
        send_message(socket, "Review the uncommitted changes on `#{scout.current}`.")

      {"recent", {:ok, %{recent: [_ | _] = commits} = scout}} ->
        send_message(
          socket,
          "Review the last #{length(commits)} commits on `#{scout.current}`, " <>
            "#{List.last(commits).sha} to #{hd(commits).sha}."
        )

      _ ->
        {:noreply, put_flash(socket, :error, "Look at the branches again first.")}
    end
  end

  def handle_event("scout_again", _, socket), do: {:noreply, scout(socket)}

  def handle_event("browse", _, socket) do
    # This chat's folder, else the one picked last.
    start =
      FileBrowser.start_dir(
        if(socket.assigns.dir_ok, do: socket.assigns.dir, else: Factory.Prefs.project_dir())
      )

    {:noreply, assign(socket, browser: FolderBrowser.open(start))}
  end

  def handle_event(event, params, socket)
      when event in ["browse_go", "browse_hidden", "browse_cancel"],
      do: FolderBrowser.handle_event(event, params, socket)

  # In a review not yet under way, the folder picked is the repository to review; in
  # troubleshooting, the repository whose code the agents search.
  def handle_event("browse_pick", %{"path" => path}, %{assigns: %{review_step: step}} = socket)
      when step in [:source, :analysis],
      do: pick_repository(socket, path)

  def handle_event(
        "browse_pick",
        %{"path" => path},
        %{assigns: %{workflow: %{key: "incident"}}} = socket
      ),
      do: pick_repository(socket, path)

  def handle_event("browse_pick", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(browser: nil, folder_warn: false)
     |> tap(fn _ -> Factory.Prefs.remember_project_dir(path) end)
     |> set_dir(path)
     |> save_setting("project_dir", Path.expand(path))
     |> derive()
     |> scout()}
  end

  # Troubleshooting from what's pasted only again: the repository is set aside.
  def handle_event("without_code", _, socket) do
    {:noreply,
     socket
     |> save_setting("project_dir", nil)
     |> set_dir("")
     |> assign(folder_error: nil, clone_error: nil)
     |> derive()}
  end

  # Fix it, under a finished troubleshooting run: on to a Fix a bug chat about it.
  def handle_event("fix_it", _, %{assigns: %{run: %{status: "done"} = run}} = socket) do
    {:ok, fix} = Chat.fix_it(run)
    {:noreply, push_navigate(socket, to: ~p"/chat/#{fix.id}")}
  end

  def handle_event("fix_it", _, socket), do: {:noreply, socket}

  def handle_event("action", %{"action" => action}, socket) do
    Chat.action(Runs.get_run(socket.assigns.run.id), action)
    {:noreply, socket}
  end

  # Try again under a failure: what Kiro couldn't take goes again (`Factory.Chat.retry/2`).
  def handle_event("retry", %{"id" => id}, socket) do
    with %{} = run <- socket.assigns.run,
         {id, ""} <- Integer.parse(to_string(id)),
         %Message{} = message <- Repo.get(Message, id) do
      Chat.retry(Runs.get_run(run.id), message)
    end

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
      for {%{} = q, i} <- Enum.with_index(List.wrap(message && message.meta["questions"])),
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

  # The plan being made (FactoryWeb.ChatLive.Plan, shown by FactoryWeb.PlanPanel).
  def handle_event("plan_" <> _ = event, params, socket),
    do: derived(Plan.handle_event(event, params, socket))

  def handle_event("use_command", %{"cmd" => cmd}, socket) do
    {:noreply,
     socket |> assign(draft: cmd <> " ") |> push_event("chat:fill", %{text: cmd <> " "})}
  end

  def handle_event("view", %{"view" => view}, socket) when view in ["chat", "graph"],
    do: {:noreply, assign(socket, view: view)}

  # A click on an agent in the graph opens a chat with just that agent. A click on an
  # action card does nothing here: actions are steps, not agents to talk to.
  def handle_event("select", %{"id" => id}, socket) do
    case chat_agent(socket, id) do
      nil ->
        {:noreply, socket}

      agent ->
        {:noreply,
         socket |> assign(view: "chat") |> push_patch(to: chat_path(socket.assigns.run, agent))}
    end
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

  # Form values typed as the question's schema asks: numbers and yes/no as such. The
  # schema comes from another MCP server as it wrote it, so anything odd is left as text.
  defp typed(fields, key, socket) do
    schema =
      with %{} = run <- socket.assigns.run,
           %Message{meta: %{"elicitation" => %{"schema" => %{"properties" => %{} = props}}}} <-
             Repo.one(
               from m in Message,
                 where:
                   m.run_id == ^run.id and fragment("?->'elicitation'->>'key'", m.meta) == ^key,
                 limit: 1
             ) do
        props
      else
        _ -> %{}
      end

    Map.new(fields, fn {name, value} ->
      {name,
       case {field_type(schema[name]), value} do
         {"boolean", v} -> v == "true"
         {"integer", v} -> with {n, _} <- Integer.parse(v), do: n, else: (_ -> v)
         {"number", v} -> with {n, _} <- Float.parse(v), do: n, else: (_ -> v)
         {_, v} -> v
       end}
    end)
  end

  defp field_type(%{"type" => type}), do: type
  defp field_type(_prop), do: nil

  # A plan event or news, then what the page derives from the plan.
  defp derived({:noreply, socket}), do: {:noreply, derive(socket)}

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

  defp send_chat(%{"chat" => %{"body" => body}}, socket) do
    # Troubleshooting works from what's pasted: its repository is optional.
    if socket.assigns.dir_ok or incident?(socket) or String.starts_with?(String.trim(body), "/") do
      socket =
        if String.starts_with?(String.trim(body), "/"), do: socket, else: Plan.remember(socket)

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

  defp send_message(socket, body) do
    files =
      consume_uploaded_entries(socket, :spec, fn %{path: path}, entry ->
        {:ok, {entry.client_name, File.read!(path)}}
      end)

    # A file named .txt may still not be text; it's set aside, not stored.
    {files, binary} = Enum.split_with(files, fn {_name, text} -> String.valid?(text) end)

    socket =
      if binary == [],
        do: socket,
        else:
          put_flash(
            socket,
            :error,
            "#{Enum.map_join(binary, ", ", &elem(&1, 0))} isn't a text file, so it wasn't attached."
          )

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

  # The scout's answer, for the folder the chat is still on.
  def handle_async(:scout, {:ok, {dir, result}}, socket) do
    if socket.assigns.dir_ok and Path.expand(socket.assigns.dir) == dir,
      do: {:noreply, assign(socket, scout: result)},
      else: {:noreply, socket}
  end

  def handle_async(:scout, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, scout: {:error, "Couldn't read the folder's branches."})}

  # A clone the chat was moved away from (to another run) is left be: its folder is
  # there, and pasting the link again fetches it.
  def handle_async(:clone, _result, %{assigns: %{cloning: nil}} = socket),
    do: {:noreply, socket}

  # Cloned (or fetched): the chat becomes a review of that repository, kept as a run
  # of its own with the clone as its folder, so it's there after a reload. The folder
  # picked for new chats stays as it was.
  def handle_async(:clone, {:ok, {:ok, cloned}}, socket) do
    said =
      if cloned.fresh,
        do: "Cloned #{cloned.label}.",
        else: "Fetched the latest of #{cloned.label}."

    {:noreply,
     socket
     |> assign(cloning: nil, clone_error: nil)
     |> put_flash(:info, said)
     # A pull request's link: its branch leads what's worth reviewing.
     |> open_review(cloned.dir, cloned.label, "clone", cloned[:pr_branch])}
  end

  def handle_async(:clone, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, cloning: nil, clone_error: reason)}

  def handle_async(:clone, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, cloning: nil, clone_error: "The clone stopped unexpectedly.")}

  def handle_async(:ideas, {:ok, {dir, ideas}}, socket) do
    if socket.assigns.dir_ok and Path.expand(socket.assigns.dir) == dir,
      do: {:noreply, assign(socket, ideas: ideas)},
      else: {:noreply, socket}
  end

  def handle_async(:ideas, {:exit, _reason}, socket), do: {:noreply, assign(socket, ideas: [])}

  # A folder picked as the repository to review or to search: its repository (a folder
  # picked inside one is all of it), or why it won't do.
  defp pick_repository(socket, path) do
    case Factory.Scout.repository(path) do
      {:ok, top} ->
        Factory.Prefs.remember_project_dir(top)
        label = Factory.Repos.label(top) || Path.basename(top)
        source = if Factory.Repos.label(top), do: "clone", else: "local"

        {:noreply,
         socket
         |> assign(browser: nil, folder_warn: false, folder_error: nil)
         |> open_review(top, label, source)}

      {:error, reason} ->
        {:noreply,
         assign(socket, browser: nil, folder_error: "#{Path.basename(path)}: #{reason}")}
    end
  end

  # The chat becomes a review of the repository in `dir`: a run of its own with the
  # folder saved, so a reload opens on what's in it (the analysis step). A draft chat
  # being set up becomes it; else an unused review of that folder, or a new one.
  # `source` is where it came from ("clone" or "local"); `pr_branch` a pull request's
  # branch fetched with it, suggested first.
  defp open_review(socket, dir, label, source, pr_branch \\ nil) do
    incident? = incident?(socket)

    run =
      case socket.assigns.run do
        %{status: "draft"} = run -> run
        _ when incident? -> elem(Runs.create_run("Troubleshoot #{label}"), 1)
        _ -> Runs.unused_review(dir) || elem(Runs.create_run("Review #{label}"), 1)
      end

    # A review is named after its repository. Troubleshooting is named after the problem
    # once it's described (`Factory.Runs.Titles`), so its title is left to that.
    named =
      if incident?,
        do: %{kind: "incident"},
        else: %{kind: "review", title: "Review #{label}"}

    settings =
      %{
        "workflow_id" => socket.assigns.workflow.id,
        "base_spec_ids" => socket.assigns.base_ids,
        "project_dir" => dir,
        "review_source" => source,
        "review_pr_branch" => pr_branch
      }
      |> Map.merge(if incident?, do: %{}, else: %{"title" => "manual"})

    {:ok, run} =
      Runs.update_run(run, Map.put(named, :settings, Map.merge(run.settings || %{}, settings)))

    push_patch(socket, to: ~p"/chat/#{run.id}")
  end

  # The run's spec, where the plan lives (FactoryWeb.ChatLive.Plan): the plan changed,
  # or Kiro is working on one of its tasks.
  def handle_info({:spec_updated, %{id: id}} = msg, %{assigns: %{plan_sub: id}} = socket),
    do: derived(Plan.handle_info(msg, socket))

  def handle_info({event, _, _} = msg, socket) when event in [:task_activity, :task_improved],
    do: derived(Plan.handle_info(msg, socket))

  # The spec's other news is for the Spec page.
  def handle_info({event, _}, socket) when event in [:spec_updated, :plan_activity],
    do: {:noreply, socket}

  def handle_info({event, _, _}, socket) when event in [:draft_activity, :task_drafted],
    do: {:noreply, socket}

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

  # A message or update queued from the run the chat has just left (before it stopped
  # following it) belongs to that run, not the open one.
  def handle_info({:message, %{run_id: id} = message}, %{assigns: %{run: %{id: id}}} = socket) do
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
       |> derive()
       |> stream_insert(:messages, message, limit: -@message_limit)}
    else
      {:noreply, derive(socket)}
    end
  end

  def handle_info({:message, _message}, socket), do: {:noreply, socket}

  # Only this run's: a chunk sent before the page moved to another run is dropped.
  def handle_info(
        {:agent_stream, %{run_id: run_id, agent_id: id} = chunk},
        %{assigns: %{run: %{id: run_id}}} = socket
      ) do
    {:noreply, socket |> update(:streaming, &Map.put(&1, id, chunk)) |> derive()}
  end

  def handle_info({:agent_stream, _chunk}, socket), do: {:noreply, socket}

  # Re-render messages when the status changes so buttons like "Start run" disappear once used.
  # A new plan's tasks, too: only the latest plan offers to implement.
  def handle_info({:run_updated, %{id: id} = run}, %{assigns: %{run: %{id: id} = old}} = socket) do
    changed =
      old.status != run.status or
        Enum.map(old.tasks, & &1.title) != Enum.map(run.tasks, & &1.title)

    socket = assign(socket, run: run, page_title: run.title)
    # A draft's spec is made when planning starts: follow it from then on.
    socket = if run.spec_id != socket.assigns.plan_sub, do: Plan.load(socket), else: socket
    socket = derive(socket)
    {:noreply, if(changed, do: refresh_messages(socket), else: socket)}
  end

  def handle_info({:run_updated, _run}, socket), do: {:noreply, socket}

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
         socket
         |> assign(
           graph: graph,
           agents: swap.(socket.assigns.agents),
           steps: steps,
           focus: if(focus && focus.id == agent.id, do: agent, else: focus)
         )
         |> derive()}
    end
  end

  def handle_info({:graph_changed}, socket) do
    %{assigns: %{graph: graph, agents: agents}} = socket = load_agents(socket)
    focus = socket.assigns.focus && Enum.find(agents, &(&1.id == socket.assigns.focus.id))

    {:noreply,
     socket
     |> assign(graph: graph, agents: agents, focus: focus)
     |> derive()
     |> push_event("flow:graph", graph)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      usage={@usage_meter}
      active_runs={@active_runs}
      kiro={@kiro}
      active={:chat}
      full
    >
      <div id="chat-page" phx-hook="ChatKeys" class="flex h-full flex-col bg-base-100">
        <header class="flex min-h-11 shrink-0 flex-wrap items-center gap-x-2 gap-y-1 border-b border-base-300 px-4 py-1.5 sm:px-6">
          <.chat_switcher runs={@runs} run={@run} />
          <.folder_button
            dir={@dir}
            ok={@dir_ok}
            warn={@folder_warn}
            locked={!settable?(@run)}
            pending={
              cond do
                @review_step == :source -> "No repository yet"
                @workflow && Workflows.kind(@workflow) == "incident" && !@dir_ok -> "No repository"
                true -> nil
              end
            }
          />
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
              if(@spec_count > 0 or (@run && @run.tasks != []),
                do: "border-base-300",
                else: "border-dashed border-base-300 text-base-content/60"
              )
            ]}
          >
            <.icon name="hero-document-text-micro" class="size-3.5 text-base-content/55" /> Spec
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
            <div :if={@show_plan} class="mx-auto max-w-3xl px-5 pt-5">
              <FactoryWeb.PlanPanel.panel
                run={@run}
                tasks={@plan_tasks}
                editing={@plan_editing}
                asking={@plan_asking}
                improve={@plan_improve}
                inline={@plan_inline}
                working={@plan_working}
                checking={@plan_checking}
                check={@plan_check}
                before={@plan_before}
                job={Workflows.kind(@workflow)}
                builders={for a <- @agents, not Factory.Agents.Agent.read_only?(a), do: a.name}
                spec_hint={@plan_spec_hint}
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

          <%!-- Room below for the message box, which isn't there while a review's repository is chosen. --%>
          <div
            :if={@empty}
            class={[
              "flex min-h-0 flex-1 items-center justify-center overflow-hidden px-4",
              if(@review_step == :source, do: "pb-12", else: "pb-40")
            ]}
          >
            <.greeting
              focus={@focus}
              to={@to}
              dir={@dir}
              dir_ok={@dir_ok}
              workflow={@workflow}
              uploads={@uploads}
              specs={@spec_count}
              chain={for st <- @steps, st.kind != "action", do: st.name}
              last_run={last_run(@runs, @run)}
              scout={@scout}
              ideas={@ideas}
              cloning={@cloning}
              clone_error={@clone_error}
              folder_error={@folder_error}
              review_step={@review_step}
              run={@run}
            />
          </div>

          <%!-- Choosing the repository to review comes before anything is said. --%>
          <div
            :if={@review_step != :source}
            class="pointer-events-none absolute inset-x-0 bottom-0 bg-linear-to-t from-base-100 from-60% to-transparent px-4 pb-4 pt-10"
          >
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
              job={Workflows.kind(@workflow)}
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
