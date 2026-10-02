defmodule Factory.Engine.Graph do
  @moduledoc """
  The order a workflow's cards run in (`Factory.Engine`): a card runs once every card
  with an arrow into it has finished, in reading order where the arrows don't decide;
  an arrow back to an earlier card is a loop, not a hand-off.
  """
  alias Factory.{Actions, Agents, Workflows}

  # An arrow that closes a loop (it points to a card that leads to its own start, like
  # Reviewer → Coder) doesn't make the earlier card wait: it's a way to send the work
  # back. The other arrows are hand-offs and decide the order.
  @doc "A workflow's steps in the order they run (`Factory.Engine.steps/1`)."
  def steps(workflow_id) do
    all = Agents.list_agents(workflow_id)
    all_ids = MapSet.new(all, & &1.id)

    links =
      Workflows.links(workflow_id)
      |> Enum.filter(&(&1.source_id in all_ids and &1.target_id in all_ids))

    cards =
      all |> Enum.reject(&loose_action?(&1, all, links)) |> Enum.sort_by(&{&1.y, &1.x, &1.id})

    back = back_links(cards, links)

    {loops, handoffs} =
      Enum.split_with(links, &MapSet.member?(back, {&1.source_id, &1.target_id}))

    preds = Enum.group_by(handoffs, & &1.target_id, & &1.source_id)
    ordered = topological(cards, preds)
    order = Enum.map(ordered, &"agent-#{&1.id}")

    ordered
    |> Enum.map(fn card ->
      %{
        id: "agent-#{card.id}",
        kind: card.kind,
        name: if(card.kind == "action", do: Actions.label(card), else: card.name),
        does: card.role || "",
        after: Enum.map(Map.get(preds, card.id, []), &"agent-#{&1}"),
        # The earlier steps this one can send the work back to, first in run order first.
        loops:
          for(l <- loops, l.source_id == card.id, do: "agent-#{l.target_id}")
          |> Enum.sort_by(&Enum.find_index(order, fn id -> id == &1 end)),
        # What each arrow into this card says on its hand-off, by the step it comes from,
        # and what an arrow back from this card says about sending the work back.
        notes:
          for(
            l <- handoffs,
            l.target_id == card.id,
            String.trim(l.prompt || "") != "",
            into: %{},
            do: {"agent-#{l.source_id}", l.prompt}
          ),
        back_notes:
          for(
            l <- loops,
            l.source_id == card.id,
            String.trim(l.prompt || "") != "",
            into: %{},
            do: {"agent-#{l.target_id}", l.prompt}
          ),
        agent: card
      }
    end)
  end

  # An action card with no arrow at all, in a workflow with agents, hasn't been put in
  # the flow yet (the palette drops it unconnected): it doesn't run. Otherwise a
  # "Commit & push" left on the canvas would push. A workflow of only actions runs them.
  defp loose_action?(%{kind: "action", id: id}, all, links) do
    Enum.any?(all, &(&1.kind != "action")) and
      not Enum.any?(links, &(&1.source_id == id or &1.target_id == id))
  end

  defp loose_action?(_card, _all, _links), do: false

  # Arrows that close a loop: depth first from the cards nothing points to, in reading
  # order, an arrow to a card on the current path goes back.
  defp back_links(cards, links) do
    rank = cards |> Enum.with_index() |> Map.new(fn {c, i} -> {c.id, i} end)

    children =
      links
      |> Enum.group_by(& &1.source_id, & &1.target_id)
      |> Map.new(fn {id, targets} -> {id, Enum.sort_by(targets, &rank[&1])} end)

    pointed_to = MapSet.new(links, & &1.target_id)
    starts = Enum.reject(cards, &MapSet.member?(pointed_to, &1.id)) ++ cards

    {back, _seen} =
      Enum.reduce(starts, {MapSet.new(), MapSet.new()}, fn card, acc ->
        visit(card.id, children, MapSet.new(), acc)
      end)

    back
  end

  defp visit(id, children, path, {back, seen}) do
    if MapSet.member?(seen, id) do
      {back, seen}
    else
      path = MapSet.put(path, id)

      Enum.reduce(Map.get(children, id, []), {back, MapSet.put(seen, id)}, fn child,
                                                                              {back, seen} ->
        if MapSet.member?(path, child),
          do: {MapSet.put(back, {id, child}), seen},
          else: visit(child, children, path, {back, seen})
      end)
    end
  end

  # Kahn's algorithm, taking the first ready card in reading order each time. The
  # arrows it follows have no loops (`back_links/2` took those out).
  defp topological(cards, preds), do: topological(cards, preds, MapSet.new(), [])

  defp topological([], _preds, _done, acc), do: Enum.reverse(acc)

  defp topological(cards, preds, done, acc) do
    ready =
      Enum.find(cards, fn c -> Enum.all?(Map.get(preds, c.id, []), &MapSet.member?(done, &1)) end)

    next = ready || hd(cards)
    topological(List.delete(cards, next), preds, MapSet.put(done, next.id), [next | acc])
  end
end
