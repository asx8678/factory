defmodule Factory.Workflows do
  @moduledoc """
  Named workflows: each a set of agents and the hand-offs between them.

  The standard workflows match the jobs on the start screen (build a feature, fix a
  bug, review a pull request, troubleshoot an issue). One that's no longer standard (resolve an issue, update
  dependencies) can be deleted like a custom one, and isn't made again. They're created from
  `Factory.Runs.Types` when first needed, can be changed like any other, and can be
  restored to their default. Custom workflows are made new or cloned.

  One workflow is `current`: the one plain chats talk to. A factory run uses the
  workflow it was started with.
  """
  import Ecto.Query
  alias Factory.{Agents, Kiro, Repo, Sources}
  alias Factory.Agents.{Agent, Link, Workflow}
  alias Factory.Runs.{Run, Types}

  @standard ~w(feature bug review incident)

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

  @doc """
  Which workflows start their runs with each base spec, `%{spec_id => [workflow name]}`:
  the names and spec ids only, for the Specs page.
  """
  def base_spec_use do
    Repo.all(
      from w in Workflow,
        where: fragment("cardinality(?) > 0", w.base_spec_ids),
        order_by: w.name,
        select: {w.name, w.base_spec_ids}
    )
    |> Enum.reduce(%{}, fn {name, ids}, acc ->
      Enum.reduce(ids, acc, fn id, acc -> Map.update(acc, id, [name], &(&1 ++ [name])) end)
    end)
  end

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
    Repo.one(from w in Workflow, where: w.current, order_by: w.id, limit: 1) ||
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

  @doc "The run's workflow (nil if deleted), or the current one when none was selected."
  def for_run(%{settings: %{"workflow_id" => id}}) when is_integer(id),
    do: get(id)

  def for_run(%{settings: %{"workflow_id" => id}}) when not is_nil(id), do: nil

  def for_run(_run), do: current()

  @doc "Makes a workflow the one plain chats use."
  def set_current(%Workflow{id: id}) do
    Repo.transact(fn ->
      Repo.update_all(from(w in Workflow, where: w.current), set: [current: false])
      Repo.update_all(from(w in Workflow, where: w.id == ^id), set: [current: true])
      if w = get(id), do: {:ok, w}, else: {:error, :not_found}
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

  @doc "Takes a deleted base spec out of every workflow that started its runs with it."
  def forget_base_spec(spec_id) when is_integer(spec_id) do
    {count, _} =
      Repo.update_all(from(w in Workflow, where: ^spec_id in w.base_spec_ids),
        pull: [base_spec_ids: spec_id]
      )

    if count > 0, do: changed(:ok)
    :ok
  end

  def rename(%Workflow{} = w, name),
    do: w |> Workflow.changeset(%{name: name}) |> Repo.update() |> changed()

  @doc """
  Deletes a custom workflow and its agents. Standard ones can only be restored. What
  Factory made for its sources (clones, section files) goes once the deletion commits.
  """
  def delete(%Workflow{key: key} = w) when key not in @standard do
    agents = Agents.list_agents(w.id)
    sources = Sources.list(w.id)

    result =
      Repo.transact(fn ->
        workflow =
          Repo.one!(from workflow in Workflow, where: workflow.id == ^w.id, lock: "FOR UPDATE")

        referenced? =
          Repo.exists?(
            from r in Run,
              where: r.status not in ["done", "cancelled"],
              where: fragment("?->>'workflow_id' = ?", r.settings, ^to_string(w.id))
          )

        if referenced?, do: {:error, :in_use}, else: Repo.delete(workflow)
      end)

    case result do
      {:ok, _} ->
        for agent <- agents, do: Kiro.stop(agent.id)
        for source <- sources, do: Sources.remove_files(source)
        changed(result)

      error ->
        error
    end
  end

  def delete(%Workflow{}), do: {:error, :standard}

  @doc """
  Copies a workflow (agents, prompts, settings, hand-offs, data sources) as a new custom
  one. Rows are copied as they are (`Ecto.Changeset.change/2`), without validating
  them again: a source whose folder has since moved is still copied. Its repositories
  start syncing once the copy has committed.
  """
  def clone(%Workflow{} = w, name \\ nil) do
    result =
      Repo.transact(fn ->
        with {:ok, copy} <-
               %Workflow{base_spec_ids: w.base_spec_ids}
               |> Workflow.changeset(%{
                 name: name || copy_name(w.name),
                 description: w.description
               })
               |> Repo.insert() do
          ids =
            Map.new(Agents.list_agents(w.id), fn a ->
              attrs = Map.take(a, ~w(name role kind prompt model kiro_mode session x y action)a)
              new = %Agent{workflow_id: copy.id} |> Ecto.Changeset.change(attrs) |> insert_copy!()

              {a.id, new.id}
            end)

          for l <- links(w.id) do
            %Link{}
            |> Ecto.Changeset.change(%{
              source_id: ids[l.source_id],
              target_id: ids[l.target_id],
              source_handle: l.source_handle,
              target_handle: l.target_handle,
              prompt: l.prompt || ""
            })
            |> insert_copy!()
          end

          sources = copy_sources(w.id, copy.id, ids)

          {:ok, {copy, sources}}
        end
      end)

    case result do
      {:ok, {copy, sources}} ->
        for source <- sources, Sources.repo?(source), do: Sources.sync(source)
        changed({:ok, copy})

      error ->
        error
    end
  end

  # The public creation helpers validate, broadcast and start syncs at once. Copies
  # are inserted as they are, without those effects, so a rollback never exposes a
  # partial workflow and a source that no longer validates still comes along.
  defp copy_sources(from_id, to_id, agent_ids) do
    for source <- Sources.list(from_id) do
      attrs = Map.take(source, ~w(kind name config content enabled x y)a)

      copy =
        %Sources.Source{workflow_id: to_id}
        |> Ecto.Changeset.change(attrs)
        |> insert_copy!()

      for id <- Sources.agent_ids(source), copied_id = agent_ids[id], not is_nil(copied_id) do
        %Sources.Link{source_id: copy.id, agent_id: copied_id} |> Repo.insert!()
      end

      copy
    end
  end

  defp insert_copy!(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # "Name (copy)", then "Name (copy) 2"…, the name cut so each fits a workflow's 60
  # characters with its suffix.
  defp copy_name(name) do
    taken = Repo.all(from w in Workflow, select: w.name)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn n ->
      suffix = if n == 1, do: " (copy)", else: " (copy) #{n}"

      candidate =
        String.trim_trailing(String.slice(name, 0, 60 - String.length(suffix))) <> suffix

      if candidate not in taken, do: candidate
    end)
  end

  @doc """
  Puts a standard workflow back as it came: its name, agents, prompts and hand-offs,
  and the arrow from its reviewer back to the agent that builds. The agents it still
  has are put back rather than made again, so runs that used them still find what they
  handed over.
  """
  def restore(%Workflow{key: key} = w) when key in @standard do
    stop_sessions(w)
    type = Types.get(key)

    Repo.transact(fn ->
      with {:ok, w} <-
             w
             |> Workflow.changeset(%{name: type.label, description: type.blurb})
             |> Repo.update() do
        build(w, key)
        {:ok, w}
      end
    end)
    |> changed()
  end

  def restore(%Workflow{}), do: {:error, :custom}

  @doc "Whether a standard workflow differs from its default. Custom ones are never modified."
  def modified?(%Workflow{key: key}) when key not in @standard, do: false

  def modified?(%Workflow{key: key} = w) do
    type = Types.get(key)

    default =
      Enum.map(Types.workflow(key), &{&1["name"], &1["kind"], prompt(&1), &1["web"] == true})

    agents = ordered_agents(w.id)
    now = Enum.map(agents, &{&1.name, &1.kind, &1.prompt, &1.web})

    w.name != type.label or now != default or not chain?(w.id, key, agents)
  end

  # The hand-offs are one chain through the agents in order, plus the arrow back.
  defp chain?(workflow_id, key, agents) do
    pairs = agents |> Enum.map(& &1.id) |> Enum.chunk_every(2, 1, :discard)
    pairs = if loop = loop(key, agents), do: pairs ++ [loop], else: pairs
    Enum.sort(Enum.map(links(workflow_id), &[&1.source_id, &1.target_id])) == Enum.sort(pairs)
  end

  # A standard workflow's arrow back, so an agent can send the work back
  # (`Factory.Engine`): the one its type names (`Factory.Runs.Types.loop/1`), else from
  # its reviewer to the agent that builds, when it has one of each.
  defp loop(key, agents) do
    case Types.loop(key) do
      {from, to} ->
        with %{id: a} <- Enum.find(agents, &(&1.name == from)),
             %{id: b} <- Enum.find(agents, &(&1.name == to)),
             do: [a, b]

      nil ->
        case {Enum.filter(agents, &(&1.kind == "reviewer")),
              Enum.filter(agents, &(&1.kind == "coder"))} do
          {[reviewer], [coder]} -> [reviewer.id, coder.id]
          _ -> nil
        end
    end
  end

  @doc """
  The agents in a workflow that build, in hand-off order: the ones a plan's tasks can
  be given to (`%{name:, does:}`). Planners, researchers and reviewers only read, and
  action cards aren't agents, so they aren't among them.
  """
  def builders(nil), do: []

  def builders(%Workflow{id: id}) do
    for a <- ordered_agents(id),
        a.kind != "action",
        not Agent.read_only?(a),
        do: %{name: a.name, does: a.role || ""}
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
        if w.id, do: build(w, key)
        {:ok, w}
      end)
    end

    :ok
  end

  # Agents on Kiro, one under the other, each handing off to the next. The workflow's
  # own agents are kept for them (a run keys what each handed over by its id): the one
  # of the same name, else one of the same kind, in order. The rest go.
  defp build(workflow, key) do
    steps = Enum.with_index(Types.workflow(key))
    have = ordered_agents(workflow.id)
    cards = Enum.reject(have, &(&1.kind == "action"))

    {named, left} =
      Enum.map_reduce(steps, cards, fn {step, _}, left ->
        take(left, &(&1.name == step["name"]))
      end)

    {kept, _left} =
      steps
      |> Enum.zip(named)
      |> Enum.map_reduce(left, fn
        {{step, _}, nil}, left -> take(left, &(&1.kind == step["kind"]))
        {_, same}, left -> {same, left}
      end)

    agents =
      for {{step, i}, same} <- Enum.zip(steps, kept), do: put_agent(same, workflow, step, i)

    ids = Enum.map(agents, & &1.id)
    Agents.delete_agents(for a <- have, a.id not in ids, do: a.id)
    Repo.delete_all(from l in Link, where: l.source_id in ^ids or l.target_id in ^ids)

    for [a, b] <- Enum.chunk_every(agents, 2, 1, :discard),
        do: Agents.link(a.id, b.id, %{source: "bottom", target: "top"})

    # Drawn down the right-hand side, so it doesn't cross the hand-offs.
    with [from, to] <- loop(key, agents),
         do: Agents.link(from, to, %{source: "right", target: "right"})

    :ok
  end

  # The first agent `fun` picks, and the others.
  defp take(agents, fun) do
    case Enum.find(agents, fun) do
      nil -> {nil, agents}
      agent -> {agent, List.delete(agents, agent)}
    end
  end

  defp put_agent(agent, workflow, step, i) do
    prompt = prompt(step)

    # The workflow is set on the struct: `Agent.changeset/2` doesn't cast it.
    (agent || %Agent{workflow_id: workflow.id})
    |> Agent.changeset(%{
      name: step["name"],
      kind: step["kind"],
      role: step["does"],
      prompt: prompt,
      web: step["web"] == true,
      model: "auto",
      session: "own",
      kiro_mode: "vibe",
      action: %{},
      x: 0.0,
      y: i * 190.0
    })
    |> Ecto.Changeset.put_change(:default_prompt, prompt)
    |> Repo.insert_or_update!()
  end

  @doc """
  Gives the standard workflows' agents the prompts Factory has now, where an agent's
  prompt is still the one Factory gave it: one someone changed keeps theirs (Restore
  puts the default back). An agent from before Factory kept track takes its prompt as
  Factory's when it's the current one. Called at startup. Returns how many changed.
  """
  def update_prompts do
    updates =
      for w <- Repo.all(from w in Workflow, where: w.key in ^@standard),
          latest = Map.new(Types.workflow(w.key), &{&1["name"], prompt(&1)}),
          a <- Agents.list_agents(w.id),
          prompt = latest[a.name],
          prompt != nil and a.prompt != nil,
          a.default_prompt != prompt,
          a.prompt == prompt or a.prompt == a.default_prompt,
          do: a |> Ecto.Changeset.change(prompt: prompt, default_prompt: prompt) |> Repo.update!()

    if updates != [], do: Agents.notify_changed()
    length(updates)
  end

  defp prompt(step),
    do: step["prompt"] || Factory.Agents.Kinds.template(step["kind"], step["name"])

  defp stop_sessions(%Workflow{id: id}) do
    for a <- Agents.list_agents(id), do: Kiro.stop(a.id)
  end

  defp changed(result) do
    Agents.notify_changed()
    result
  end
end
