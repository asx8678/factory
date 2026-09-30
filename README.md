# Factory

Factory runs a team of coding agents on [Kiro](https://kiro.dev) against a project
folder on your machine. You describe a change in the chat, a planner turns it into a
spec (requirements, design, tasks), and a workflow of agents (planner, coder, tester,
reviewer…) works through the tasks, handing over to each other along the arrows you
draw on the Workflows canvas. Actions between agents can run a command, commit and
push, open a pull request, update a ticket, or send a message.

## What you need

* Elixir 1.18+ and PostgreSQL (the dev config expects `postgres`/`postgres` on localhost)
* Node.js, for the Svelte Flow canvas (`mix assets.setup` runs `npm install`)
* `kiro-cli` 2.24 or later, signed in (`kiro-cli login`). Factory looks for it on your
  `PATH`, else at `~/.local/bin/kiro-cli`; see `config :factory, :kiro` in `config/config.exs`.
* `git`, to clone the repositories you review and read what there is to review in a
  project folder. GitHub's `gh`, signed in, is optional: with it the chat lists a
  repository's open pull requests.

## Run it

```sh
mix setup
mix phx.server
```

Then open [localhost:4000](http://localhost:4000), choose a project folder and describe
what you want built. Kiro's logs go to `tmp/kiro-logs`; cloned data sources to `tmp/sources`.

## Review a pull request

Pick "Review a PR" in the chat and paste a link: a pull request
(`https://github.com/owner/repo/pull/12`), a repository (`https://github.com/owner/repo`
or `git@github.com:owner/repo.git`), or a folder on your machine. Factory clones the
repository over SSH into `~/repo-reviews/<owner>/<repo>` (set
`config :factory, :review_dir` to put it elsewhere), fetches it again when you paste
the same link later, and fetches a pull request as its own branch, `pr-12`. Then it
shows what there is to review in the folder: the branch it's on, the branches with the
latest work and how far ahead they are, and, with `gh` signed in, the open pull requests.

You need `git` and an SSH key that can read the repository (`ssh -T git@github.com`
tells you whether GitHub accepts it); git runs without a terminal, so a key that needs a
passphrase typed in fails rather than waits. An SSH host Factory hasn't seen before is
trusted on first contact and its key remembered.

## Environment variables

Factory never stores tokens. Actions and data sources name an environment variable and
read it when they run, so set these in the shell that starts Factory:

| Variable | Used by |
| --- | --- |
| `GITHUB_TOKEN` | Create GitHub PR, Update GitHub issue (default name; each action can name its own) |
| `AZURE_DEVOPS_PAT` | Azure DevOps PRs and tickets, and cloning Azure DevOps repositories |
| `SLACK_WEBHOOK_URL` | Slack or Teams message (default name) |
| `TZ` | The time zone the Usage page counts days in (else the system zone) |
| `FACTORY_ACTION_ENV_VARS` | The variables actions may name, comma-separated (`config :factory, :action_env_vars`). Unset, any plain upper-case name but Factory's own secrets (`SECRET_KEY_BASE`, `DATABASE_URL`, anything with SECRET, PRIVATE_KEY or PASSWORD in it) |
| `FACTORY_ALLOW_PRIVATE_ACTION_URLS` | `true` lets API requests and webhooks reach this machine or a private network; by default they call public addresses only |

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

The tests talk to a fake `kiro-cli` (`test/support/fake_kiro.mjs`), so they don't need
Kiro or credits. `docs/plan-tools.md` describes the planner's MCP tools and what's next.
