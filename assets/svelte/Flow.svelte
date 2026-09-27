<script>
  // Wraps the canvas in a provider so the canvas can convert screen to flow coordinates.
  import { SvelteFlowProvider } from "@xyflow/svelte"
  import Canvas from "./Canvas.svelte"

  let props = $props()
  let canvas

  export function setGraph(graph) {
    canvas.setGraph(graph)
  }

  export function select(id) {
    canvas.select(id)
  }
</script>

<SvelteFlowProvider>
  <Canvas bind:this={canvas} {...props} />
</SvelteFlowProvider>
