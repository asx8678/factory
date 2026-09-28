defmodule Factory.Workflows do
  @moduledoc """
  Named workflows: each a set of agents and the hand-offs between them.

  The standard workflows match the jobs on the start screen (build a feature, fix a
  bug, resolve an issue, update dependencies). They're created from
  `Factory.Runs.Types` when first needed, can be changed like any other, and can be
  restored to their default. Custom workflows are made new or cloned.

  One workflow is `current`: the one plain chats talk to. A factory run uses the
  workflow it was started with.
  """
  import Ecto.Query
  alias Factory.{Agents, Kiro, Repo}
  alias Factory.Agents.{Agent, Link, Workflow}
  alias Factory.Runs.Types

  @standard ~w(feature bug issue deps)

  @doc "The run types that have a standard workflow."
  def standard_keys, do: @standard

  @doc "Every workflow: the standard ones in start-screen order, then custom ones by name."
  def list do
    ensure_standard()

    Repo.all(from w in Workflow, preload: :agents)
    |> Enum.sort_by(fn w ->
      case Enum.find_index(@standard, &(&1 == w.key)) do
        nil -> {1, String.downcase(w.name)}
        i -> {0, i}
      end
    end)
  end

  def get(id), do: Repo.get(Workflow, id)

  @doc "The kind of job a run on this workflow is (see `Factory.Runs.Types`): its key, or \"other\"."
  def kind(%Workflow{key: key}) when key in @standard, do: key
  def kind(%Workflow{}), do: "other"

  @doc "The standard workflow for a run type, or nil (e.g. for \"other\")."
  def standard(key) when key in @standard do
    ensure_standard()
    Repo.get_by(Workflow, key: key)
  end

  def standard(_key), do: nil

  @doc "The workflow plain chats use. Made (empty, \"My workflow\") if there's none yet."
  def current do
    Repo.one(from w in Workflow, where: w.current, limit: 1) ||
      Repo.one(from w in Workflow, where: is_nil(w.key), order_by: w.id, limit: 1)
      |> case do
        nil ->
          {:ok, w} = create("My workflow")
          {:ok, w} = set_current(w)
          w

        w ->
          w
      end
  end

  @doc """
  The workflow picked for new runs, in the chat and on the Workflows page: the current
  one if it has agents, else "Build a feature" (which becomes the current one), so a
  fresh install starts with a team that can plan and build.
  """
  def picked do
    w = current()

    if Agents.list_agents(w.id) != [] do
      w
    else
      {:ok, feature} = set_current(standard("feature"))
      feature
    end
  end

  @doc "The workflow a run's chat talks to: the run's own, else the current one."
  def for_run(%{settings: %{"workflow_id" => id}}) when is_integer(id),
    do: get(id) || current()

  def for_run(_run), do: current()

  @doc "Makes a workflow the one plain chats use."
  def set_current(%Workflow{id: id}) do
    Repo.transact(fn ->
      Repo.update_all(from(w in Workflow, where: w.current), set: [current: false])
      Repo.update_all(from(w in Workflow, where: w.id == ^id), set: [current: true])
      {:ok, get(id)}
    end)
    |> changed()
  end

  @doc "A new, empty custom workflow."
  def create(name, description \\ "") do
    %Workflow{}
    |> Workflow.changeset(%{name: name, description: description})
    |> Repo.insert()
    |> changed()
  end

  @doc "Sets the base specs (ids) this workflow's runs start with."
  def set_base_specs(%Workflow{} = w, ids) do
    w |> Ecto.Changeset.change(base_spec_ids: Enum.uniq(ids)) |> Repo.update() |> changed()
  end

  def rename(%Workflow{} = w, name),
    do: w |> Workflow.changeset(%{name: name}) |> Repo.update() |> changed()

  @doc "Deletes a custom workflow and its agents. Standard ones can only be restored."
  def delete(%Workflow{key: nil} = w) do
    stop_sessions(w)
    result = Repo.delete(w)
    changed(result)
  end

  def delete(%Workflow{}), do: {:error, :standard}

  @doc "Copies a workflow (agents, prompts, settings, hand-offs) as a new custom one."
  def clone(%Workflow{} = w, name \\ nil) do
    Repo.transact(fn ->
      with {:ok, copy} <- create(name || copy_name(w.name), w.description),
           {:ok, copy} <- set_base_specs(copy, w.base_spec_ids) do
        ids =
          Map.new(Agents.list_agents(w.id), fn a ->
            {:ok, new} =
              Agents.create_agent(
                a
                |> Map.take(~w(name role kind prompt model kiro_mode session x y action)a)
                |> Map.put(:workflow_id, copy.id)
              )

            {a.id, new.id}
          end)

        for l <- links(w.id) do
          Agents.link(ids[l.source_id], ids[l.target_id], %{
            source: l.source_handle,
            target: l.target_handle,
            prompt: l.prompt
          })
        end

        Factory.Sources.copy(w.id, copy.id, ids)

        {:ok, copy}
      end
    end)
    |> changed()
  end

  defp copy_name(name) do
    base = "#{String.slice(name, 0, 53)} (copy)"
    taken = Repo.all(from w in Workflow, select: w.name)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 -> if base not in taken, do: base
      n -> if "#{base} #{n}" not in taken, do: "#{base} #{n}"
    end)
  end

  @doc "Puts a standard workflow back as it came: its name, agents, prompts and hand-offs."
  def restore(%Workflow{key: key} = w) when key in @standard do
    stop_sessions(w)
    type = Types.get(key)

    Repo.transact(fn ->
      Repo.delete_all(from a in Agent, where: a.workflow_id == ^w.id)

      with {:ok, w} <-
             w
             |> Workflow.changeset(%{name: type.label, description: type.blurb})
             |> Repo.update() do
        build(w, Types.workflow(key))
        {:ok, w}
      end
    end)
    |> changed()
  end

  def restore(%Workflow{}), do: {:error, :custom}

  @doc "Whether a standard workflow differs from its default. Custom ones are never modified."
  def modified?(%Workflow{key: nil}), do: false

  def modified?(%Workflow{key: key} = w) do
    type = Types.get(key)
    default = Enum.map(Types.workflow(key), &{&1["name"], &1["kind"], prompt(&1)})
    agents = ordered_agents(w.id)
    now = Enum.map(agents, &{&1.name, &1.kind, &1.prompt})

    w.name != type.label or now != default or not chain?(w.id, agents)
  end

  # The hand-offs are exactly one chain through the agents in order.
  defp chain?(workflow_id, agents) do
    pairs = agents |> Enum.map(& &1.id) |> Enum.chunk_every(2, 1, :discard)
    Enum.sort(Enum.map(links(workflow_id), &[&1.source_id, &1.target_id])) == Enum.sort(pairs)
  end

  @doc """
  A workflow's agents as steps, in hand-off order:
  `[%{"kind" =>, "name" =>, "does" =>, "agent_id" =>}]`.
  """
  def steps(%Workflow{id: id}) do
    for a <- ordered_agents(id),
        do: %{"kind" => a.kind, "name" => a.name, "does" => a.role, "agent_id" => a.id}
  end

  @doc """
  Agents in hand-off order: following the arrows from agents nothing hands to, and
  top to bottom, left to right where the arrows don't decide.
  """
  def ordered_agents(workflow_id) do
    agents = Agents.list_agents(workflow_id) |> Enum.sort_by(&{&1.y, &1.x, &1.id})
    edges = links(workflow_id)
    by_id = Map.new(agents, &{&1.id, &1})
    incoming = Enum.frequencies_by(edges, & &1.target_id)
    out = Enum.group_by(edges, & &1.source_id, & &1.target_id)

    roots = Enum.filter(agents, &(Map.get(incoming, &1.id, 0) == 0))

    visit(Enum.map(roots, & &1.id), out, by_id, MapSet.new(), [])
    |> then(fn seen ->
      # Agents in a loop with no start come last, in reading order.
      seen ++ Enum.reject(agents, &(&1 in seen))
    end)
  end

  defp visit([], _out, _by_id, _seen, acc), do: Enum.reverse(acc)

  defp visit([id | rest], out, by_id, seen, acc) do
    if MapSet.member?(seen, id) or not Map.has_key?(by_id, id) do
      visit(rest, out, by_id, seen, acc)
    else
      next = out |> Map.get(id, []) |> Enum.sort_by(&{by_id[&1] && by_id[&1].y, &1})
      visit(next ++ rest, out, by_id, MapSet.put(seen, id), [by_id[id] | acc])
    end
  end

  @doc "The hand-off arrows between a workflow's cards."
  def links(workflow_id) do
    Repo.all(
      from l in Link,
        join: a in Agent,
        on: a.id == l.source_id,
        where: a.workflow_id == ^workflow_id,
        order_by: l.id
    )
  end

  # Standard workflows

  @doc "Creates any standard workflow that doesn't exist yet."
  def ensure_standard do
    have = Repo.all(from w in Workflow, where: not is_nil(w.key), select: w.key)

    for key <- @standard -- have do
      type = Types.get(key)

      Repo.transact(fn ->
        {:ok, w} =
          %Workflow{key: key}
          |> Workflow.changeset(%{name: type.label, description: type.blurb})
          |> Repo.insert(on_conflict: :nothing, conflict_target: :key)

        # Another process may have made it first.
        if w.id, do: build(w, Types.workflow(key))
        {:ok, w}
      end)
    end

    :ok
  end

  # Agents on Kiro, one under the other, each handing off to the next.
  defp build(workflow, steps) do
    agents =
      for {step, i} <- Enum.with_index(steps) do
        {:ok, a} =
          Agents.create_agent(%{
            workflow_id: workflow.id,
            name: step["name"],
            kind: step["kind"],
            role: step["does"],
            prompt: prompt(step),
            model: "auto",
            x: 0.0,
            y: i * 190.0
          })

        a
      end

    for [a, b] <- Enum.chunk_every(agents, 2, 1, :discard),
        do: Agents.link(a.id, b.id, %{source: "bottom", target: "top"})

    :ok
  end

  defp prompt(step), do: FactoryWeb.AgentKinds.template(step["kind"], step["name"])

  defp stop_sessions(%Workflow{id: id}) do
    for a <- Agents.list_agents(id), do: Kiro.stop(a.id)
  end

  defp changed(result) do
    Agents.notify_changed()
    result
  end
end
