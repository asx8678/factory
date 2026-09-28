import { flushSync, mount, unmount } from "svelte"
import FlowComponent from "../../svelte/Flow.svelte"

// Mounts the Svelte Flow canvas. The LiveView owns the data: the canvas sends
// every change with pushEvent and gets the saved graph back via "flow:graph".
export const Flow = {
  mounted() {
    this.flow = mount(FlowComponent, {
      target: this.el,
      props: {
        graph: JSON.parse(this.el.dataset.graph),
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
  destroyed() {
    unmount(this.flow)
  },
}
