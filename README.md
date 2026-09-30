# Factory

Factory runs a team of coding agents on [Kiro](https://kiro.dev) against a project
folder on your machine. You describe a change in the chat, a planner turns it into a
spec (requirements, design, tasks), and a workflow of agents (planner, coder, tester,
reviewer…) works through the tasks, handing over to each other along the arrows you
draw on the Workflows canvas. Actions between agents can run a command, commit and
push, open a pull request, update a ticket, or send a message.

## What you need

* Elixir 1.17+ and PostgreSQL (the dev config expects `postgres`/`postgres` on localhost)
* Node.js, for the Svelte Flow canvas (`mix assets.setup` runs `npm install`)
* `kiro-cli` 2.24 or later, signed in (`kiro-cli login`). Factory looks for it on your
  `PATH`, else at `~/.local/bin/kiro-cli`; see `config :factory, :kiro` in `config/config.exs`.

## Run it

```sh
mix setup
mix phx.server
```

Then open [localhost:4000](http://localhost:4000), choose a project folder and describe
what you want built. Kiro's logs go to `tmp/kiro-logs`; cloned data sources to `tmp/sources`.

## Workflows

Pick one in the chat's header. Each is a set of agents you can change on the Workflows
page, and restore to how it came (runs that used its agents keep what they handed over).
When Factory's own prompts improve, agents you haven't changed get them at startup; one
you've changed keeps yours until you restore it.

* **Build a feature**: a planner, a coder, a tester and a reviewer. Describe the change;
  the planner reads the code and writes the tasks; start it, and they build task by task.
* **Fix a bug**: the same shape, starting from reproducing the bug.
* **Review a PR**: first choose the repository (a folder on this computer, or a link to
  clone with SSH into `~/repo-reviews`); then see what's in it worth reviewing, the
  suggested change first. The Scout plans the checks and the Reviewer reports.
* **Troubleshoot an issue**: paste an error, a stack trace or logs, optionally with the
  code ("With the code": a folder or a clone). The Triage Lead works out what it is and
  picks a quick check or a full investigation; an Error Researcher looks the error up on
  the web; the team traces it to the root cause; a Fact Checker checks the claims on the
  web; a Devil's Advocate can send it back; the Incident Reporter writes the answer. Log
  files dropped into the chat (`.log`, `.json`, `.csv`, up to 20 MB) are kept whole for
  the agents to search, in `tmp/evidence`. The two agents that search the web never see
  what you pasted, only what the others hand them, with internal hosts, user names, your
  folders, IDs and secrets taken out, and the names you list under Settings → Web
  searches. When it's done, **Fix it** starts a Fix a bug chat from the report.

Agents that only read ask you first, in the chat, before they fetch a web page, read
outside the project, or run a pull request's own code.

A run pauses once it has used 10 credits and asks whether to go on (Continue lets it use
as many again); the header shows what it has used against that. Change the limit, or
turn it off with 0, under Settings → Runs. If Kiro refuses for its monthly usage limit,
every page says so until it answers again.

## Environment variables

Factory never stores tokens. Actions and data sources name an environment variable and
read it when they run, so set these in the shell that starts Factory:

| Variable | Used by |
| --- | --- |
| `GITHUB_TOKEN` | Create GitHub PR, Update GitHub issue (default name; each action can name its own) |
| `AZURE_DEVOPS_PAT` | Azure DevOps PRs and tickets, and cloning Azure DevOps repositories |
| `SLACK_WEBHOOK_URL` | Slack or Teams message (default name) |
| `TZ` | The time zone the Usage page counts days in (else the system zone) |

## Running it for others

Factory has no sign-in. It can browse this machine's files, read its environment
variables and run commands in the project folder, so it is meant to run on your own
machine. In production it listens on `127.0.0.1` only; set `PHX_BIND_ALL=true` to
listen on every interface, and put something that authenticates in front of it first.
The planner's tools are reached over HTTP at the endpoint's URL, so with a public
`PHX_HOST` set `config :factory, :mcp_url` to where Kiro on the same machine can reach Factory.

## Development

```sh
mix precommit   # compile with warnings as errors, format, build assets, run the tests
mix test test/factory/engine_test.exs
```

After pulling a change to `config :mime, :types` (Factory adds `.log`), run
`mix deps.compile mime --force` once.

The tests talk to a fake `kiro-cli` (`test/support/fake_kiro.mjs`), so they don't need
Kiro or credits. `docs/plan-tools.md` describes the planner's MCP tools and what's next.
