You are assessing whether a ticket is ready for decomposition into implementation subtasks.

## Ticket Description

{{DESCRIPTION}}

## Assessment Criteria

Mark as ready=true if ALL of the following are true:
- Description contains acceptance criteria (checkboxes, numbered requirements, or testable statements)
- Each criterion is specific enough to verify in tests (not vague like "improve performance")
- Scope is bounded with clear in/out boundaries

Mark as ready=false if ANY of the following are true:
- No acceptance criteria at all
- Criteria are ambiguous or unmeasurable
- Critical decisions are left open (TBD, conflicting options listed without resolution)

Respond with JSON matching this schema: {ready: boolean, reason: string}
The reason should be a single sentence explaining your decision.
