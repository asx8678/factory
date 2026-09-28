<script>
  import {
    SvelteFlow,
    Background,
    BackgroundVariant,
    Controls,
    Panel,
    MarkerType,
    ConnectionLineType,
    ConnectionMode,
    useSvelteFlow,
  } from "@xyflow/svelte"
  import { setContext } from "svelte"
  import AgentNode from "./AgentNode.svelte"
  import SourcesCard from "./SourcesCard.svelte"
  import SourceNode from "./SourceNode.svelte"
  import ActionNode from "./ActionNode.svelte"
  import ActionsPalette from "./ActionsPalette.svelte"
  import FloatingEdge from "./FloatingEdge.svelte"

  // graph: {nodes, edges, selected} from Factory.Agents.graph/1
  // push(event, payload): sends an event to the LiveView
  // viewKey: where this canvas remembers its zoom and position in the browser.
  let { graph, readonly = false, push, viewKey } = $props()

  // Restore the last zoom and position, so the workflow looks as you left it.
  // Stored per browser only; if storage is unavailable, the canvas fits all agents.
  // svelte-ignore state_referenced_locally
  const storageKey = viewKey && `factory:viewport:${viewKey}`
  const savedViewport = (() => {
    try {
      return storageKey ? JSON.parse(localStorage.getItem(storageKey)) : null
    } catch {
      return null
    }
  })()
  const saveViewport = (_event, viewport) => {
    try {
      if (storageKey) localStorage.setItem(storageKey, JSON.stringify(viewport))
    } catch {}
  }

  const nodeTypes = { agent: AgentNode, source: SourceNode, action: ActionNode }
  const edgeTypes = { floating: FloatingEdge }
  const { screenToFlowPosition, fitView } = useSvelteFlow()
  // Fixed for the canvas's lifetime; agent cards use them to send events.
  // svelte-ignore state_referenced_locally
  setContext("factory", { push, readonly })

  // Data sources (Workflows page only: its graph has `sources`) are cards of their
  // own, ids "source-ID". An arrow from one to an agent attaches it to that agent.
  // svelte-ignore state_referenced_locally
  let sources = $state(graph.sources ?? null)
  // The kinds of action to add (Workflows page only).
  // svelte-ignore state_referenced_locally
  let actionTypes = $state(graph.action_types ?? null)
  // Agents and actions are the steps of a workflow; data sources aren't.
  const isAgent = (n) => n.type === "agent" || n.type === "action"
  const isAction = (id) => nodes.some((n) => n.id === id && n.type === "action")
  const isSource = (id) => typeof id === "string" && id.startsWith("source-")
  const sourceEdge = (e) => isSource(e.source) || isSource(e.target)

  const toNodes = (g) => {
    const attached = new Map()
    for (const l of g.source_links ?? []) attached.set(l.source, (attached.get(l.source) ?? 0) + 1)

    return [
      ...g.nodes.map((n) => ({
        id: n.id,
        type: n.kind === "action" ? "action" : "agent",
        position: { x: n.x, y: n.y },
        data: n,
        selected: n.id === g.selected,
      })),
      ...(g.sources ?? []).map((s) => ({
        id: `source-${s.id}`,
        type: "source",
        position: { x: s.x, y: s.y },
        data: { ...s, attached: attached.get(`source-${s.id}`) ?? 0 },
      })),
    ]
  }

  // Arrows out of a running agent get moving dashes.
  const toEdges = (g) => {
    const running = new Set(g.nodes.filter((n) => n.status === "running").map((n) => n.id))
    const attachments = (g.source_links ?? []).map((l) => ({
      id: `sl-${l.source}-${l.target}`,
      source: l.source,
      target: l.target,
      type: "floating",
      class: "source-edge",
      data: { attachment: true },
      markerEnd: { type: MarkerType.ArrowClosed, width: 16, height: 16 },
    }))
    const actions = new Set(g.nodes.filter((n) => n.kind === "action").map((n) => n.id))
    return [...attachments, ...g.edges.map((e) => ({
      id: e.id,
      source: e.source,
      target: e.target,
      type: "floating",
      sourceHandle: e.source_handle ?? undefined,
      targetHandle: e.target_handle ?? undefined,
      animated: running.has(e.source),
      data: { prompt: e.prompt ?? "", toAction: actions.has(e.target) },
      markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18 },
    }))]
  }

  // Only the first graph comes from props; later ones arrive through setGraph.
  // svelte-ignore state_referenced_locally
  let nodes = $state.raw(toNodes(graph))
  // svelte-ignore state_referenced_locally
  let edges = $state.raw(toEdges(graph))
  let container
  let reconnecting = false

  // Keep each node's measured size so a refresh from the server doesn't make nodes flicker.
  export function setGraph(g) {
    const measured = new Map(nodes.map((n) => [n.id, n.measured]))
    nodes = toNodes(g).map((n) => (measured.get(n.id) ? { ...n, measured: measured.get(n.id) } : n))
    edges = toEdges(g)
    sources = g.sources ?? null
    actionTypes = g.action_types ?? null
  }

  export function select(id) {
    nodes = nodes.map((n) => (n.selected === (n.id === id) ? n : { ...n, selected: n.id === id }))
  }

  const pair = (e) => ({ source: e.source, target: e.target })
  // A new connection also records which circles it joins.
  const withHandles = (c) => ({ ...pair(c), sourceHandle: c.sourceHandle, targetHandle: c.targetHandle })

  // Lays agents out top-down in layers: each agent sits one row below the lowest agent handing off to it.
  function arrange() {
    const agents = nodes.filter(isAgent)
    const cards = nodes.filter((n) => n.type === "source").sort((a, b) => a.position.y - b.position.y)
    const layer = new Map(agents.map((n) => [n.id, 0]))
    for (let pass = 0; pass < agents.length; pass++) {
      for (const e of edges) {
        const next = layer.get(e.source) + 1
        if (e.source !== e.target && next < agents.length && layer.get(e.target) < next) layer.set(e.target, next)
      }
    }
    const rows = new Map()
    for (const n of agents) rows.set(layer.get(n.id), [...(rows.get(layer.get(n.id)) ?? []), n.id])
    const place = new Map()
    for (const [row, ids] of rows) ids.forEach((id, i) => place.set(id, { x: (i - (ids.length - 1) / 2) * 290, y: row * 190 }))

    // An arrow that skips a row must not run behind a card in between: move such cards aside.
    const width = agents[0]?.measured?.width ?? 240
    for (const e of edges) {
      const [from, to] = [layer.get(e.source), layer.get(e.target)]
      if (to - from < 2) continue
      const [a, b] = [place.get(e.source), place.get(e.target)]
      for (let row = from + 1; row < to; row++) {
        const lineX = a.x + ((b.x - a.x) * (row - from)) / (to - from) + width / 2
        for (const id of rows.get(row) ?? []) {
          const p = place.get(id)
          if (lineX > p.x - 24 && lineX < p.x + width + 24) place.set(id, { ...p, x: lineX - width - 48 })
        }
      }
    }

    const placed = agents.map((n) => ({ ...n, position: place.get(n.id) }))
    // Data source cards line up in a column left of the agents.
    const left = Math.min(0, ...placed.map((n) => n.position.x)) - 320
    const stacked = cards.map((n, i) => ({ ...n, position: { x: left, y: i * 120 } }))
    nodes = [...placed, ...stacked]
    const at = (n) => ({ id: n.id, x: n.position.x, y: n.position.y })
    push("move", { nodes: placed.map(at) })
    if (stacked.length) push("move_sources", { nodes: stacked.map(at) })
    setTimeout(() => fitView({ padding: 0.3, maxZoom: 1.1, duration: 300 }), 50)
  }

  // A source (either end) attaches to an agent; two agents hand off; two sources don't connect.
  const attachment = (c) =>
    isSource(c.source) && !isSource(c.target)
      ? { source: c.source, agent: c.target }
      : isSource(c.target) && !isSource(c.source)
        ? { source: c.target, agent: c.source }
        : null

  const isValidConnection = (c) => {
    if (c.source === c.target || (isSource(c.source) && isSource(c.target))) return false
    const a = attachment(c)
    if (a) return !isAction(a.agent) && !edges.some((e) => e.source === a.source && e.target === a.agent)
    return !edges.some((e) => e.source === c.source && e.target === c.target)
  }

  // Dropping a source's arrow on empty canvas offers the agents to attach it to.
  let picker = $state(null)

  function attachTo(agentId) {
    push("attach_source", { source: picker.source, agent: agentId })
    picker = null
  }

  // Middle of the visible canvas, moved down until it doesn't cover another agent.
  function addAgent() {
    const r = container.getBoundingClientRect()
    const p = screenToFlowPosition({ x: r.left + r.width / 2, y: r.top + r.height / 2 })
    let [x, y] = [p.x - 88, p.y - 28]
    const covers = (n) => Math.abs(n.position.x - x) < 190 && Math.abs(n.position.y - y) < 90
    while (nodes.filter(isAgent).some(covers)) y += 110
    push("add_agent", { x, y })
  }

  // A new action goes right of the selected agent, else right of the last one, moved
  // down until it doesn't cover another card. It isn't connected: draw the arrow.
  function addAction(type) {
    const steps = nodes.filter(isAgent)
    const anchor =
      steps.find((n) => n.selected) ??
      steps.reduce((low, n) => (!low || n.position.y > low.position.y ? n : low), null)
    let [x, y] = anchor ? [anchor.position.x + 300, anchor.position.y] : [0, 0]
    const covers = (n) => Math.abs(n.position.x - x) < 200 && Math.abs(n.position.y - y) < 70
    while (nodes.some(covers)) y += 80
    push("add_action", { type, x, y })
  }

  let anySelected = $derived(nodes.some((n) => n.selected))

  // Dropping a new arrow on empty canvas creates an agent at that spot, already connected.
  function onconnectend(event, state) {
    if (reconnecting || state.isValid || !state.fromNode) return
    const { clientX, clientY } = "changedTouches" in event ? event.changedTouches[0] : event

    // Released on another card (not exactly on one of its circles): connect to it.
    const over = document.elementFromPoint(clientX, clientY)?.closest(".svelte-flow__node")?.dataset.id
    if (over && over !== state.fromNode.id) {
      const from = state.fromNode.id
      const c = state.fromHandle?.type === "target" ? { source: over, target: from } : { source: from, target: over }
      if (isValidConnection(c)) {
        const a = attachment(c)
        a ? push("attach_source", a) : push("connect", { ...c, sourceHandle: null, targetHandle: null })
      }
      return
    }

    if (state.fromNode.type === "source") {
      const r = container.getBoundingClientRect()
      const agents = nodes.filter((n) => n.type === "agent").map((n) => ({ id: n.id, name: n.data.name }))
      picker = { source: state.fromNode.id, name: state.fromNode.data.name, agents, x: clientX - r.left, y: clientY - r.top }
      return
    }
    const p = screenToFlowPosition({ x: clientX, y: clientY })
    const end = state.fromHandle?.type === "target" ? "to" : "from"
    push("add_agent", { x: p.x - 88, y: p.y - 28, [end]: state.fromNode.id })
  }
