defmodule FactoryWeb.WorkflowMap do
  @moduledoc """
  A workflow drawn small: its steps as little cards, left to right in the order they
  run, joined by their hand-off arrows, each marked with how it's doing (busy, done,
  failed…). Shown above a run's chat, on the run page, and before a run starts.

  The steps are `Factory.Engine.steps/1`'s. `layout/2` places them: a step goes one
  column after the furthest step it waits for, so a chain is a row and a fork opens
  into rows. Parts of a workflow that no arrow joins follow each other in the order
  they run, joined by a dotted line. Actions (commit, open a PR…) are round badges.
  A step with nothing to wait for sits just before the first step it feeds, and an
  arrow back to an earlier step (a review sending work back) loops under the cards.
  """
  use FactoryWeb, :html

  # A card's width and height, an action badge's size, and the gaps between columns and rows.
  @sizes %{
    sm: %{w: 132, h: 28, dot: 26, gap_x: 36, gap_y: 8},
    md: %{w: 152, h: 38, dot: 32, gap_x: 48, gap_y: 14}
  }

  # Icon class names are written out in full so Tailwind's heroicons plugin sees them.
  # Same as assets/svelte/ActionNode.svelte.
  # How far under the cards a loop back runs, and the space between loops.
  @loop_gap 16
  @loop_step 6

  @action_icons %{
    "git_push" => "hero-arrow-up-on-square-micro",
    "github_pr" => "hero-arrows-right-left-micro",
    "azure_pr" => "hero-arrows-right-left-micro",
    "azure_item_update" => "hero-pencil-square-micro",
    "azure_item_close" => "hero-check-badge-micro",
    "github_issue" => "hero-check-badge-micro",
    "email" => "hero-envelope-micro",
    "webhook" => "hero-chat-bubble-left-right-micro",
    "api_request" => "hero-globe-alt-micro",
    "command" => "hero-command-line-micro"
  }

  @labels %{
    done: "Done",
    busy: "Working",
    error: "Failed",
    paused: "Paused",
    waiting: "Waiting",
    pending: "Not started"
  }

  @doc """
  Places the steps: `%{nodes:, edges:, width:, height:}`, in pixels. A node is
  `%{step:, x:, y:, w:, h:, action?:}`. An edge is `%{from:, to:, kind:, path:, head:}`
  (SVG path data), `kind` being `:handoff` (an arrow on the canvas) or `:then` (the
  next part of the workflow, with no arrow in between).
  """
  def layout(steps, size \\ :sm)
  def layout([], _size), do: %{nodes: [], edges: [], width: 0, height: 0}

  def layout(steps, size) do
    d = Map.fetch!(@sizes, size)
    ids = MapSet.new(steps, & &1.id)
    preds = Map.new(steps, fn s -> {s.id, Enum.filter(s.after, &MapSet.member?(ids, &1))} end)

    # Steps come in the order they run, so the ones a step waits for are placed first.
    levels =
      Enum.reduce(steps, %{}, fn s, acc ->
        level =
          preds[s.id]
          |> Enum.flat_map(&List.wrap(acc[&1]))
          |> Enum.map(&(&1 + 1))
          |> Enum.max(fn -> 0 end)

        Map.put(acc, s.id, level)
      end)

    # A step that waits for nothing moves up to just before the first step it feeds.
    levels =
      Map.new(levels, fn {id, level} ->
        feeds =
          for s <- steps, id in preds[s.id], levels[s.id] > level, do: levels[s.id] - 1

        {id, if(preds[id] == [] and feeds != [], do: Enum.min(feeds), else: level)}
      end)

    parts = parts(steps, preds)

    # Each part starts in the column after the previous part's last.
    {columns, _} =
      Enum.flat_map_reduce(parts, 0, fn part, offset ->
        deepest = part |> Enum.map(&levels[&1]) |> Enum.max()
        {Enum.map(part, &{&1, offset + levels[&1]}), offset + deepest + 1}
      end)

    column = Map.new(columns)
    by_column = Enum.group_by(steps, &column[&1.id])
    last = by_column |> Map.keys() |> Enum.max()

    widths =
      Map.new(by_column, fn {c, ss} ->
        {c, ss |> Enum.map(&elem(size(&1, d), 0)) |> Enum.max()}
      end)

    xs =
      0..last
      |> Enum.scan({0, 0}, fn c, {x, prev_c} ->
        {if(c == 0, do: 0, else: x + Map.get(widths, prev_c, 0) + d.gap_x), c}
      end)
      |> Map.new(fn {x, c} -> {c, x} end)

    rows = by_column |> Map.values() |> Enum.map(&length/1) |> Enum.max()
    pitch = d.h + d.gap_y

    nodes =
      for {c, ss} <- by_column, {s, r} <- Enum.with_index(ss) do
        {w, h} = size(s, d)
        # A column with fewer steps is centred on the tallest one.
        top = (rows - length(ss)) * pitch / 2 + r * pitch

        %{
          step: s,
          x: xs[c] + (widths[c] - w) / 2,
          y: top + (d.h - h) / 2,
          w: w,
          h: h,
          action?: s.kind == "action"
        }
      end

    at = Map.new(nodes, &{&1.step.id, &1})

    # Arrows back (`loops`, see Factory.Engine) loop under the cards; so does any
    # hand-off that would point left.
    {backs, forwards} =
      for(s <- steps, p <- preds[s.id], do: {at[p], at[s.id]})
      |> Enum.split_with(fn {a, b} -> column[b.step.id] <= column[a.step.id] end)

    backs =
      backs ++
        for s <- steps, t <- Map.get(s, :loops, []), MapSet.member?(ids, t), do: {at[s.id], at[t]}

    height = rows * pitch - d.gap_y
    handoffs = for {a, b} <- forwards, do: edge(a, b, :handoff)

    loops =
      for {{a, b}, i} <- Enum.with_index(backs),
          do: loop(a, b, height + @loop_gap + i * @loop_step)

    thens =
      for [a, b] <- Enum.chunk_every(parts, 2, 1, :discard) do
        from = a |> Enum.reverse() |> Enum.max_by(&levels[&1])
        edge(at[from], at[hd(b)], :then)
      end

    %{
      nodes: Enum.sort_by(nodes, &{&1.x, &1.y}),
      edges: handoffs ++ loops ++ thens,
      width: xs[last] + widths[last],
      height: if(backs == [], do: height, else: height + @loop_gap + length(backs) * @loop_step)
    }
  end

  defp size(%{kind: "action"}, d), do: {d.dot, d.dot}
  defp size(_step, d), do: {d.w, d.h}

  # Steps joined by arrows, either way, make a part; parts in the order their first step runs.
  defp parts(steps, preds) do
    near =
      for({id, ps} <- preds, p <- ps, pair <- [{id, p}, {p, id}], do: pair)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    order = Enum.map(steps, & &1.id)

    {parts, _} =
      Enum.reduce(order, {[], MapSet.new()}, fn id, {parts, seen} ->
        if MapSet.member?(seen, id) do
          {parts, seen}
        else
          part = reach([id], near, MapSet.new())
          {[Enum.filter(order, &MapSet.member?(part, &1)) | parts], MapSet.union(seen, part)}
        end
      end)

    Enum.reverse(parts)
  end

  defp reach([], _near, seen), do: seen

  defp reach([id | rest], near, seen) do
    if MapSet.member?(seen, id),
      do: reach(rest, near, seen),
      else: reach(Map.get(near, id, []) ++ rest, near, MapSet.put(seen, id))
  end

  # From the middle of a's right side to the middle of b's left side, ending in an arrowhead.
  defp edge(a, b, kind) do
    {x1, y1} = {a.x + a.w, a.y + a.h / 2}
    {x2, y2} = {b.x, b.y + b.h / 2}
    tip = if kind == :handoff, do: x2 - 5, else: x2
    bend = max(abs(tip - x1) / 2, 10)

    %{
      from: a.step.id,
      to: b.step.id,
      kind: kind,
      path:
        "M#{n(x1)} #{n(y1)} C#{n(x1 + bend)} #{n(y1)} #{n(tip - bend)} #{n(y2)} #{n(tip)} #{n(y2)}",
      head: "M#{n(x2 - 5)} #{n(y2 - 3.5)} L#{n(x2)} #{n(y2)} L#{n(x2 - 5)} #{n(y2 + 3.5)} Z"
    }
  end

  # Back to an earlier step: down from a's bottom, left under the cards at `y`, and up
  # into b's bottom, with rounded corners.
  defp loop(a, b, y) do
    {x1, y1} = {a.x + a.w / 2, a.y + a.h}
    {x2, y2} = {b.x + b.w / 2, b.y + b.h}
    r = 6

    %{
      from: a.step.id,
      to: b.step.id,
      kind: :handoff,
      path:
        "M#{n(x1)} #{n(y1)} L#{n(x1)} #{n(y - r)} Q#{n(x1)} #{n(y)} #{n(x1 - r)} #{n(y)} " <>
          "L#{n(x2 + r)} #{n(y)} Q#{n(x2)} #{n(y)} #{n(x2)} #{n(y - r)} L#{n(x2)} #{n(y2 + 5)}",
      head: "M#{n(x2 - 3.5)} #{n(y2 + 5)} L#{n(x2)} #{n(y2)} L#{n(x2 + 3.5)} #{n(y2 + 5)} Z"
    }
  end

  defp n(x), do: :erlang.float_to_binary(x / 1, decimals: 1)

  @doc """
  How each step is doing, by step id: `:done`, `:busy`, `:error`, `:paused`, `:waiting`
  or `:pending`. For a run, from its way through the workflow (`Factory.Engine`) and any
  agent answering in its chat right now; for a plain chat (or none), from the agents.
  """
  def states(steps, run) do
    progress = (run && run.progress) || %{}
    Map.new(steps, &{&1.id, state(&1, run, progress)})
  end

  defp state(step, run, progress) do
    live = step.agent && step.agent.status
    current? = step.id == progress["current"]

    cond do
      run && run.status == "done" -> :done
      step.id in (progress["done"] || []) -> :done
      current? and run.status == "running" -> :busy
      current? and progress["error"] != nil -> :error
      current? -> :paused
      live == "running" -> :busy
      live == "waiting" -> :waiting
      # A failure belongs to the chat it happened in, not to a new one.
      live == "error" and run != nil and run.kind == nil -> :error
      true -> :pending
    end
  end

  def state_label(state), do: Map.fetch!(@labels, state)

  @doc "An action's icon (16px), by its type."
  def action_icon(%{agent: %{action: %{"type" => type}}}),
    do: Map.get(@action_icons, type, "hero-bolt-micro")

  def action_icon(_step), do: "hero-bolt-micro"

  attr :id, :string, required: true
  attr :steps, :list, required: true
  attr :states, :map, default: %{}
  attr :size, :atom, default: :sm, values: [:sm, :md]

  attr :focus, :string,
    default: nil,
    doc: "the id of the step to ring, e.g. the agent the chat is with"

  attr :link, :any, default: nil, doc: "`fn step -> path | nil` for a step's card to open"

  @doc "The workflow drawn small. Wrap it in something that scrolls sideways."
  def map(assigns) do
    assigns = assign(assigns, :map, layout(assigns.steps, assigns.size))

    ~H"""
    <div
      id={@id}
      role="img"
      aria-label={summary(@steps, @states)}
      class={["wf-map relative shrink-0", "wf-#{@size}"]}
      style={"width: #{@map.width}px; height: #{@map.height}px"}
    >
      <svg
        class="absolute inset-0 overflow-visible"
        width={@map.width}
        height={@map.height}
        aria-hidden="true"
      >
        <g
          :for={e <- @map.edges}
          class={["wf-edge", e.kind == :then && "is-then", edge_class(@states[e.from], @states[e.to])]}
        >
          <path d={e.path} class="wf-line" />
          <path :if={e.kind == :handoff} d={e.head} class="wf-head" />
        </g>
      </svg>
      <.card
        :for={node <- @map.nodes}
        id={"#{@id}-#{node.step.id}"}
        node={node}
        state={Map.get(@states, node.step.id, :pending)}
        focus={@focus == node.step.id}
        href={@link && @link.(node.step)}
      />
    </div>
    """
  end

  # A hand-off lights up once the step before is done, and moves while the next one works.
  defp edge_class(:done, :busy), do: "is-active"
  defp edge_class(_, :error), do: "is-error"
  defp edge_class(:done, _), do: "is-done"
  defp edge_class(_, _), do: nil

  # "Planner done, Coder working, …" for screen readers.
  defp summary(steps, states) do
    Enum.map_join(steps, ", ", fn s ->
      "#{s.name} #{String.downcase(state_label(Map.get(states, s.id, :pending)))}"
    end)
  end

  attr :id, :string, required: true
  attr :node, :map, required: true
  attr :state, :atom, required: true
  attr :focus, :boolean, required: true
  attr :href, :string, default: nil

  defp card(assigns) do
    %{node: node, state: state} = assigns
    step = node.step

    assigns =
      assign(assigns,
        class: [
          "wf-node absolute",
          node.action? && "wf-action",
          "is-#{state}",
          assigns.focus && "is-focus"
        ],
        style:
          "left: #{n(node.x)}px; top: #{n(node.y)}px; width: #{node.w}px; height: #{node.h}px",
        title:
          [step.name, state_label(state), String.trim(step.does || ""), context_title(step)]
          |> Enum.reject(&(&1 in ["", nil]))
          |> Enum.join(" · ")
      )

    ~H"""
    <.link
      :if={@href}
      id={@id}
      navigate={@href}
      class={@class}
      style={@style}
      title={@title}
    >
      <.card_body node={@node} state={@state} />
    </.link>
    <div :if={!@href} id={@id} class={@class} style={@style} title={@title}>
      <.card_body node={@node} state={@state} />
    </div>
    """
  end

  # "Context 42% (compacts at 70%)" for an agent whose Kiro session is running.
  defp context_title(%{agent: %{usage: %{"context_pct" => pct}}}) when is_number(pct),
    do: "Context #{FactoryWeb.Usage.pct(pct)} (compacts at #{FactoryWeb.Usage.compact_at()}%)"

  defp context_title(_step), do: nil

  attr :usage, :map, default: nil

  # A thin bar along the card's bottom edge: how full the agent's Kiro context is.
  defp context_meter(%{usage: %{"context_pct" => pct}} = assigns) when is_number(pct) do
    assigns = assign(assigns, pct: pct, level: FactoryWeb.Usage.level(pct))

    ~H"""
    <span class={["wf-ctx", "is-#{@level}"]} style={"width: #{min(@pct, 100)}%"} aria-hidden="true"></span>
    """
  end

  defp context_meter(assigns), do: ~H""

  attr :node, :map, required: true
  attr :state, :atom, required: true

  defp card_body(%{node: %{action?: true}} = assigns) do
    ~H"""
    <span :if={@state == :busy} class="loading loading-spinner loading-xs text-primary"></span>
    <.icon :if={@state != :busy} name={action_icon(@node.step)} class="wf-icon" />
    <span class="sr-only">{@node.step.name}</span>
    """
  end

  defp card_body(assigns) do
    ~H"""
    <.icon name={FactoryWeb.RunParts.kind_icon(@node.step.kind)} class="wf-icon" />
    <span class="wf-name">{@node.step.name}</span>
    <span :if={@state == :busy} class="loading loading-spinner loading-xs shrink-0 text-primary"></span>
    <.icon
      :if={@state == :done}
      name="hero-check-circle-micro"
      class="size-3.5 shrink-0 text-success"
    />
    <.icon
      :if={@state == :error}
      name="hero-exclamation-circle-micro"
      class="size-3.5 shrink-0 text-error"
    />
    <.icon
      :if={@state == :paused}
      name="hero-pause-circle-micro"
      class="size-3.5 shrink-0 text-warning"
    />
    <.icon :if={@state == :waiting} name="hero-clock-micro" class="size-3.5 shrink-0 text-warning" />
    <.context_meter usage={@node.step.agent && @node.step.agent.usage} />
    """
  end
end
