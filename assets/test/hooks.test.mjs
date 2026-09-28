import test from "node:test"
import assert from "node:assert/strict"
import { build } from "esbuild"
import { ChatScroll } from "../js/hooks/chat.js"

test("the Flow hook resyncs the current data-graph on update and reconnect", async () => {
  const { outputFiles } = await build({
    entryPoints: [new URL("../js/hooks/flow.js", import.meta.url).pathname],
    bundle: true,
    write: false,
    format: "esm",
    plugins: [{
      name: "svelte-mount-stub",
      setup(build) {
        build.onResolve({ filter: /^(svelte)$|\.svelte$/ }, (args) => ({ path: args.path, namespace: "stub" }))
        build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({ contents: "export const mount = () => ({}); export const flushSync = () => {}; export const unmount = () => {}; export default {}" }))
      },
    }],
  })
  const { Flow } = await import(`data:text/javascript;base64,${Buffer.from(outputFiles[0].text).toString("base64")}`)
  const graphs = []
  const hook = { el: { dataset: { graph: '{"nodes":[{"id":"new"}]}' } }, flow: { setGraph: (graph) => graphs.push(graph) } }
  Flow.reconnected.call(hook)
  hook.el.dataset.graph = '{"nodes":[]}'
  Flow.updated.call(hook)
  assert.deepEqual(graphs, [{ nodes: [{ id: "new" }] }, { nodes: [] }])
})

function scrollHook(t) {
  let mutation
  const previous = globalThis.MutationObserver
  globalThis.MutationObserver = class {
    constructor(callback) { mutation = callback }
    observe() {}
    disconnect() {}
  }
  t.after(() => { globalThis.MutationObserver = previous })
  const listeners = new Map()
  const scroller = {
    scrollHeight: 1000, clientHeight: 300, scrollTop: 700,
    addEventListener: (event, callback) => listeners.set(event, callback),
    removeEventListener: (event) => listeners.delete(event),
    getBoundingClientRect: () => ({ top: 0 }),
  }
  const button = {
    hidden: true,
    addEventListener: (event, callback) => listeners.set(event, callback),
    removeEventListener: (event) => listeners.delete(event),
  }
  const pushed = []
  const hook = {
    ...ChatScroll,
    el: { dataset: { history: "false" }, children: [], closest: (selector) => selector === "[data-scroll]" ? scroller : { querySelector: () => button } },
    handleEvent: (event, callback) => listeners.set(event, callback),
    pushEvent: (...event) => pushed.push(event),
  }
  hook.mounted()
  return { hook, scroller, button, listeners, pushed, mutate: () => mutation() }
}

test("chat follows nearby readers and offers Jump to latest while reading older messages", (t) => {
  const { hook, scroller, button, listeners, mutate } = scrollHook(t)
  scroller.scrollTop = 690
  listeners.get("scroll")()
  scroller.scrollHeight = 1200
  mutate()
  assert.equal(scroller.scrollTop, 1200)
  assert.equal(button.hidden, true)

  scroller.scrollTop = 100
  listeners.get("scroll")()
  scroller.scrollHeight = 1500
  mutate()
  assert.equal(scroller.scrollTop, 100)
  assert.equal(button.hidden, false)
  listeners.get("click")()
  assert.equal(scroller.scrollTop, 1500)
  assert.equal(button.hidden, true)
  hook.destroyed()
  assert.equal(listeners.has("scroll"), false)
  assert.equal(listeners.has("click"), false)
})

test("earlier pages preserve the visible message and Jump reloads the latest page", (t) => {
  const { hook, scroller, button, listeners, pushed, mutate } = scrollHook(t)
  scroller.scrollTop = 10
  listeners.get("scroll")()
  let top = 5
  hook.el.children = [{ isConnected: true, getBoundingClientRect: () => ({ top, bottom: top + 50 }) }]
  hook.beforeUpdate()
  top = 155
  hook.el.dataset.history = "true"
  hook.updated()
  mutate()
  assert.equal(scroller.scrollTop, 160)
  assert.equal(button.hidden, false)
  listeners.get("click")()
  assert.deepEqual(pushed, [["latest", {}]])
  hook.el.dataset.history = "false"
  listeners.get("chat:latest")()
  assert.equal(scroller.scrollTop, scroller.scrollHeight)
  assert.equal(button.hidden, true)
  hook.destroyed()
})
