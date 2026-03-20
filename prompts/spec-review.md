You are reviewing a diff to verify the implementation matches the subtask specifications.

## Subtask Descriptions

{{SUBTASK_DESC}}

## Diff (base_branch...HEAD)

{{GIT_DIFF}}

## Review Focus

- Missing requirements — Check every requirement in every subtask description is implemented and tested
- Extra/unneeded work — Was code added beyond what the spec asked for?
- Misunderstandings — Were requirements interpreted correctly?
- Test coverage — Does every subtask have tests? Do tests verify the specified behavior?
- Data integrity — Default values across language boundaries? Nullable field handling? Cross-layer consistency?

## Output

- status: "pass" — The diff fully satisfies all subtask descriptions. Nothing is missing or extra.
- status: "fail" — Populate tasks[] with specific fix instructions. Include file:line references where possible. Each task becomes a subtask the agent implements. Batch related issues into single tasks.

Respond with JSON matching this schema: {status: "pass" | "fail", tasks: string[]}
