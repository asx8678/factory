# Planner tools (MCP): status and next steps

The chat planner writes its plan with Factory's own tools instead of replying with one
JSON blob: it reads the project, calls `create_plan` (summary + approach), then
`add_tasks` a few at a time, and on later messages refines the plan with `update_task`
and `remove_tasks`. It can `ask_user` questions. Tasks show up live in the planner's
chat bubble.

## How it fits together

- `Factory.PlanTools`: the tools (`get_plan`, `create_plan`, `add_tasks`,
  `update_task`, `remove_tasks`, `ask_user`). A signed token per planning request binds
  calls to `{run_id, planner_generation, waiting pid}`; a call only writes while the run
  is a draft and that generation is the latest. The plan is the run's spec: approach in
  `design` (only when it's empty or starts with `# Approach`), tasks in `tasks`.
- `FactoryWeb.MCP` at `/mcp`: minimal MCP over HTTP (JSON responses, no SSE; `GET` → 405).
  A bad token is a tool error, not HTTP 401 (Kiro treats the server as OAuth).
- `Factory.Kiro.Ask`: `mcp_servers:` goes into ACP `session/new`; MCP permission
  requests carry no `kind`, so they're allowed by
  `_meta.kiro.mcpTool.identity.serverName`. `reply: :last` returns only the text after
  the last tool call.
- `Factory.ChatPlanner`: grants the token, collects `{:plan_tools, generation, event}`
  messages after Kiro's turn, and falls back to the old JSON plan if no tool was called.

## Verified

- Real `kiro-cli` 2.24.1: plan with 3 tasks in 21 s / 0.51 credits; a refinement used
  `update_task` + `remove_tasks` in 14 s / 0.35 credits.
- Real `kiro-cli` 2.26.0 (30 Sep 2026), on a throwaway Elixir project: the planner wrote
  an approach and 2 tasks (0.35 credits), and a follow-up edited both in place. Started,
  the Coder built them and marked both done with `complete_tasks`, the Tester ran the
  suite, and the Reviewer approved with `verdict`. A run planned in the chat cost 1.34
  credits end to end.
- Kiro 2.26 sends `session/request_permission` without the tool's kind; see
  `Factory.Kiro.Permission.kind/2`, which takes it from the earlier `tool_call` update or
  `_meta.kiro.toolId`. Without it every write and command was refused.
- The fake Kiro (`test/support/fake_kiro.mjs`) calls the tools over HTTP; planning tests
  start a Bandit listener and set `:mcp_url`.

## Run tools

- `Factory.RunTools` on the same `/mcp` server: `get_tasks` and `complete_tasks` for steps
  that change the project, `verdict` for a step with an arrow back. The token decides
  which tool set `tools/list` gives (`FactoryWeb.MCP`).
- Run steps run on each agent's own `Factory.Kiro.Session` (`Factory.Kiro.run_step/4`),
  not a throwaway `Kiro.ask`. Every session gets Factory's MCP server with a session
  token tied to the kiro-cli process it was given to (a nonce made at each start): a
  call from a process that has since restarted is refused, so it can't act on the next
  turn. A tool call resolves to the step the session is answering and is refused
  outside one.
- Standard workflows have an arrow from the Reviewer back to the builder, so `verdict`
  can send work back (up to `config :factory, :max_loop_rounds`, default 2).
- A planner step whose run already has its tasks hands them on without a second
  planning turn. An action card with no arrows, in a workflow with agents, doesn't run.

## Planning from the chat, after the start, and on the Spec page

- A planning agent's Kiro session (planner, researcher or orchestrator kind) also has
  the plan tools. In a chat message, the agent that plans the run
  (`Factory.Chat.planner_for/1`) can read and change the plan before or after the run
  starts (`Factory.PlanTools.call_in_turn/4`); after the start the plan can't be
  replaced, and the run's tasks follow the spec, keeping which are done. The message
  reminds the planner that only the tools change the plan.
- `/run` on a finished run with open tasks runs it again; each step's prompt lists which
  tasks are done.
- Workflows without a planner plan with their first agent when it's a researcher or an
  orchestrator; plain text to Factory on a draft goes to that planner.
- A planner's questions with options show as choices in the chat; "Send answers" posts
  them to the planner.
- The Spec page's "Suggest tasks" adds suggestions with `suggest_tasks` into
  `spec.plan["tasks"]` as they come (a token per round); the JSON reply is the fallback.
- A run step's prompt is a brief (role, job, rules, spec, sources, instructions) and an
  ask; the session sends the brief once per agent and run (again after a compaction or
  restart, or when it changes).
- Action cards with no arrows are marked on the canvas ("Not connected: runs skip it").

Verified on Kiro 2.26 (30 Sep 2026): after a run finished, the planner added a task with
`get_plan` + `add_tasks` and `/run` built only that task; Spec page suggestions arrived
3 at a time (20 in 40 s).

## Asking the person mid-turn (MCP elicitation)

- Kiro 2.26 forwards a tool's `elicitation/create` to its ACP client as
  `_kiro/mcp/elicitation` (`{sessionId, toolCallId, elicitation: {mode: "form",
  message, requestedSchema}}`) and takes `{action: "accept" | "decline" | "cancel",
  content}` back; it waited at least 150 s for an answer. It declares elicitation
  (form and url) when it connects to an MCP server.
- `Factory.Kiro.Session` posts the question to the run's chat as a form from its schema
  and waits; the chat's answer goes back through `Factory.Kiro.answer_elicitation/4`.
  Open questions are cancelled when the turn ends. `Factory.Kiro.Ask` cancels them.
- `FactoryWeb.MCP` can elicit too: a tool returning `{:elicit, request, then}` gets an
  SSE answer carrying `elicitation/create`; the answer Kiro posts back is routed to it
  through `Factory.Kiro.Registry`. The planner's `ask_user` in a session turn uses it,
  falling back to questions after the turn.
- Only form mode is handled; a `url` elicitation is cancelled.

## Also done

- Drafts plan on the planner's own session (`Factory.ChatPlanner`), with the generation
  guard in the plan tools and the spec files sent as a brief; a one-off `Kiro.ask` when
  that session is busy in another folder. On Kiro 2.26 a follow-up cost 0.20 credits,
  against 0.35 one-off.
- The message box hint follows the agent that plans the run.
- Two intermittent test failures fixed: tests clearing the `:context` settings, and the
  unboxed spec concurrency test running beside async tests.

## What agents may do without asking

- `Factory.Kiro.Permission` answers Kiro's permission requests. Agents that build get
  every tool. Agents that only read (planner, researcher, reviewer) get reading and
  searching, and commands that only look (`looking?/1`: no `&`, no `VAR=` prefix, no
  option that writes a file or runs a program).
- Some of what a reading agent may do goes to the person first, as a Yes or No card in
  the chat (`Kiro.Permission.ask_first/5`, `Kiro.Session.ask_permission/4`): fetching a
  web page, running the project's own code (tests, a build) in a pull request cloned for
  review, and reading outside the project folder. A card nobody answers within half the
  turn's time is a No. One-off sessions (`Kiro.Ask`) have nobody to ask and refuse.
- An agent set to search the web (`web` on its card, like the troubleshooting
  workflow's Error Researcher and Fact Checker) fetches without asking. It isn't shown
  the person's own material (the job), and what it's handed is filtered first
  (`Factory.Redact`: internal hosts, IPs, emails, `user=` names, paths in a home folder,
  IDs, keys and tokens come out, and the names listed under Settings → Web searches, as
  whole words).
- Comments in a command (`# why`) don't count when deciding whether it only looks, as
  the shell ignores them; nor does a `sed 's/…/…/'` that only changes what it prints.
- Factory waits for Kiro to say its tools are loaded (`_kiro/mcp/status`, at most
  `:mcp_ready_timeout`) before an agent's first message, and when kiro-cli stops, ends
  what it started (`OsProcess.kill_known/1`), such as MCP servers.
- A tool may ask the person to open a web page (URL-mode elicitation): the card shows the
  link, for http and https only, and says when it's done or declined.
- Kiro's own working files (`~/.kiro/sessions/…`, where it keeps big tool results to read
  back) and a troubleshooting run's attached files (`Factory.Evidence`, not for the web
  agents) count as inside the project.
