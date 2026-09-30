import { flushSync, mount, unmount } from "svelte"
import FlowComponent from "../../svelte/Flow.svelte"

// The graph the server rendered into data-graph, or null when it can't be read.
export function readGraph(el) {
  try {
    return JSON.parse(el.dataset.graph)
  } catch (error) {
    console.error("Flow: could not read data-graph", error)
    return null
  }
}

// Mounts the Svelte Flow canvas. The LiveView owns the data: the canvas sends
// every change with pushEvent and gets the saved graph back via "flow:graph".
// data-graph is only read when the canvas (re)joins the page; later changes each
// arrive once, as a "flow:graph" event, so `updated` has nothing to do.
export const Flow = {
  mounted() {
    this.flow = mount(FlowComponent, {
      target: this.el,
      props: {
        graph: readGraph(this.el) ?? { nodes: [], edges: [] },
        readonly: this.el.dataset.readonly === "true",
        viewKey: this.el.id,
        push: (event, payload) => this.pushEvent(event, payload),
      },
    })
    // Finish mounting now, so events that arrive with the page join have a canvas to go to.
    flushSync()
    this.handleEvent("flow:graph", (graph) => this.flow.setGraph(graph))
    this.handleEvent("flow:select", ({ id }) => this.flow.select(id))
  },
  reconnected() {
    const graph = readGraph(this.el)
    if (graph) this.flow.setGraph(graph)
  },
  destroyed() {
    unmount(this.flow)
  },
}
