You are preparing a git commit for a completed subtask implementation.

## Subtask Description

{{SUBTASK_DESC}}

## Current Git Status

{{GIT_STATUS}}

## File Selection Rules

- Include files that are part of the subtask implementation
- Exclude: temp files, logs, lock file churn, IDE configs, build artifacts
- When in doubt, include the file (reviewer catches mistakes)

## Commit Message Format

Use the format: type(scope): description

- Types: feat, fix, test, refactor, chore, docs
- Scope: area of codebase (e.g., solver, client, core, transport)
- Description: what changed and why — no marketing language, no filler
- Keep under 72 characters

Respond with JSON matching this schema: {files: string[], message: string}
