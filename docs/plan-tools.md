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
  token (it doesn't expire; the session existing is the gate); a tool call resolves to
  the step the session is answering and is refused outside one.
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

## Open

1. **MCP elicitation** for mid-turn questions is untried: Kiro supports it, but it holds
   the turn open while the person answers. The chat's question choices cover the
   common case.
2. **Draft planning still uses a fresh `Kiro.ask`** per message (it's what guards against
   a replaced request with `planner_generation`). The planner's session now has the
   tools, so drafts could move onto it for context and cost; the generation guard would
   have to move with it.
3. **The chat's message box** says "Describe a change…" only for planner-kind agents;
   an Investigator or Auditor that plans a draft shows "Message Investigator…".
4. `test/factory/runs_test.exs` "pruning removes stale empty chats" failed once in a
   full run and not in eight others; cause not found.