- Kiro 2.26 names its tools on the request (`_meta.kiro.toolId`) and often sends no kind:
  `read_file`, `run_command`, `web_fetch`, `remote_web_search` (its search runs on a
  server of its own, "remote"). `Permission.kind/2` maps them.

## Kiro signed out

When kiro-cli stops, the reason comes from what it wrote to its log since it started
(`Kiro.stop_reason/3`): "Kiro isn't signed in…" rather than an exit code. Every page's
header then warns until a check or a session works again (`FactoryWeb.KiroStatus`), and
the failure in the chat has a Try again button (`Chat.retry/2`).

## Verified on real Kiro 2.26 (30 Sep 2026)

A troubleshooting run of a pasted Node.js `EADDRINUSE` error, with no repository: the
Triage Lead planned three checks with the plan tools, and all nine steps ran to a report
(9.9 credits). It showed that Kiro asks before reading files (`read_file`), that
`web_fetch` works for a web agent, and that `remote_web_search` wasn't recognised then
(since mapped). The Yes or No card worked with a reading agent fetching a page.

## Open

- A Kiro session's MCP tools load after `session/new` answers; a message sent at once
  may reach the model before they're listed. Factory's first messages have worked in
  practice (the agent reads files first), but nothing waits for the tools.
- URL-mode elicitation (open a link, then carry on) isn't handled.
