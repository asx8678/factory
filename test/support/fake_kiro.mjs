#!/usr/bin/env node
// Stands in for `kiro-cli acp` in tests: answers the ACP handshake and echoes prompts.
// A prompt containing "write" first asks permission to write a file.
import readline from "node:readline"
import { existsSync, readFileSync } from "node:fs"
const out = (msg) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...msg }) + "\n")
const update = (sessionId, update) => out({ method: "session/update", params: { sessionId, update } })
// What a turn cost, reported like Kiro does before the turn ends.
const cost = (sessionId, usage) => update(sessionId, { sessionUpdate: "session_info_update", _meta: { kiro: { promptTurnSummaries: [{ usage }] } } })
let waiting = null
let sessions = 0
// The MCP servers each session was given (Factory's plan tools), by session id.
const mcp = {}
// Calls a Factory tool like Kiro does: announce it, ask permission (MCP requests carry the
// server's name, not a kind), then POST it to the server with the session's headers.
const callTool = (sessionId, name, args) => new Promise((resolve) => {
  const server = mcp[sessionId][0]
  update(sessionId, { sessionUpdate: "tool_call", kind: "other", title: `@${server.name}/${name}`, rawInput: args })
  waiting = async (reply) => {
    waiting = null
    if (reply.result.outcome.optionId !== "accept") return resolve({ denied: true })
    const headers = { "content-type": "application/json" }
    for (const h of server.headers) headers[h.name] = h.value
    const res = await fetch(server.url, { method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }) })
    resolve((await res.json()).result)
  }
  out({ id: 902, method: "session/request_permission", params: { sessionId, toolCall: { title: `@${server.name}/${name}` }, options: [{ optionId: "accept", kind: "allow_once" }, { optionId: "reject", kind: "reject_once" }], _meta: { kiro: { mcpTool: { identity: { serverName: server.name, toolName: name } } } } } })
})
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const m = JSON.parse(line)
  // Tests can leave a particular RPC unanswered without affecting other processes.
  if (existsSync(".fake-kiro-stall") && readFileSync(".fake-kiro-stall", "utf8") === m.method) return
  if (m.id === 900 && waiting) return waiting(m)
  if (m.id === 901 && waiting) return waiting(m)
  if (m.id === 902 && waiting) return waiting(m)
  if (m.method === "initialize") out({ id: m.id, result: { protocolVersion: 1 } })
  // Each session gets its own id; the pid tells tests which process answered.
  if (m.method === "session/new") mcp[`sess_${process.pid}_${sessions + 1}`] = m.params.mcpServers || []
  if (m.method === "session/new")
    out({ id: m.id, result: { sessionId: `sess_${process.pid}_${++sessions}`, configOptions: [{ id: "model", currentValue: "auto" }, { id: "mode", currentValue: "vibe" }] } })
  if (m.method === "_kiro/session/compact") out({ id: m.id, result: { success: true } })
  if (m.method === "session/set_config_option") {
    const { configId, value } = m.params
    if (value === "bad-model") out({ id: m.id, error: { code: -32602, message: "unknown model" } })
    else if (value === "glm-5") out({ id: m.id, result: { configOptions: [{ id: configId, currentValue: "auto" }] } })
    else if (value === "deepseek-3.2") out({ id: m.id, result: {} })
    else out({ id: m.id, result: { configOptions: [{ id: configId, currentValue: value }] } })
  }
  if (m.method === "session/prompt") {
    const { sessionId, prompt } = m.params
    const text = prompt[0].text
    // Hold a turn open while tests deliver timeout and late-response messages.
    if (text.endsWith("[test:wait]"))
      return update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "waiting" } })
    // Task planning: step 1 reads a file (asking permission, which Factory should allow for
    // reads) and asks questions; step 2 suggests tasks.
    if (text.includes('<task-planning step="questions">')) {
      update(sessionId, { sessionUpdate: "tool_call", kind: "read", title: "Read File", locations: [{ path: process.cwd() + "/mix.exs" }] })
      waiting = (reply) => {
        waiting = null
        const plan = { project: `Phoenix app. Read permission: ${reply.result.outcome.optionId}.`, questions: [{ question: "Where should the reset link go?", why: "Decides the route.", options: ["/reset", "/account/reset"] }, { question: "Only one option?", options: ["yes"] }] }
        update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: JSON.stringify(plan) } })
        out({ id: m.id, result: { stopReason: "end_turn" } })
      }
      return out({ id: 901, method: "session/request_permission", params: { sessionId, toolCall: { title: "Read File", kind: "read" }, options: [{ optionId: "allow", kind: "allow_once" }, { optionId: "deny", kind: "reject_once" }] } })
    }
    if (text.includes('<task-planning step="tasks">')) {
      const answered = text.includes("Answer: /account/reset") ? "account" : "default"
      const tasks = [{ title: `Add the reset route (${answered})`, details: "In router.ex.", requirements: ["1.1"], size: "S" }, { title: "Send the email", details: "", requirements: [], size: "XL" }, { title: "" }]
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: JSON.stringify({ tasks }) } })
      cost(sessionId, 0.25)
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    // Planning in a chat, with Factory's tools: a plan and two tasks; asked again, one more
    // task. "[test:unclear]" asks questions, "[test:edit]" renames task 1 and removes task 2,
    // "[test:json]" answers with the JSON plan as if the tools were missing.
    if (text.includes('<task-planning step="chat">')) {
      update(sessionId, { sessionUpdate: "tool_call", kind: "read", title: "Read File", locations: [{ path: process.cwd() + "/mix.exs" }] })
      const again = !text.includes("None yet.")
      const say = (t) => update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: t } })
      const end = () => { cost(sessionId, 0.3); out({ id: m.id, result: { stopReason: "end_turn" } }) }
      if (text.includes("[test:json]")) {
        const tasks = [{ title: "Add the export button to the invoices page", details: ["In `lib/app_web/live/invoices_live.ex`."] }]
        say(JSON.stringify({ reply: "Planned without tools.", tasks }))
        return end()
      }
      ;(async () => {
        say("Let me look at the invoices page first.")
        const results = []
        if (text.includes("[test:unclear]")) {
          results.push(await callTool(sessionId, "ask_user", { questions: [{ question: "Which page gets the button?", options: ["Invoices", "Reports"] }] }))
          say("I need to know where the export goes.")
        } else if (text.includes("[test:edit]")) {
          results.push(await callTool(sessionId, "update_task", { number: 1, title: "Add an Export CSV button" }))
          results.push(await callTool(sessionId, "remove_tasks", { numbers: [2] }))
          say("Renamed the button task and dropped the CSV task.")
        } else if (again) {
          results.push(await callTool(sessionId, "add_tasks", { tasks: [{ title: "Test an empty month", details: ["Returns just the header row."] }] }))
          say("Added a test for an empty month.")
        } else {
          results.push(await callTool(sessionId, "create_plan", { summary: "Export the invoices shown as CSV.", approach: "A button on the invoices page and a small CSV module." }))
          results.push(await callTool(sessionId, "add_tasks", { tasks: [{ title: "Add the export button to the invoices page", details: ["In `lib/app_web/live/invoices_live.ex`."] }, { title: "Write the CSV for the invoices shown", details: ["New `lib/app/invoices/csv.ex`.", "Test it in `test/app/invoices/csv_test.exs`."] }] }))
          say("The invoices page lists invoices in invoices_live.ex; I'd add a button there and a small CSV module.")
        }
        // Tests can see what the tools answered in the log.
        if (results.some((r) => r.denied || r.isError)) say(` [tool trouble: ${JSON.stringify(results)}]`)
        end()
      })()
      return
    }
    // Planning a factory run: requirements, design, tasks; the workflow and model when asked.
    // An overview containing "no plan" gets a reply without tasks.
    if (text.includes('<task-planning step="run">')) {
      update(sessionId, { sessionUpdate: "tool_call", kind: "read", title: "Read File", locations: [{ path: process.cwd() + "/mix.exs" }] })
      const plan = {
        requirements: "# Requirements\n\n1. WHEN a user logs in THEN they SHALL land on their dashboard",
        design: "# Design\n\nThe redirect in `session_controller.ex` drops the return path.",
        tasks: text.includes("no plan") ? [] : [{ title: "Add a failing test for the redirect", details: ["In `test/session_test.exs`."], requirements: ["1"] }, { title: "Keep the return path", details: [], requirements: ["1"] }],
        why: "The redirect lives in session_controller.ex.",
      }
      cost(sessionId, 0.4)
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: JSON.stringify(plan) } })
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    // Writing a new task from an idea: the title repeats the idea's first line.
    if (text.includes('<task-planning step="draft">')) {
      const idea = text.split("The person's rough idea for the task:\n")[1].split("\n")[0]
      const task = { title: `Scoped: ${idea}`, details: ["Add `lib/export.ex`.", "Test it in `test/export_test.exs`."], requirements: ["2.1"], why: "Looked at 2 files." }
      update(sessionId, { sessionUpdate: "tool_call", kind: "search", title: "Search" })
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: JSON.stringify(task) } })
      cost(sessionId, 0.25)
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    // Improving a task: the new title says what was asked for, so tests can check it arrived.
    if (text.includes('<task-planning step="improve">')) {
      const asked = text.split("What the person wants done better:\n")[1].split("\n")[0]
      const task = { title: `Better: ${asked}`, details: ["Edit `lib/a.ex`.\nThen test it.", 3], requirements: ["1.1"], why: "Named the file." }
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: JSON.stringify(task) } })
      cost(sessionId, 0.25)
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    // A spec review answers with JSON in a fence, split over chunks like Kiro streams it;
    // a spec containing "unreadable" gets prose instead.
    if (text.includes("<run-title>")) {
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: '"Login redirect after draft save."\n' } })
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    if (text.includes("<spec-review>")) {
      const review = { score: 62, summary: "Clear goal, but most requirements lack acceptance criteria.", checks: [{ id: "acceptance", status: "fail", note: "Requirement 2 has no acceptance criteria." }, { id: "requirements", status: "pass", note: "Each requirement is specific." }, { id: "made_up", status: "pass", note: "ignored" }], improvements: ["Add WHEN/THEN criteria to Requirement 2."] }
      const reply = text.includes("unreadable") ? "This spec looks fine to me." : "```json\n" + JSON.stringify(review) + "\n```"
      for (const part of [reply.slice(0, 20), reply.slice(20)]) update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: part } })
      cost(sessionId, 0.25)
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    // A step told to send the work back does, until it's another pass.
    if (text.includes("[test:send-back]") && text.includes("Send back: <what to fix>")) {
      const again = text.includes("This is another pass")
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: again ? "Checked.\nApproved" : "Checked.\nSend back: add the missing test" } })
      return out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    const finish = () => {
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "echo: " } })
      update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text } })
      // Like Kiro: context use with a token breakdown (10,000 tokens = 1% -> window about 1M).
      update(sessionId, { sessionUpdate: "session_info_update", _meta: { kiro: { kind: "context_usage", contextUsage: { usagePercentage: 2 }, breakdown: { tools: { tokens: 10000, percent: 1 }, yourPrompts: { tokens: 3, percent: 0.1 } } } } })
      update(sessionId, { sessionUpdate: "session_info_update", _meta: { kiro: { promptTurnSummaries: [{ usage: 0.05 }] } } })
      out({ id: m.id, result: { stopReason: "end_turn" } })
    }
    if (text.includes("write")) {
      let options = [{ optionId: "allow", kind: "allow_once" }, { optionId: "deny", kind: "reject_once" }]
      if (text.includes("[test:allow-only]")) options = options.slice(0, 1)
      if (text.includes("[test:reject-only]")) options = options.slice(1)
      if (text.includes("[test:no-options]")) options = []
      waiting = (reply) => { waiting = null; update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `[${reply.result.outcome.optionId || reply.result.outcome.outcome}] ` } }); finish() }
      out({ id: 900, method: "session/request_permission", params: { sessionId, toolCall: { title: "Write notes.md", kind: "edit" }, options } })
    } else finish()
  }
})