</script>

<div class="h-full w-full" bind:this={container}>
  <SvelteFlow
    bind:nodes
    bind:edges
    {nodeTypes}
    {edgeTypes}
    fitView={!savedViewport}
    initialViewport={savedViewport ?? undefined}
    onmoveend={saveViewport}
    fitViewOptions={{ maxZoom: 1.1, padding: 0.3 }}
    minZoom={0.3}
    maxZoom={2}
    defaultMarkerColor="var(--xy-edge-stroke)"
    connectionLineType={ConnectionLineType.Bezier}
    connectionRadius={40}
    connectionMode={ConnectionMode.Loose}
    nodesDraggable={!readonly}
    nodesConnectable={!readonly}
    deleteKey={readonly ? null : ["Backspace", "Delete"]}
    zoomOnScroll={!readonly}
    preventScrolling={!readonly}
    {isValidConnection}
    onnodeclick={({ node }) =>
      isAgent(node) ? push("select", { id: node.id }) : push("source_edit", { id: node.id.slice(7) })}
    onpaneclick={() => {
      picker = null
      if (!readonly) push("deselect", {})
    }}
    onnodedragstop={({ nodes: moved }) => {
      const at = (n) => ({ id: n.id, x: n.position.x, y: n.position.y })
      const agents = moved.filter(isAgent)
      const cards = moved.filter((n) => n.type === "source")
      if (agents.length) push("move", { nodes: agents.map(at) })
      if (cards.length) push("move_sources", { nodes: cards.map(at) })
    }}
    onconnect={(c) => {
      const a = attachment(c)
      a ? push("attach_source", a) : push("connect", withHandles(c))
    }}
    {onconnectend}
    onreconnectstart={() => (reconnecting = true)}
    onreconnect={(old, c) => {
      if (sourceEdge(old)) {
        const a = attachment(c)
        push("detach_source", { source: old.source, agent: old.target })
        if (a) push("attach_source", a)
      } else push("reconnect", { old: pair(old), new: withHandles(c) })
    }}
    onreconnectend={() => (reconnecting = false)}
    ondelete={({ nodes: n, edges: e }) => {
      for (const x of e.filter(sourceEdge)) push("detach_source", { source: x.source, agent: x.target })
      const cards = n.filter((x) => x.type === "source").map((x) => x.id)
      if (cards.length) push("delete_sources", { ids: cards })
      push("delete", { nodes: n.filter(isAgent).map((x) => x.id), edges: e.filter((x) => !sourceEdge(x)).map(pair) })
    }}
  >
    <Background variant={BackgroundVariant.Dots} gap={22} size={1.2} />
    {#if !readonly && actionTypes}
      <!-- Beside the side panel when a card is selected, so it stays usable. -->
      <Panel position="top-right" style={anySelected ? "right: 356px" : ""}>
        <ActionsPalette types={actionTypes} onadd={addAction} />
      </Panel>
    {/if}
    {#if !readonly}
      <Panel position="top-left">
        <div class="flex items-center gap-1 rounded-2xl border border-base-content/10 bg-surface p-1 shadow-md">
          <button class="flex h-8 items-center gap-1.5 rounded-xl bg-primary px-3 text-sm font-medium text-primary-content transition-opacity hover:opacity-90" onclick={addAgent}>
            <svg viewBox="0 0 20 20" class="size-4" fill="currentColor" aria-hidden="true"><path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" /></svg>
            Add agent
          </button>
          <span class="mx-0.5 h-5 w-px bg-base-content/15"></span>
          <button class="flex h-8 items-center gap-1.5 rounded-xl px-2.5 text-sm hover:bg-base-content/[0.06]" onclick={() => fitView({ padding: 0.3, maxZoom: 1.1, duration: 300 })} title="Fit all agents on screen">
            <svg viewBox="0 0 20 20" class="size-4" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" d="M3 7V3.5h3.5M17 7V3.5h-3.5M3 13v3.5h3.5M17 13v3.5h-3.5" /></svg>
            Fit
          </button>
          <button class="flex h-8 items-center gap-1.5 rounded-xl px-2.5 text-sm hover:bg-base-content/[0.06] disabled:opacity-40" onclick={arrange} disabled={nodes.length < 2} title="Lay agents out top-down">
            <svg viewBox="0 0 20 20" class="size-4" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><rect x="7.5" y="2.5" width="5" height="4" rx="1" /><rect x="2.5" y="13.5" width="5" height="4" rx="1" /><rect x="12.5" y="13.5" width="5" height="4" rx="1" /><path stroke-linecap="round" d="M10 6.5v3.5M5 13.5V10h10v3.5" /></svg>
            Arrange
          </button>
        </div>
        {#if sources}
          <div class="mt-2">
            <SourcesCard {sources} />
          </div>
        {/if}
      </Panel>
      <Controls showLock={false} showFitView={false} position="bottom-left" />
      {#if nodes.length === 0}
        <Panel position="top-center">
          <p class="mt-24 rounded-full border border-base-content/10 bg-surface px-4 py-2 text-sm shadow-md">No agents yet. Click Add agent to start your workflow.</p>
        </Panel>
      {:else if edges.length === 0}
        <Panel position="bottom-center">
          <p class="mb-2 rounded-full border border-base-content/10 bg-surface px-4 py-2 text-sm opacity-80 shadow-md">
            Drag from a dot on an agent's edge to another agent to connect them. Drop on empty space to create one.
          </p>
        </Panel>
      {/if}
    {/if}
  </SvelteFlow>

  {#if picker}
    <div
      class="absolute z-50 w-56 rounded-xl border border-base-content/10 bg-surface p-1 shadow-xl"
      style={`left: ${picker.x}px; top: ${picker.y}px`}
      role="menu"
    >
      <p class="px-2.5 pb-1 pt-1.5 text-[11px] text-base-content/55">Attach “{picker.name}” to</p>
      {#each picker.agents as a (a.id)}
        <button
          type="button"
          role="menuitem"
          class="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left text-sm hover:bg-success/10"
          onclick={() => attachTo(a.id)}
        >
          <span class="hero-arrow-long-right-micro size-3.5 text-success"></span>
          {a.name}
        </button>
      {:else}
        <p class="px-2.5 py-2 text-xs text-base-content/55">Add an agent first.</p>
      {/each}
      <button
        type="button"
        class="mt-0.5 w-full rounded-lg px-2.5 py-1 text-left text-xs text-base-content/50 hover:text-base-content"
        onclick={() => (picker = null)}
      >
        Cancel
      </button>
    </div>
  {/if}
</div>
