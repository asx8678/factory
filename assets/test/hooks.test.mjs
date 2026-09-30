import test from "node:test"
import assert from "node:assert/strict"
import { build } from "esbuild"
import { ChatScroll } from "../js/hooks/chat.js"
import { QuestionKeys } from "../js/hooks/question_keys.js"
import { ChatKeys } from "../js/hooks/chat_keys.js"

test("the Flow hook resyncs data-graph on reconnect only, and skips one it can't read", async () => {
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
  // Changes reach the canvas once, as "flow:graph" events: nothing re-reads data-graph on update.
  assert.equal(Flow.updated, undefined)
  hook.el.dataset.graph = "{not json"
  const error = console.error
  console.error = () => {}
  try {
    Flow.reconnected.call(hook)
  } finally {
    console.error = error
  }
  assert.deepEqual(graphs, [{ nodes: [{ id: "new" }] }])
})

// A stand-in element: `is` lists the selectors it matches (closest only looks at itself).
function stub(is, extra = {}) {
  const el = {
    matches: (selector) => selector.split(",").some((s) => is.includes(s.trim())),
    ...extra,
  }
  el.closest = (selector) => (el.matches(selector) ? el : null)
  return el
}

function keyHook(t, Hook, { inside = [], extra = {} } = {}) {
  const body = stub(["body"])
  const previous = globalThis.document
  globalThis.document = { body, getElementById: () => null, ...extra }
  t.after(() => { globalThis.document = previous })
  let listener
  const previousWindow = globalThis.window
  globalThis.window = { addEventListener: (_event, callback) => (listener = callback), removeEventListener: () => {} }
  t.after(() => { globalThis.window = previousWindow })
  const hook = {
    ...Hook,
    el: { contains: (target) => inside.includes(target), submitted: 0, requestSubmit() { this.submitted++ }, querySelector: () => null },
    pushed: [],
    pushEvent(...event) { this.pushed.push(event) },
  }
  hook.mounted()
  const press = (key, target, mods = {}) => {
    const e = { key, target, prevented: false, preventDefault() { this.prevented = true }, ...mods }
    listener(e)
    return e
  }
  return { hook, body, press }
}

test("question keys leave links and buttons outside the form alone", (t) => {
  const link = stub(["a"])
  const menuitem = stub(["button", "[role=menuitem]"])
  const { hook, body, press } = keyHook(t, QuestionKeys)
  assert.equal(press("Enter", link).prevented, false)
  assert.equal(press("Enter", menuitem).prevented, false)
  assert.equal(press("a", link).prevented, false)
  assert.equal(hook.el.submitted, 0)
  assert.equal(press("Enter", body).prevented, true)
  assert.equal(hook.el.submitted, 1)
})

test("question keys pick options and move on from inside the form", (t) => {
  const radio = stub(["input", "input[type=radio]"], { checked: false, value: "b", events: [], dispatchEvent(e) { this.events.push(e.type) } })
  const option = { querySelector: (selector) => (selector === "input[type=radio]" ? radio : null) }
  const text = stub(["input", "input:not([type=radio])", "input[type=text]"])
  const link = stub(["a"])
  const { hook, body, press } = keyHook(t, QuestionKeys, { inside: [radio, text, link] })
  hook.el.querySelector = (selector) => (selector === '[data-key="b"]' ? option : null)
  assert.equal(press("Enter", radio).prevented, true)
  assert.equal(press("Enter", text).prevented, false)
  assert.equal(press("Enter", link).prevented, false)
  assert.equal(hook.el.submitted, 1)
  assert.equal(press("b", text).prevented, false)
  assert.equal(press("b", link).prevented, false)
  assert.equal(radio.checked, false)
  assert.equal(press("B", body).prevented, true)
  assert.equal(radio.checked, true)
  assert.deepEqual(radio.events, ["input"])
  assert.equal(press("b", radio).prevented, true)
})

test("chat keys open Plan only when nothing that uses the key has the focus", (t) => {
  const summary = stub(["summary"])
  const link = stub(["a"])
  const input = stub(["input"])
  let focused = 0
  const { hook, body, press } = keyHook(t, ChatKeys, { inside: [summary, link, input], extra: { getElementById: () => ({ focus: () => focused++ }) } })
  press("p", summary)
  press("P", link)
  press("p", input)
  press("p", stub(["div"]))
  assert.deepEqual(hook.pushed, [])
  assert.equal(press("p", body).prevented, true)
  assert.deepEqual(hook.pushed, [["tasks", {}]])
  assert.equal(press("k", input, { metaKey: true }).prevented, true)
  assert.equal(focused, 1)
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
