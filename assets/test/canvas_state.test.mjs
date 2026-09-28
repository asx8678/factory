import test from "node:test"
import assert from "node:assert/strict"
import { reconcileNodes, reconcileEdges, validConnection } from "../js/canvas_state.js"

test("graph updates preserve drag positions, measurements and multi-selection by id", () => {
  const current = [
    { id: "1", position: { x: 100, y: 200 }, dragging: true, selected: true, measured: { width: 240 } },
    { id: "2", position: { x: 0, y: 0 }, selected: true },
    { id: "removed", selected: true },
  ]
  const incoming = [
    { id: "2", position: { x: 30, y: 40 }, selected: false, data: { status: "done" } },
    { id: "1", position: { x: 0, y: 0 }, selected: false, data: { status: "running" } },
    { id: "new", position: { x: 1, y: 2 }, selected: false },
  ]
  const [second, first, added] = reconcileNodes(current, incoming)
  assert.deepEqual(first.position, { x: 100, y: 200 })
  assert.deepEqual(first.measured, { width: 240 })
  assert.equal(first.dragging, true)
  assert.equal(first.selected, true)
  assert.equal(first.data.status, "running")
  assert.deepEqual(second.position, { x: 30, y: 40 })
  assert.equal(second.selected, true)
  assert.deepEqual(added, incoming[2])
  assert.deepEqual(reconcileNodes([{ ...first, dragging: false }], [incoming[1]])[0].position, { x: 0, y: 0 })
})

test("edge refreshes preserve selection and update server data", () => {
  const edges = reconcileEdges([{ id: "l1", selected: true }], [{ id: "l1", data: { prompt: "Updated" } }, { id: "l2" }])
  assert.equal(edges[0].selected, true)
  assert.equal(edges[0].data.prompt, "Updated")
  assert.equal(edges.length, 2)
})

const nodes = [
  { id: "1", type: "agent" }, { id: "2", type: "agent" },
  { id: "3", type: "agent" }, { id: "4", type: "action" },
  { id: "source-1", type: "source" }, { id: "source-2", type: "source" },
]

test("reconnections keep workflow and attachment arrow types", () => {
  const handoff = { id: "l1", source: "1", target: "2" }
  const attachment = { id: "sl1", source: "source-1", target: "2" }
  assert.equal(validConnection({ source: "1", target: "source-1" }, nodes, [handoff], handoff), false)
  assert.equal(validConnection({ source: "1", target: "2" }, nodes, [attachment], attachment), false)
  assert.equal(validConnection({ source: "source-2", target: "3" }, nodes, [attachment], attachment), true)
  assert.equal(validConnection({ source: "1", target: "3" }, nodes, [handoff], handoff), true)
  assert.equal(validConnection(handoff, nodes, [handoff], handoff), true)
})

test("connections reject missing nodes, duplicates, self loops and sources attached to actions", () => {
  assert.equal(validConnection({ source: "missing", target: "2" }, nodes, []), false)
  assert.equal(validConnection({ source: "1", target: "1" }, nodes, []), false)
  assert.equal(validConnection({ source: "source-1", target: "source-2" }, nodes, []), false)
  assert.equal(validConnection({ source: "source-1", target: "4" }, nodes, []), false)
  assert.equal(validConnection({ source: "4", target: "source-1" }, nodes, []), false)
  assert.equal(validConnection({ source: "2", target: "source-1" }, nodes, [{ id: "sl1", source: "source-1", target: "2" }]), false)
  assert.equal(validConnection({ source: "1", target: "4" }, nodes, []), true)
})
