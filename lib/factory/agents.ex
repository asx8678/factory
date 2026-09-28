defmodule Factory.Agents do
  @moduledoc """
  Agents and the links (hand-offs) between them. Every agent belongs to a workflow
  (`Factory.Workflows`); links only join agents of the same workflow.
  """
  import Ecto.Query
  alias Factory.Repo
  alias Factory.Agents.{Agent, Link}

  @topic "agents:graph"

  @doc "Subscribes the caller to `{:graph_changed}` messages sent after changes made by other processes."
  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, @topic)

  defp changed(result) do
    Phoenix.PubSub.broadcast_from(Factory.PubSub, self(), @topic, {:graph_changed})
    result
  end

  @doc "Every agent, or a workflow's agents."
  def list_agents, do: Repo.all(from a in Agent, order_by: a.id)

  def list_agents(workflow_id),
    do: Repo.all(from a in Agent, where: a.workflow_id == ^workflow_id, order_by: a.id)

  def get_agent(id), do: Repo.get(Agent, id)

  @doc "Creates an agent, in the current workflow unless `workflow_id` says otherwise."
  def create_agent(attrs) do
    attrs = Map.new(attrs)

    attrs =
      if attrs[:workflow_id] || attrs["workflow_id"],
        do: attrs,
        else: Map.put(attrs, :workflow_id, Factory.Workflows.current().id)

    attrs |> insert_agent() |> changed()
  end

  defp insert_agent(attrs), do: %Agent{} |> Agent.changeset(attrs) |> Repo.insert()

  def update_agent(%Agent{} = agent, attrs),
    do: agent |> Agent.changeset(attrs) |> Repo.update() |> changed()

  def change_agent(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)

  @doc "Sets what an agent is doing right now (used by its Kiro session)."
  def set_activity(agent_id, status, activity) do
    from(a in Agent, where: a.id == ^agent_id)
    |> Repo.update_all(
      set: [status: status, activity: activity, updated_at: DateTime.utc_now(:second)]
    )
    |> changed()
  end

  @doc "Tells open pages the graph changed, e.g. when a Kiro session starts or stops."
  def notify_changed, do: changed(:ok)

  @doc """
  Kiro sessions don't survive a restart, so on startup every agent is idle and has no
  context in use. Turns and credits are kept.
  """
  def reset_sessions do
    for agent <- list_agents() do
      usage = Map.drop(agent.usage || %{}, ["context_pct", "context_tokens"])

      from(a in Agent, where: a.id == ^agent.id)
      |> Repo.update_all(set: [usage: usage, status: "idle", activity: nil])
    end

    :ok
  end

  @doc "Stores an agent's usage totals from Kiro (turns, credits, context)."
  def record_usage(agent_id, usage) do
    from(a in Agent, where: a.id == ^agent_id)
    |> Repo.update_all(set: [usage: usage])
    |> changed()
  end

  def delete_agents(ids), do: Repo.delete_all(from a in Agent, where: a.id in ^ids) |> changed()

  @doc "Saves new positions, given as `[%{\"id\" => id, \"x\" => x, \"y\" => y}]`."
  def move_agents(positions) do
    Repo.transact(fn ->
      for %{"id" => id, "x" => x, "y" => y} <- positions do
        from(a in Agent, where: a.id == ^id) |> Repo.update_all(set: [x: x / 1, y: y / 1])
      end

      {:ok, :moved}
    end)
    |> changed()
  end

  @doc """
  Adds an action card (see `Factory.Actions`) to a workflow, optionally after an
  agent (`from:`), with the type's default settings.
  """
  def add_action(workflow_id, type, x, y, opts \\ []) do
    kind = Factory.Actions.get(type)

    Repo.transact(fn ->
      with {:ok, card} <-
             insert_agent(%{
               name: kind.label,
               kind: "action",
               role: kind.blurb,
               action: %{"type" => type, "config" => Factory.Actions.defaults(type)},
               x: x,
               y: y,
               workflow_id: workflow_id
             }),
           :ok <- maybe_link(opts[:from], card.id) do
        {:ok, card}
      end
    end)
    |> changed()
  end

  @doc "Creates an agent in a workflow, optionally linked from or to an existing one."
  def add_agent(workflow_id, x, y, opts \\ []) do
    count = Repo.aggregate(from(a in Agent, where: a.workflow_id == ^workflow_id), :count)

    Repo.transact(fn ->
      with {:ok, agent} <-
             insert_agent(%{name: "Agent #{count + 1}", x: x, y: y, workflow_id: workflow_id}),
           :ok <- maybe_link(opts[:from], agent.id),
           :ok <- maybe_link(agent.id, opts[:to]) do
        {:ok, agent}
      end
    end)
    |> changed()
  end

  defp maybe_link(nil, _), do: :ok
  defp maybe_link(_, nil), do: :ok
  defp maybe_link(source, target), do: with({:ok, _} <- insert_link(source, target), do: :ok)

  def list_links, do: Repo.all(from l in Link, order_by: l.id)

  @doc """
  Links two agents. `handles` names the circles the arrow is attached to,
  e.g. `%{source: "right", target: "left"}`; leave them out for the facing sides.
  """
  def link(source_id, target_id, handles \\ %{}),
    do: insert_link(source_id, target_id, handles) |> changed()

  defp insert_link(source_id, target_id, handles \\ %{}) do
    %Link{}
    |> Link.changeset(%{
      source_id: source_id,
      target_id: target_id,
      source_handle: handles[:source],
      target_handle: handles[:target],
      prompt: handles[:prompt] || ""
    })
    |> Repo.insert(
      on_conflict: {:replace, [:source_handle, :target_handle, :updated_at]},
      conflict_target: [:source_id, :target_id]
    )
  end

  def unlink(source_id, target_id), do: delete_link(source_id, target_id) |> changed()

  defp delete_link(source_id, target_id) do
    Repo.delete_all(
      from l in Link, where: l.source_id == ^source_id and l.target_id == ^target_id
    )
  end

  @doc "Moves one end of a link to a different agent."
  def relink({old_source, old_target}, {source, target}, handles \\ %{}) do
    Repo.transact(fn ->
      # The arrow keeps its hand-off prompt when an end moves.
      old = Repo.get_by(Link, source_id: old_source, target_id: old_target)
      delete_link(old_source, old_target)
      insert_link(source, target, Map.put(handles, :prompt, old && old.prompt))
    end)
    |> changed()
  end

  @doc "A workflow's graph in the shape the Svelte Flow canvas expects."
  def graph(workflow_id, selected_id \\ nil) do
    agents = list_agents(workflow_id)
    ids = MapSet.new(agents, & &1.id)

    %{
      selected: selected_id && to_string(selected_id),
      nodes:
        for a <- agents do
          %{
            id: to_string(a.id),
            name: a.name,
            model: a.model,
            status: a.status,
            x: a.x,
            y: a.y,
            kiro: true,
            activity: a.activity,
            kind: a.kind,
            has_context: String.trim(a.prompt || "") != "",
            usage: a.usage,
            shared: a.session == "shared",
            # whether the Kiro session this agent talks in is running right now
            live: Factory.Kiro.running?(a),
            role: a.role,
            action: if(a.kind == "action", do: a.action),
            missing: if(a.kind == "action", do: Factory.Actions.missing(a), else: [])
          }
        end,
      edges:
        for l <- list_links(), MapSet.member?(ids, l.source_id) do
          %{
            id: "l#{l.id}",
            source: to_string(l.source_id),
            target: to_string(l.target_id),
            source_handle: l.source_handle,
            target_handle: l.target_handle,
            prompt: l.prompt || ""
          }
        end
    }
  end

  def get_link(id), do: Repo.get(Link, id)

  @doc "Sets the prompt said on an arrow's hand-off; \"\" removes it."
  def set_link_prompt(%Link{} = link, prompt) do
    link |> Link.changeset(%{prompt: prompt || ""}) |> Repo.update() |> changed()
  end

  @doc "Ids of agents that hand off to, and receive from, the given agent."
  def neighbours(agent_id) do
    links = Repo.all(from l in Link, where: l.source_id == ^agent_id or l.target_id == ^agent_id)
    ids = Enum.flat_map(links, &[&1.source_id, &1.target_id]) |> Enum.uniq()
    names = Repo.all(from a in Agent, where: a.id in ^ids, select: {a.id, a}) |> Map.new()

    %{
      hands_off_to: for(l <- links, l.source_id == agent_id, do: names[l.target_id]),
      receives_from: for(l <- links, l.target_id == agent_id, do: names[l.source_id])
    }
  end
end
