#!/usr/bin/env nu

source config.nu

const SCRIPT_DIR = (path self | path dirname)
const DB = ($SCRIPT_DIR | path join "worker.db")
const PROMPTS = ($SCRIPT_DIR | path join "prompts")
const REPO_ROOT = ($SCRIPT_DIR | path join "..")

def db-query [sql: string] { open $DB | query db $sql }
def now-iso [] { date now | format date "%Y-%m-%dT%H:%M:%S" }
def escape-sql [s: string] { $s | str replace --all "'" "''" }

def init-db [] {
    let init_sql = ($SCRIPT_DIR | path join "init.sql")
    ^sqlite3 $DB $".read ($init_sql)"
    db-query "PRAGMA journal_mode=WAL"
    db-query "PRAGMA busy_timeout=5000"
}

def pick-subtask [] {
    let rows = (db-query "
        SELECT s.id, s.ticket_id, s.description, s.sort_order, s.spec_model, s.quality_model,
               t.worktree_path, t.base_branch, t.total_iterations
        FROM subtasks s
        JOIN tickets t ON t.jira_key = s.ticket_id
        WHERE s.status IN ('pending', 'in_progress')
          AND t.status NOT IN ('needs_intervention', 'done')
        ORDER BY s.sort_order ASC, s.id ASC
        LIMIT 1
    ")
    if ($rows | is-empty) { null } else { $rows | get 0 }
}

def mark-subtask [id: int, status: string] {
    let ts = (now-iso)
    db-query $"UPDATE subtasks SET status = '(escape-sql $status)', updated_at = '($ts)' WHERE id = ($id)"
}

def mark-ticket [key: string, status: string] {
    let ts = (now-iso)
    db-query $"UPDATE tickets SET status = '(escape-sql $status)', updated_at = '($ts)' WHERE jira_key = '(escape-sql $key)'"
}

def increment-iterations [key: string] {
    let ts = (now-iso)
    db-query $"UPDATE tickets SET total_iterations = total_iterations + 1, updated_at = '($ts)' WHERE jira_key = '(escape-sql $key)'"
}

def get-ticket-iterations [key: string] {
    let rows = (db-query $"SELECT total_iterations FROM tickets WHERE jira_key = '(escape-sql $key)'")
    $rows | get 0.total_iterations
}

def load-context [subtask_id: int] {
    let path = $"/tmp/ralph-($subtask_id)-context.json"
    if ($path | path exists) {
        open $path
    } else {
        { actions: [], last_messages: [] }
    }
}

def save-context [subtask_id: int, context: record] {
    $context | save -f $"/tmp/ralph-($subtask_id)-context.json"
}

def extract-action-log [events: list] {
    $events
    | where type == "tool_use"
    | each { |e|
        let summary = if ($e | get -o input | is-not-empty) {
            let input = $e.input
            let file = ($input | get -o file_path | default ($input | get -o path | default ""))
            let cmd = ($input | get -o command | default "")
            [$file $cmd] | where { |s| $s != "" } | str join " "
        } else {
            ""
        }
        { tool: ($e | get -o name | default "unknown"), summary: $summary }
    }
}

def extract-last-messages [events: list, count: int] {
    $events
    | where type == "text"
    | last $count
    | each { |e| $e | get -o text | default "" }
}

def load-rules [worktree_path: string] {
    let claude_md = ($worktree_path | path join "CLAUDE.md")
    let repo_rules_dir = ($worktree_path | path join ".claude" "rules")
    let user_rules_dir = ($env.HOME | path join ".claude" "rules")
    mut rules = ""
    if ($claude_md | path exists) {
        $rules = $rules + (open $claude_md) + "\n\n"
    }
    for dir in [$repo_rules_dir $user_rules_dir] {
        if ($dir | path exists) {
            let rule_files = (glob $"($dir)/*.md")
            for f in $rule_files {
                $rules = $rules + (open $f) + "\n\n"
            }
        }
    }
    $rules | str trim
}

def smart-commit [worktree_path: string, description: string] {
    let git_status = (do { cd $worktree_path; ^git status --short } | complete).stdout | str trim
    if ($git_status | is-empty) {
        print "[ralph] nothing to commit"
        return
    }

    let schema = '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"}},"message":{"type":"string"}},"required":["files","message"]}'
    let prompt_template = (open ([$PROMPTS "commit.md"] | path join))
    let prompt = ($prompt_template | str replace "{{SUBTASK_DESC}}" $description | str replace "{{GIT_STATUS}}" $git_status)

    let result = (^claude --print --output-format json --json-schema $schema --model claude-haiku-4-5-20251001 --no-session-persistence $prompt
    | from json
    | where type == "result"
    | get 0.structured_output)

    if ($result.files | is-empty) {
        print "[ralph] no files selected for commit"
        return
    }

    for file in $result.files {
        do { cd $worktree_path; ^git add $file } | complete
    }
    do { cd $worktree_path; ^git commit -m $result.message --no-verify } | complete
    print $"[ralph] committed: ($result.message)"
}

def build-implementer-prompt [description: string, context: record, tests_status: string, tests_output: string, rules: string] {
    let actions_json = ($context.actions | to json)
    let last_msgs = ($context.last_messages | to json)

    $"# Project Rules

($rules)

# Task

Subtask: ($description)

Previous iteration context:
Actions taken: ($actions_json)
Last messages: ($last_msgs)
Test status: ($tests_status)
($tests_output)

Continue implementing. When complete, set done=true.

IMPORTANT: Before setting done=true you MUST run the relevant test suite yourself and verify all tests pass. Do NOT set done=true if any tests are failing — fix them first.
- Changed .cs files → run `make test-dotnet`
- Changed solver .py files → run `make test-solver-local`
- Changed client .ts/.tsx files → run `make test-client`"
}

def work-subtask [subtask: record] {
    let schema = '{"type":"object","properties":{"done":{"type":"boolean"},"reason":{"type":"string"}},"required":["done","reason"]}'
    let rules = (load-rules $subtask.worktree_path)
    mut iter = 0
    mut tests_status = "unknown"
    mut tests_output = ""

    while $iter < $MAX_ITERATIONS_PER_PASS {
        # check lifetime cap
        let total = (get-ticket-iterations $subtask.ticket_id)
        if $total >= $LIFETIME_CAP {
            print $"[ralph] lifetime cap reached for ($subtask.ticket_id)"
            mark-subtask $subtask.id "failed"
            mark-ticket $subtask.ticket_id "needs_intervention"
            return
        }

        let context = (load-context $subtask.id)
        let prompt = (build-implementer-prompt $subtask.description $context $tests_status $tests_output $rules)

        print $"[ralph] subtask ($subtask.id) iter ($iter) — invoking claude"

        let raw_output = (do { cd $subtask.worktree_path; ^claude --print --output-format stream-json --json-schema $schema --permission-mode bypassPermissions --model claude-opus-4-6 --no-session-persistence $prompt })

        # increment ticket iterations
        increment-iterations $subtask.ticket_id

        # save raw stream
        $raw_output | save -f $"/tmp/ralph-($subtask.id)-iter-($iter).jsonl"

        # parse events (stream-json = JSONL, one JSON object per line)
        let events = ($raw_output | lines | each { from json })

        # extract action log and last messages
        let new_actions = (extract-action-log $events)
        let last_msgs = (extract-last-messages $events 3)

        # merge context (cap actions to last 50)
        let all_actions = ($context.actions | append $new_actions)
        let capped_actions = if ($all_actions | length) > 50 { $all_actions | last 50 } else { $all_actions }
        let updated_context = {
            actions: $capped_actions,
            last_messages: $last_msgs
        }
        save-context $subtask.id $updated_context

        # extract structured output
        let result_events = ($events | where type == "result")
        let structured = if ($result_events | is-empty) {
            { done: false, reason: "no result event" }
        } else {
            $result_events | get 0.structured_output
        }

        print $"[ralph] subtask ($subtask.id) iter ($iter) — done=($structured.done) reason=($structured.reason)"

        # run tests
        let test_result = (do { cd $subtask.worktree_path; make test-dotnet; make test-solver CONTAINER_ENGINE=podman } | complete)
        let tests_pass = ($test_result.exit_code == 0)
        $tests_status = (if $tests_pass { "pass" } else { "fail" })
        $tests_output = (if $tests_pass { "" } else {
            let combined = $"($test_result.stdout)\n($test_result.stderr)"
            let lines = ($combined | lines)
            let count = ($lines | length)
            let truncated = if $count > 80 { $lines | last 80 | str join "\n" } else { $combined }
            let fence = "```"
            $"\nTest output \(last 80 lines\):\n($fence)\n($truncated)\n($fence)"
        })

        print $"[ralph] subtask ($subtask.id) iter ($iter) — tests ($tests_status)"

        if $structured.done and $tests_pass {
            break
        }

        $iter = $iter + 1
    }

    if $iter >= $MAX_ITERATIONS_PER_PASS {
        print $"[ralph] subtask ($subtask.id) exhausted iterations, leaving in_progress"
        return
    }

    mark-subtask $subtask.id "done"
    print $"[ralph] subtask ($subtask.id) done"

    # commit changes
    smart-commit $subtask.worktree_path $subtask.description

    # check if all subtasks for this ticket are done
    let remaining = (db-query $"SELECT id FROM subtasks WHERE ticket_id = '(escape-sql $subtask.ticket_id)' AND status IN \('pending', 'in_progress'\)")
    if ($remaining | is-empty) {
        print $"[ralph] all subtasks done for ($subtask.ticket_id) — running reviews"
        run-ticket-reviews $subtask.ticket_id
    }
}

def run-review [kind: string, model: string, diff: string, subtask_descs: string, worktree_path: string] {
    let schema = '{"type":"object","properties":{"status":{"type":"string","enum":["pass","fail"]},"tasks":{"type":"array","items":{"type":"string"}}},"required":["status","tasks"]}'
    let rules = (load-rules $worktree_path)
    let prompt_template = (open ([$PROMPTS $"($kind)-review.md"] | path join))
    let prompt = $"# Project Rules\n\n($rules)\n\n# Review\n\n" + ($prompt_template | str replace "{{SUBTASK_DESC}}" $subtask_descs | str replace "{{GIT_DIFF}}" $diff)

    ^claude --print --output-format json --json-schema $schema --permission-mode bypassPermissions --model $model --no-session-persistence $prompt
    | from json
    | where type == "result"
    | get 0.structured_output
}

def insert-followup-subtasks [ticket_id: string, tasks: list] {
    # find the max sort_order of done subtasks for this ticket
    let done_rows = (db-query $"SELECT MAX\(sort_order\) as max_order FROM subtasks WHERE ticket_id = '(escape-sql $ticket_id)' AND status = 'done'")
    let insert_after = if ($done_rows | is-empty) or ($done_rows.0.max_order == null) { 0 } else { $done_rows.0.max_order }

    # shift sort_order of all pending subtasks that come after
    let shift_amount = ($tasks | length)
    db-query $"UPDATE subtasks SET sort_order = sort_order + ($shift_amount) WHERE ticket_id = '(escape-sql $ticket_id)' AND status = 'pending' AND sort_order > ($insert_after)"

    # get spec_model / quality_model from last done subtask
    let model_rows = (db-query $"SELECT spec_model, quality_model FROM subtasks WHERE ticket_id = '(escape-sql $ticket_id)' AND status = 'done' ORDER BY sort_order DESC LIMIT 1")
    let spec_model = if ($model_rows | is-empty) { "claude-sonnet-4-6" } else { $model_rows.0.spec_model }
    let quality_model = if ($model_rows | is-empty) { "claude-sonnet-4-6" } else { $model_rows.0.quality_model }

    # insert new subtasks
    for idx in 0..<($tasks | length) {
        let desc = ($tasks | get $idx)
        let order = $insert_after + $idx + 1
        let esc_key = (escape-sql $ticket_id)
        let esc_desc = (escape-sql $desc)
        let esc_spec = (escape-sql $spec_model)
        let esc_quality = (escape-sql $quality_model)
        db-query $"INSERT INTO subtasks \(ticket_id, description, sort_order, spec_model, quality_model\) VALUES \('($esc_key)', '($esc_desc)', ($order), '($esc_spec)', '($esc_quality)'\)"
    }

    let count = ($tasks | length)
    print $"[ralph] inserted ($count) followup subtasks for ($ticket_id)"
}

def run-ticket-reviews [ticket_id: string] {
    # get ticket info
    let ticket = (db-query $"SELECT worktree_path, base_branch FROM tickets WHERE jira_key = '(escape-sql $ticket_id)'" | get 0)

    # commit any remaining uncommitted changes before review
    let stash_status = (do { cd $ticket.worktree_path; ^git status --short } | complete).stdout | str trim
    if ($stash_status | is-not-empty) {
        do { cd $ticket.worktree_path; ^git add -A; ^git commit -m "chore: stage remaining changes for review" --no-verify } | complete
    }
    let diff = (do { cd $ticket.worktree_path; ^git diff $"($ticket.base_branch)...HEAD" } | complete).stdout

    # get all subtask descriptions
    let subtasks = (db-query $"SELECT description FROM subtasks WHERE ticket_id = '(escape-sql $ticket_id)' ORDER BY sort_order ASC")
    let subtask_descs = ($subtasks | get description | str join "\n- " | $"- ($in)")

    # get models from last done subtask
    let model_rows = (db-query $"SELECT spec_model, quality_model FROM subtasks WHERE ticket_id = '(escape-sql $ticket_id)' AND status = 'done' ORDER BY sort_order DESC LIMIT 1")
    let spec_model = if ($model_rows | is-empty) { "claude-sonnet-4-6" } else { $model_rows.0.spec_model }
    let quality_model = if ($model_rows | is-empty) { "claude-sonnet-4-6" } else { $model_rows.0.quality_model }

    # spec review
    print $"[ralph] running spec review for ($ticket_id)"
    let spec_result = (run-review "spec" $spec_model $diff $subtask_descs $ticket.worktree_path)

    if $spec_result.status == "fail" {
        print $"[ralph] spec review failed for ($ticket_id) — inserting followup subtasks"
        insert-followup-subtasks $ticket_id $spec_result.tasks
        return
    }

    # quality review
    print $"[ralph] running quality review for ($ticket_id)"
    let quality_result = (run-review "quality" $quality_model $diff $subtask_descs $ticket.worktree_path)

    if $quality_result.status == "fail" {
        print $"[ralph] quality review failed for ($ticket_id) — inserting followup subtasks"
        insert-followup-subtasks $ticket_id $quality_result.tasks
        return
    }

    # both passed
    mark-ticket $ticket_id "done"
    print $"[ralph] ticket ($ticket_id) done"
}

# --- main loop ---

def main [] {
    print "[ralph] starting"
    init-db

    loop {
        let subtask = (pick-subtask)

        if ($subtask == null) {
            print $"[ralph] no subtasks, sleeping 30s"
            sleep 30sec
            continue
        }

        # check lifetime cap before starting
        if $subtask.total_iterations >= $LIFETIME_CAP {
            print $"[ralph] lifetime cap reached for ($subtask.ticket_id), marking failed"
            mark-subtask $subtask.id "failed"
            mark-ticket $subtask.ticket_id "needs_intervention"
            continue
        }

        print $"[ralph] picking up subtask ($subtask.id) for ($subtask.ticket_id): ($subtask.description | str substring 0..80)"

        mark-subtask $subtask.id "in_progress"

        try {
            work-subtask $subtask
        } catch { |e|
            print $"[ralph] error on subtask ($subtask.id): ($e.msg)"
            # leave as in_progress — picked up next pass
        }
    }
}
