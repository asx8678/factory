<script>
  // A gently curved arrow from circle to circle. If the arrow was drawn between two
  // specific circles, it stays on those. Otherwise (older links, or agents created
  // by dropping an arrow) it uses the circles on the sides that face each other.
  // When selected, both ends can be dragged onto another agent.
  import { BaseEdge, EdgeReconnectAnchor, Position, getBezierPath, useInternalNode } from "@xyflow/svelte"

  let {
    id,
    source,
    target,
    sourceHandleId,
    targetHandleId,
    selected,
    markerEnd,
    style,
    interactionWidth,
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    data,
  } = $props()

  // An arrow's two agents never change: moving an end saves a new link with a new id.
  // svelte-ignore state_referenced_locally
  const from = useInternalNode(source)
  // svelte-ignore state_referenced_locally
  const to = useInternalNode(target)
  let reconnecting = $state(false)

  const box = (n) => ({
    x: n.internals.positionAbsolute.x,
    y: n.internals.positionAbsolute.y,
    w: n.measured.width,
    h: n.measured.height,
  })

  // The circle in the middle of a's side that faces b, and which side that is
  // (the curve leaves and enters at right angles to it).
  function facing(a, b) {
    const [p, q] = [box(a), box(b)]
    const dx = q.x + q.w / 2 - (p.x + p.w / 2)
    const dy = q.y + q.h / 2 - (p.y + p.h / 2)
    if (Math.abs(dx) / p.w > Math.abs(dy) / p.h)
      return dx > 0
        ? { x: p.x + p.w, y: p.y + p.h / 2, pos: Position.Right }
        : { x: p.x, y: p.y + p.h / 2, pos: Position.Left }
    return dy > 0
      ? { x: p.x + p.w / 2, y: p.y + p.h, pos: Position.Bottom }
      : { x: p.x + p.w / 2, y: p.y, pos: Position.Top }
  }

  // Left or right side only: data source arrows all meet an agent at the one circle
  // on its side facing the sources, so several of them join at a single dot and
  // never run over the top-to-bottom hand-offs.
  function sideways(a, b) {
    const [p, q] = [box(a), box(b)]
    return q.x + q.w / 2 >= p.x + p.w / 2
      ? { x: p.x + p.w, y: p.y + p.h / 2, pos: Position.Right }
      : { x: p.x, y: p.y + p.h / 2, pos: Position.Left }
  }

  let ends = $derived.by(() => {
    const a = from.current
    const b = to.current
    const measured = a?.measured?.width && b?.measured?.width
    if (data?.attachment && measured) return [sideways(a, b), sideways(b, a)]
    return [
      sourceHandleId || !measured ? { x: sourceX, y: sourceY, pos: sourcePosition } : facing(a, b),
      targetHandleId || !measured ? { x: targetX, y: targetY, pos: targetPosition } : facing(b, a),
    ]
  })

  let path = $derived(
    getBezierPath({
      sourceX: ends[0].x,
      sourceY: ends[0].y,
      sourcePosition: ends[0].pos ?? Position.Bottom,
      targetX: ends[1].x,
      targetY: ends[1].y,
      targetPosition: ends[1].pos ?? Position.Top,
      curvature: 0.3,
    })[0],
  )
</script>

{#if !reconnecting}
  <BaseEdge {id} {path} {markerEnd} {style} {interactionWidth} />
{/if}

{#if selected}
  <EdgeReconnectAnchor bind:reconnecting type="source" position={ends[0]} />
  <EdgeReconnectAnchor bind:reconnecting type="target" position={ends[1]} />
{/if}
