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
- `mix precommit`: 206 tests pass. The fake Kiro (`test/support/fake_kiro.mjs`) calls
  the tools over HTTP; planning tests start a Bandit listener and set `:mcp_url`.

## Next

1. **Persistent planner session.** Give `Factory.Kiro.Session` the Factory MCP server
   for planner agents, so follow-up messages keep their context (cheaper and faster
   than a fresh `Kiro.ask` each time) and `/ask Planner create tasks for X` works after
   the draft too. The token would map to the session; the tool finds the run from the
   session's current turn. Its permission check (`Agent.tools/1` by kind) needs the same
   `serverName` rule as `Kiro.Ask`.
2. **Spec page "Suggest tasks"** (`Specs.plan_questions/2`, `plan_tasks/2`): move onto
   the same tools, writing suggestions into `spec.plan` for picking instead of straight
   into the tasks.
3. **One task shape.** `run_prompt`, the questions/tasks prompts and the chat prompt
   describe tasks differently (details as string vs list, `size`). Make the
   `add_tasks` schema the single shape.
4. **Smaller items:** the `unclear` badge text assumes no tasks; show questions asked
   alongside a plan in the chat UI (`meta["questions"]` is already stored); consider
   MCP elicitation for mid-turn questions (Kiro supports it, but it holds the turn open).
5. **Pre-existing, unrelated:** `Specs.reset_reviews/0` at boot logs a sandbox
   ownership error in tests.
