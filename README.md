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
* Optionally [pi](https://github.com/earendil-works/pi) with its ACP adapter
  (`npm install -g pi-acp`), to run the agents on when Kiro can't be used: see
  [Kiro or pi](#kiro-or-pi).
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

## Workflows

Pick one in the chat's header. Each is a set of agents you can change on the Workflows
page, and restore to how it came (runs that used its agents keep what they handed over).
When Factory's own prompts improve, agents you haven't changed get them at startup; one
you've changed keeps yours until you restore it.

* **Build a feature**: a planner, a coder, a tester and a reviewer. Describe the change;
  the planner grills the code and writes the tasks; start it, and they build task by task.
* **Fix a bug**: the same shape, starting from reproducing the bug and finding its cause.
* **Review a PR**: first choose the repository (a folder on this computer, or a link to
  clone with SSH into `~/repo-reviews`); then see what's in it worth reviewing, the
  suggested change first. The Scout plans the checks and the Reviewer reports (see
  [Review a pull request](#review-a-pull-request)).
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

Before it plans, the planner grills the code so you don't have to: it puts a set of
questions to the code around what you asked (does it exist already, how does it work
today, what depends on it, what happens if it's built, is it a good fit) and answers
them from what it reads. A bug and a pull request have their own questions. What it
found is kept with the plan (the Spec page's design, under "What the code says"), where
the agents that build read it. It then asks you only what the code can't say, up to 10
questions with the option it recommends first. **Grill code**, on the plan, does this
again on its own and reports with a verdict (Go ahead, Change the plan or Don't do it),
changing nothing; **Refine** acts on the report.

Agents that only read ask you first, in the chat, before they fetch a web page, read
outside the project, or run a pull request's own code.

A run pauses once it has used 10 credits and asks whether to go on (Continue lets it use
as many again); the header shows what it has used against that. Change the limit, or
turn it off with 0, under Settings → Runs. If Kiro refuses for its monthly usage limit,
every page says so until it answers again.

## Kiro or pi

Agents run on Kiro unless you choose pi under Settings → Runtime, which shows what's
installed (`kiro-cli`, and `pi` with `pi-acp`). When Kiro is signed out or at its usage
limit and pi is installed, the warning in the header has a **Use pi** button; the
header then says it's on pi. Changing the runtime stops the sessions running, and the
next message starts on the new one.

pi is driven the same way as Kiro, through its ACP adapter, with Factory's own
extension (`priv/pi/factory.ts`) loaded instead of yours, plus the one that brings the
chosen model's provider. What differs on pi:

* **One model.** Every agent runs on the model chosen in Settings (pi's own default
  unless you pick one); models on agents' cards and in plans are Kiro's and aren't used.
* **Tools are checked, not asked about.** pi never asks before it uses a tool, so the
  extension asks Factory before each one, by the same rules as on Kiro: an agent that
  only reads can't edit or run commands that change things, and nothing is read
  outside the project and its sources. What Kiro would ask you first (a web page, a
  file outside the project, a pull request's own code) is refused.
* **Questions come when the turn ends**, not during it.
* **No credits.** pi doesn't report them, so usage shows the calls and their time, and
  a run's credit limit never stops it.

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

After pulling a change to `config :mime, :types` (Factory adds `.log`), run
`mix deps.compile mime --force` once.

The tests talk to a fake `kiro-cli` (`test/support/fake_kiro.mjs`), so they don't need
Kiro or credits. `docs/plan-tools.md` describes the planner's MCP tools and what's next.
