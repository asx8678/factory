defmodule FactoryWeb.PlanDiff do
  @moduledoc """
  What changed in a plan since a snapshot, so the chat's plan can mark it: the plan as
  it was when Refine (or a message to the planner) started, against the plan now.

  Tasks are matched to the snapshot by title, then, for a task renamed or rewritten,
  by the snapshot task it shares the most words with. A task with no match is new. A
  matched task shows which of its parts changed; a snapshot task nothing matches was
  removed.
  """

  @fields [:title, :objective, :details, :verify, :agent, :model, :requirements]

  @doc "A plan's tasks as the snapshot keeps them."
  def snapshot(tasks), do: Enum.map(tasks, &entry/1)

  defp entry(task) do
    task
    |> Map.take(@fields)
    |> Map.put_new(:objective, nil)
    |> Map.put_new(:verify, [])
    |> Map.put_new(:agent, nil)
    |> Map.put_new(:model, nil)
  end

  @doc """
  What changed in `tasks` since `snapshot`: `{marks, removed}`, a mark per task, in
  order, and the titles of the snapshot's tasks that are gone. A mark is nil for an
  unchanged task, `%{new: true}` for a new one, or says which parts changed:
  `%{new: false, title:, objective:, agent:, model:, steps: [index], checks: [index]}`. With no
  snapshot, nothing is marked.
  """
  def diff(nil, tasks), do: {Enum.map(tasks, fn _ -> nil end), []}

  def diff(snapshot, tasks) do
    matches = match(snapshot, tasks)

    marks =
      for {task, j} <- Enum.zip(tasks, matches) do
        if j, do: changed(Enum.at(snapshot, j), entry(task)), else: %{new: true}
      end

    removed =
      for {old, j} <- Enum.with_index(snapshot), j not in matches, do: old.title

    {marks, removed}
  end

  @doc """
  The snapshot after the person changed task `i` themselves, from `before` to `after`
  (the plan's tasks either side of it), so their own edit isn't marked as the
  planner's. `:remove` for a task they removed.
  """
  def accept(nil, _before, _after, _i, _how), do: nil

  def accept(snapshot, before, after_tasks, i, how) do
    j = Enum.at(match(snapshot, before), i)

    case {how, j, Enum.at(after_tasks, i)} do
      {:remove, nil, _} -> snapshot
      {:remove, j, _} -> List.delete_at(snapshot, j)
      {:edit, nil, task} when task != nil -> snapshot ++ [entry(task)]
      {:edit, j, task} when task != nil -> List.replace_at(snapshot, j, entry(task))
      _ -> snapshot
    end
  end

  # For each task, the index of the snapshot task it is, or nil when it's new.
  defp match(snapshot, tasks) do
    # Same title first.
    {matches, used} =
      Enum.map_reduce(tasks, MapSet.new(), fn task, used ->
        j =
          Enum.find_index(Enum.with_index(snapshot), fn {old, j} ->
            old.title == task.title and not MapSet.member?(used, j)
          end)

        {j, if(j, do: MapSet.put(used, j), else: used)}
      end)

    # Then a renamed or rewritten task: the unused snapshot task it shares most words with.
    {matches, _used} =
      Enum.map_reduce(Enum.zip(tasks, matches), used, fn
        {_task, j}, used when j != nil ->
          {j, used}

        {task, nil}, used ->
          words = words(task)

          best =
            snapshot
            |> Enum.with_index()
            |> Enum.reject(fn {_, j} -> MapSet.member?(used, j) end)
            |> Enum.map(fn {old, j} -> {similarity(words, words(old)), j} end)
            |> Enum.max_by(&elem(&1, 0), fn -> {0, nil} end)

          case best do
            {score, j} when score >= 0.3 -> {j, MapSet.put(used, j)}
            _ -> {nil, used}
          end
      end)

    matches
  end

  defp changed(old, new) do
    mark = %{
      new: false,
      title: old.title != new.title,
      objective: (old.objective || "") != (new.objective || ""),
      agent: old.agent != new.agent,
      model: old.model != new.model,
      steps: added(old.details, new.details),
      checks: added(old.verify, new.verify)
    }

    if mark.title or mark.objective or mark.agent or mark.model or mark.steps != [] or
         mark.checks != [] or
         old.requirements != new.requirements or old.details != new.details or
         old.verify != new.verify,
       do: mark,
       else: nil
  end

  # The indexes of the lines in `new` that weren't in `old`.
  defp added(old, new) do
    for {line, j} <- Enum.with_index(new || []), line not in (old || []), do: j
  end

  defp words(task) do
    [task.title, Map.get(task, :objective) || "" | task.details]
    |> Enum.join(" ")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> MapSet.new()
  end

  defp similarity(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end
end
