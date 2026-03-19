# Worker System

Automated implementation pipeline: tickets go in, reviewed code comes out.

## How it works

1. **Scheduler** (`scheduler.nu`) polls Jira every 5 min (if configured), upserts tickets to `worker.db`
2. Each ticket gets a **readiness check** (Haiku) — does it have clear, testable acceptance criteria?
3. Ready tickets get a **git worktree** and are **decomposed** into ordered subtasks (Opus explores the codebase first)
4. **Ralph** (`ralph.nu`) picks up subtasks one at a time, runs Claude Opus with full tool access in the worktree
5. After each iteration Ralph runs the test suite — if tests fail, the output is fed back and the agent tries again (up to 20 iterations per pass, 160 lifetime cap per ticket)
6. When all subtasks are done, Ralph runs **spec review** then **quality review** — if either fails, followup subtasks are inserted and implementation continues
7. Both reviews pass → ticket marked done

## Adding manual tickets

Manual tickets bypass Jira entirely. Insert directly into the DB:

```bash
sqlite3 worker.db "INSERT INTO tickets (jira_key, summary, description, manual) VALUES ('MANUAL-001', 'Short summary here', 'Full description with acceptance criteria here', 1)"
```

- `jira_key` — must be unique. Use a `MANUAL-XXX` convention so they don't collide with real Jira keys
- `summary` — short title, used for the git branch name
- `description` — this is the spec. Same rules as a Jira ticket: clear acceptance criteria, testable statements, bounded scope
- `manual=1` — tells the scheduler to use the DB description instead of fetching from Jira

The ticket enters the pipeline as `pending` and goes through the same readiness → decompose → implement → review flow as any Jira ticket.

## Running without Jira

Jira integration is optional. If `JIRA_PROJECT` and `JIRA_ASSIGNEE` are not set, the scheduler skips Jira polling and only processes tickets already in the DB (i.e. manual tickets). Only `GIT_BASE_BRANCH` is required.

## Writing good ticket descriptions

The description is the **only spec** the system gets. Nobody is going to clarify anything. Write it like you're handing it to a contractor you can't talk to.

Must include:
- Acceptance criteria as checkboxes or numbered requirements
- Each criterion specific enough to assert in a test
- Clear scope — what's in, what's out

Will be rejected by readiness check:
- Vague goals ("improve performance", "make it better")
- Open decisions ("TBD", "discuss with team")
- No acceptance criteria at all

## Task sizing

The decomposer splits tickets into subtasks. Each subtask must compile, have tests, and be committable on its own. This means your ticket needs to be big enough to be meaningful but bounded enough to be unambiguous.

**Too small** — "rename field X to Y", "add a null check here". These are single-line changes that don't justify the overhead of the pipeline (readiness check, decomposition, worktree, reviews). Just do them by hand.

**Right size** — "add endpoint X that does Y with these acceptance criteria", "refactor service Z to use pattern W, covering these cases". Something that takes 1-8 subtasks to implement.

**Too big** — "rewrite the auth system". If you can't write exhaustive acceptance criteria in a single ticket description, it's too big. Split it into multiple tickets yourself.

## Dashboard

```bash
cd dashboard && bun run server.ts
```

Runs on `:3737`. Shows ticket statuses, subtask progress, and inline descriptions. Auto-refreshes every 10s.

## Statuses

**Tickets:** `pending` → `not_ready` (failed readiness, retried after cooldown) or `decomposed` (subtasks created) → `done` or `needs_intervention` (lifetime cap hit or empty decomposition)

**Subtasks:** `pending` → `in_progress` → `done` or `failed`
