<script>
  import {
    SvelteFlow,
    Background,
    BackgroundVariant,
    Controls,
    Panel,
    MarkerType,
    ConnectionLineType,
    useSvelteFlow,
  } from "@xyflow/svelte"
  import AgentNode from "./AgentNode.svelte"
  import StraightEdge from "./StraightEdge.svelte"

  // graph: {nodes, edges, selected} from Factory.Agents.graph/1
  // push(event, payload): sends an event to the LiveView
  let { graph, readonly = false, push } = $props()

  const nodeTypes = { agent: AgentNode }
  const edgeTypes = { straight: StraightEdge }
  const { screenToFlowPosition } = useSvelteFlow()

  const toNodes = (g) =>
    g.nodes.map((n) => ({
      id: n.id,
      type: "agent",
      position: { x: n.x, y: n.y },
      data: n,
      selected: n.id === g.selected,
    }))

  const toEdges = (g) =>
    g.edges.map((e) => ({
      id: e.id,
      source: e.source,
      target: e.target,
      type: "straight",
      markerEnd: { type: MarkerType.ArrowClosed, width: 18, height: 18 },
    }))

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
  }

  export function select(id) {
    nodes = nodes.map((n) => (n.selected === (n.id === id) ? n : { ...n, selected: n.id === id }))
  }

  const pair = (e) => ({ source: e.source, target: e.target })

  const isValidConnection = (c) =>
    c.source !== c.target && !edges.some((e) => e.source === c.source && e.target === c.target)

  // Middle of the visible canvas, moved down until it doesn't cover another agent.
  function addAgent() {
    const r = container.getBoundingClientRect()
    const p = screenToFlowPosition({ x: r.left + r.width / 2, y: r.top + r.height / 2 })
    let [x, y] = [p.x - 88, p.y - 28]
    const covers = (n) => Math.abs(n.position.x - x) < 190 && Math.abs(n.position.y - y) < 90
    while (nodes.some(covers)) y += 110
    push("add_agent", { x, y })
  }

  // Dropping a new arrow on empty canvas creates an agent at that spot, already connected.
  function onconnectend(event, state) {
    if (reconnecting || state.isValid || !state.fromNode) return
    const { clientX, clientY } = "changedTouches" in event ? event.changedTouches[0] : event
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
    fitView
    fitViewOptions={{ maxZoom: 1.1, padding: 0.3 }}
    minZoom={0.3}
    maxZoom={2}
    defaultMarkerColor="var(--xy-edge-stroke)"
    connectionLineType={ConnectionLineType.Straight}
    nodesDraggable={!readonly}
    nodesConnectable={!readonly}
    deleteKey={readonly ? null : ["Backspace", "Delete"]}
    zoomOnScroll={!readonly}
    preventScrolling={!readonly}
    {isValidConnection}
    onnodeclick={({ node }) => push("select", { id: node.id })}
    onpaneclick={() => !readonly && push("deselect", {})}
    onnodedragstop={({ nodes: moved }) =>
      push("move", { nodes: moved.map((n) => ({ id: n.id, x: n.position.x, y: n.position.y })) })}
    onconnect={(c) => push("connect", pair(c))}
    {onconnectend}
    onreconnectstart={() => (reconnecting = true)}
    onreconnect={(old, c) => push("reconnect", { old: pair(old), new: pair(c) })}
    onreconnectend={() => (reconnecting = false)}
    ondelete={({ nodes: n, edges: e }) =>
      push("delete", { nodes: n.map((x) => x.id), edges: e.map(pair) })}
  >
    <Background variant={BackgroundVariant.Dots} gap={22} size={1.2} />
    {#if !readonly}
      <Controls showLock={false} />
      <Panel position="top-left">
        <button class="btn btn-primary btn-sm" onclick={addAgent}>Add agent</button>
      </Panel>
      {#if nodes.length === 0}
        <Panel position="top-center">
          <p class="mt-16 text-sm opacity-70">No agents yet. Add one to start your graph.</p>
        </Panel>
      {/if}
    {/if}
  </SvelteFlow>
</div>
