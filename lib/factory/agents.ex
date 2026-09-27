defmodule Factory.Agents do
  @moduledoc "Agents and the links (hand-offs) between them."
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

  def list_agents, do: Repo.all(from a in Agent, order_by: a.id)

  def get_agent(id), do: Repo.get(Agent, id)

  def create_agent(attrs), do: attrs |> insert_agent() |> changed()

  defp insert_agent(attrs), do: %Agent{} |> Agent.changeset(attrs) |> Repo.insert()

  def update_agent(%Agent{} = agent, attrs), do: agent |> Agent.changeset(attrs) |> Repo.update() |> changed()

  def change_agent(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)

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

  @doc "Creates an agent, optionally linked from or to an existing one."
  def add_agent(x, y, opts \\ []) do
    count = Repo.aggregate(Agent, :count)

    Repo.transact(fn ->
      with {:ok, agent} <- insert_agent(%{name: "Agent #{count + 1}", x: x, y: y}),
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

  def link(source_id, target_id), do: insert_link(source_id, target_id) |> changed()

  defp insert_link(source_id, target_id) do
    %Link{}
    |> Link.changeset(%{source_id: source_id, target_id: target_id})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:source_id, :target_id])
  end

  def unlink(source_id, target_id), do: delete_link(source_id, target_id) |> changed()

  defp delete_link(source_id, target_id) do
    Repo.delete_all(from l in Link, where: l.source_id == ^source_id and l.target_id == ^target_id)
  end

  @doc "Moves one end of a link to a different agent."
  def relink({old_source, old_target}, {source, target}) do
    Repo.transact(fn ->
      delete_link(old_source, old_target)
      insert_link(source, target)
    end)
    |> changed()
  end

  @doc "The whole graph in the shape the Svelte Flow canvas expects."
  def graph(selected_id \\ nil) do
    %{
      selected: selected_id && to_string(selected_id),
      nodes:
        for a <- list_agents() do
          %{id: to_string(a.id), name: a.name, model: a.model, status: a.status, x: a.x, y: a.y}
        end,
      edges:
        for l <- list_links() do
          %{id: "l#{l.id}", source: to_string(l.source_id), target: to_string(l.target_id)}
        end
    }
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
