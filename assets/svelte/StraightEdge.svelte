<script>
  // A straight arrow. When selected, both ends can be dragged onto another agent.
  import { BaseEdge, EdgeReconnectAnchor, getStraightPath } from "@xyflow/svelte"

  let { id, sourceX, sourceY, targetX, targetY, selected, markerEnd, style, interactionWidth } =
    $props()

  let [path] = $derived(getStraightPath({ sourceX, sourceY, targetX, targetY }))
  let reconnecting = $state(false)
</script>

{#if !reconnecting}
  <BaseEdge {id} {path} {markerEnd} {style} {interactionWidth} />
{/if}

{#if selected}
  <EdgeReconnectAnchor bind:reconnecting type="source" position={{ x: sourceX, y: sourceY }} />
  <EdgeReconnectAnchor bind:reconnecting type="target" position={{ x: targetX, y: targetY }} />
{/if}
