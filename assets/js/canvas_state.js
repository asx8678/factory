// Server graph updates refresh data without interrupting interaction on the canvas.
export function reconcileNodes(current, incoming) {
  const byId = new Map(current.map((node) => [node.id, node]))
  return incoming.map((node) => {
    const old = byId.get(node.id)
    return old ? {
      ...old,
      ...node,
      selected: old.selected,
      position: old.dragging ? old.position : node.position,
      dragging: old.dragging,
      measured: old.measured,
    } : node
  })
}

export function reconcileEdges(current, incoming) {
  const byId = new Map(current.map((edge) => [edge.id, edge]))
  return incoming.map((edge) => ({ ...edge, selected: byId.get(edge.id)?.selected ?? edge.selected }))
}

export const isSource = (id) => typeof id === "string" && id.startsWith("source-")
export const sourceEdge = (edge) => isSource(edge.source) || isSource(edge.target)

export function validConnection(connection, nodes, edges, old = null) {
  const { source, target } = connection
  if (!nodes.some((node) => node.id === source) || !nodes.some((node) => node.id === target)) return false
  if (source === target || (isSource(source) && isSource(target))) return false
  // Moving an endpoint keeps the arrow's kind: attachment or workflow hand-off.
  if (old && sourceEdge(old) !== sourceEdge(connection)) return false

  const sourceId = isSource(source) ? source : target
  const agentId = isSource(source) ? target : source
  if (sourceEdge(connection) && nodes.some((node) => node.id === agentId && node.type === "action")) return false

  return !edges.some((edge) => edge.id !== old?.id && (
    sourceEdge(connection)
      ? edge.source === sourceId && edge.target === agentId
      : edge.source === source && edge.target === target
  ))
}
