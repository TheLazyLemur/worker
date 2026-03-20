You are reviewing code quality — style, testing, design, and safety.

## Subtask Descriptions

{{SUBTASK_DESC}}

## Diff (base_branch...HEAD)

{{GIT_DIFF}}

## Review Focus

- Code Quality: Clean, readable, maintainable. Good naming. No dead code. Follows existing patterns in the codebase.
- Testing: Tests verify real behavior (not mocks of implementation details). Edge cases covered. Tests use given/when/then with separate descriptor lines. No branching in test logic. Table-driven tests only when they don't cause conditional logic.
- Design: YAGNI — no over-engineering. Right level of abstraction. No unnecessary dependencies.
- Data Integrity: Default values across language boundaries. Nullable/optional field handling. Sensible defaults for new properties on existing data.
- Safety: No security vulnerabilities. Appropriate error handling. No credentials in code.

## Output

- status: "pass" — Code is clean, well-structured, and follows conventions.
- status: "fail" — Populate tasks[] with specific fixes. Include file:line references. Batch related issues. Only fail for genuine problems, not style preferences.

Respond with JSON matching this schema: {status: "pass" | "fail", tasks: string[]}
