# Worker

Automated Jira ticket implementation pipeline using Claude Code. Two cooperating loops:

- **scheduler** — polls Jira for sprint tickets, checks readiness, decomposes into subtasks, creates git worktrees
- **ralph** — picks up subtasks, invokes Claude to implement them, runs tests, commits, and triggers spec + quality reviews

## Prerequisites

- [Nushell](https://www.nushell.sh/)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- [Jira CLI](https://github.com/ankitpokhrel/jira-cli) (configured with your instance)
- SQLite3

## Setup

Copy `.env` and fill in your values:

```sh
cp .env.example .env
```

| Variable | Description |
|---|---|
| `JIRA_ASSIGNEE` | Your Jira email address |
| `JIRA_PROJECT` | Jira project key (e.g. `APS`) |

The `.env` file is loaded automatically at startup. You can also export the variables directly.

## Usage

Run the scheduler and ralph in separate terminals:

```sh
nu scheduler.nu
nu ralph.nu
```

## How it works

1. **Scheduler** polls Jira for tickets assigned to you in open sprints
2. Each ticket goes through a readiness gate (are acceptance criteria clear enough?)
3. Ready tickets are decomposed into ordered subtasks via Claude
4. A git worktree is created per ticket on a feature branch off `develop`
5. **Ralph** picks up subtasks one at a time and invokes Claude Opus to implement them
6. After each iteration, tests run — if passing and Claude reports done, the subtask is committed
7. When all subtasks for a ticket are done, spec and quality reviews run
8. Failed reviews generate follow-up subtasks; passing reviews mark the ticket done
9. A lifetime iteration cap prevents runaway loops — breaching it marks the ticket `needs_intervention`

## Configuration

Tunable constants in `config.nu`:

| Constant | Default | Description |
|---|---|---|
| `POLL_INTERVAL` | `5min` | How often the scheduler polls Jira |
| `NOT_READY_COOLDOWN` | `5min` | Re-check interval for not-ready tickets |
| `MAX_ITERATIONS_PER_PASS` | `20` | Max Claude invocations per subtask per pass |
| `LIFETIME_CAP` | `160` | Max total iterations per ticket before intervention |
