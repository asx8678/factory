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

## Next

1. **Create tasks after the run has started.** Messages to the planner then go to its
   own `Kiro.Session`, which has the run tools but not the plan tools, so "create tasks
   for X" does nothing. Give sessions the plan tools too (the session token already
   resolves to the current turn; a planner turn outside a run step would resolve to the
   run and its `planner_generation`). This also lets the draft planner use its session
   instead of a fresh `Kiro.ask`, so follow-ups keep their context and cost less.
2. **Asking for tasks without a planner.** "Fix a bug" and "Update dependencies" have no
   planner agent, so the chat sends a request to the first agent (Investigator,
   Auditor), which can't write tasks; plain text to Factory itself only takes slash
   commands. Either route a draft's plain text to a planning turn whatever the first
   agent is, or give those workflows a planner.
3. **Spec page "Suggest tasks"** (`Specs.plan_questions/2`, `plan_tasks/2`): still its own
   two-turn JSON flow. Moving it onto the tools would need a place for suggestions to
   wait until they're picked (`spec.plan`), since the tools write the spec directly.
4. **Questions in the chat.** The "Not clear enough to plan yet" badge shows even when
   tasks came with the questions; questions asked alongside a plan are plain text under
   it, not choices to click (`meta["questions"]` is stored). MCP elicitation for
   mid-turn questions is untried (Kiro supports it, but it holds the turn open).
5. **Loose action cards on the canvas** now don't run, but the Workflows page doesn't
   say so. Mark them ("Not connected: won't run") on the card.
6. **Don't resend the job and spec** to a session that already has them on a later step.
   Interacts with `primed`, `carry` and `restart` after compaction.

Done since the first version: one task shape (`Factory.Specs.Planner.task/1`, `task_json/0`),
and the boot reset no longer logs a sandbox error in tests (`reset_on_boot`).
