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

def fetch-jira-tickets [] {
    let jql = "project = " + $env.JIRA_PROJECT + ' AND sprint in openSprints() AND assignee = "' + $env.JIRA_ASSIGNEE + '" AND status != Done'
    ^jira issue list --plain --no-headers --columns KEY,SUMMARY --delimiter "|" -q $jql
    | lines
    | each { |l| $l | split column "|" key summary | get 0 }
}

def fetch-ticket-description [key: string] {
    ^jira issue view $key --plain
}

def upsert-tickets [tickets: list] {
    for ticket in $tickets {
        let existing = (db-query $"SELECT jira_key FROM tickets WHERE jira_key = '(escape-sql $ticket.key)'")
        if ($existing | is-empty) {
            let description = (fetch-ticket-description $ticket.key)
            let esc_key = (escape-sql $ticket.key)
            let esc_summary = (escape-sql $ticket.summary)
            let esc_desc = (escape-sql $description)
            let desc_hash = ($description | hash md5)
            db-query $"INSERT INTO tickets \(jira_key, summary, description, description_hash\) VALUES \('($esc_key)', '($esc_summary)', '($esc_desc)', '($desc_hash)'\)"
            print $"[scheduler] inserted ticket ($ticket.key)"
        }
    }
}

def get-pending-tickets [] {
    db-query "SELECT jira_key, summary, description, status, manual FROM tickets WHERE status = 'pending'"
}

def get-stale-not-ready-tickets [] {
    let cutoff = ((date now) - $NOT_READY_COOLDOWN | format date "%Y-%m-%dT%H:%M:%S")
    db-query $"SELECT jira_key, summary, description, status, manual FROM tickets WHERE status = 'not_ready' AND updated_at < '($cutoff)'"
}

def readiness-check [description: string]: nothing -> record {
    let schema = '{"type":"object","properties":{"ready":{"type":"boolean"},"reason":{"type":"string"}},"required":["ready","reason"]}'
    let prompt_template = (open ([$PROMPTS "readiness.md"] | path join))
    let prompt = ($prompt_template | str replace "{{TICKET_CONTENT}}" $description)

    ^claude --print --output-format json --json-schema $schema --model claude-haiku-4-5-20251001 --no-session-persistence $prompt
    | from json
    | where type == "result"
    | get 0.structured_output
}

def create-worktree [key: string, summary: string]: nothing -> record {
    let base_branch = $env.GIT_BASE_BRANCH
    let slug = ($summary | str downcase | str replace --all --regex '[^a-z0-9]+' '-' | str substring 0..40)
    let branch = $"feature/($key | str downcase)-($slug)"
    let worktree_path = ($REPO_ROOT | path join ".claude" "worktrees" $"($key)-($slug)")

    ^git -C $REPO_ROOT fetch origin $base_branch
    ^git -C $REPO_ROOT worktree add $worktree_path -b $branch $"origin/($base_branch)"
    print $"[scheduler] created worktree ($worktree_path) on branch ($branch)"

    { worktree_path: $worktree_path, base_branch: $base_branch }
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

def decompose-ticket [description: string, worktree_path: string]: nothing -> list {
    let schema = '{"type":"object","properties":{"subtasks":{"type":"array","items":{"type":"object","properties":{"description":{"type":"string"},"sort_order":{"type":"integer"},"spec_model":{"type":"string"},"quality_model":{"type":"string"}},"required":["description","sort_order","spec_model","quality_model"]}}},"required":["subtasks"]}'
    let rules = (load-rules $worktree_path)
    let prompt_template = (open ([$PROMPTS "decompose.md"] | path join))
    let prompt = $"# Project Rules\n\n($rules)\n\n# Task\n\n" + ($prompt_template | str replace "{{TICKET_CONTENT}}" $description)

    let result = do { cd $worktree_path; ^claude --print --output-format json --json-schema $schema --model claude-opus-4-6 --allowed-tools "Read Glob Grep" --no-session-persistence $prompt }
    | from json
    | where type == "result"
    | get 0.structured_output

    $result.subtasks
}

def insert-subtasks [ticket_key: string, subtasks: list] {
    let esc_key = (escape-sql $ticket_key)
    for subtask in $subtasks {
        let esc_desc = (escape-sql $subtask.description)
        let esc_spec = (escape-sql $subtask.spec_model)
        let esc_quality = (escape-sql $subtask.quality_model)
        db-query $"INSERT INTO subtasks \(ticket_id, description, sort_order, spec_model, quality_model\) VALUES \('($esc_key)', '($esc_desc)', ($subtask.sort_order), '($esc_spec)', '($esc_quality)'\)"
    }
    print $"[scheduler] inserted ($subtasks | length) subtasks for ($ticket_key)"
}

def mark-decomposed [key: string, worktree_path: string, base_branch: string] {
    let ts = (now-iso)
    let esc_wt = (escape-sql $worktree_path)
    let esc_bb = (escape-sql $base_branch)
    db-query $"UPDATE tickets SET status = 'decomposed', worktree_path = '($esc_wt)', base_branch = '($esc_bb)', updated_at = '($ts)' WHERE jira_key = '(escape-sql $key)'"
}

def mark-not-ready [key: string, reason: string] {
    let ts = (now-iso)
    db-query $"UPDATE tickets SET status = 'not_ready', updated_at = '($ts)' WHERE jira_key = '(escape-sql $key)'"
    print $"[scheduler] ($key) not ready: ($reason)"
}

def process-candidate [ticket: record] {
    print $"[scheduler] checking readiness: ($ticket.jira_key)"

    let description = if ($ticket.manual == 1) {
        # manual tickets already have their description in the DB
        $ticket.description
    } else {
        # re-fetch description from Jira in case it was updated since last check
        fetch-ticket-description $ticket.jira_key
    }
    let new_hash = ($description | hash md5)

    # skip readiness check if description unchanged since last not_ready verdict
    let stored = (db-query $"SELECT description_hash FROM tickets WHERE jira_key = '(escape-sql $ticket.jira_key)'" | get -o 0)
    if $ticket.status == "not_ready" and ($stored | is-not-empty) and ($stored.description_hash? == $new_hash) {
        print $"[scheduler] ($ticket.jira_key) description unchanged, skipping"
        return
    }

    let esc_desc = (escape-sql $description)
    db-query $"UPDATE tickets SET description = '($esc_desc)', description_hash = '($new_hash)', updated_at = '(now-iso)' WHERE jira_key = '(escape-sql $ticket.jira_key)'"
    let check = (readiness-check $description)

    if $check.ready {
        print $"[scheduler] ($ticket.jira_key) is ready, creating worktree"
        let wt = (create-worktree $ticket.jira_key $ticket.summary)

        print $"[scheduler] decomposing ($ticket.jira_key)"
        let subtasks = (decompose-ticket $ticket.description $wt.worktree_path)

        if ($subtasks | is-empty) {
            let ts = (now-iso)
            db-query $"UPDATE tickets SET status = 'needs_intervention', updated_at = '($ts)' WHERE jira_key = '(escape-sql $ticket.jira_key)'"
            print $"[scheduler] ($ticket.jira_key) empty decomposition, marked needs_intervention"
            return
        }

        insert-subtasks $ticket.jira_key $subtasks
        mark-decomposed $ticket.jira_key $wt.worktree_path $wt.base_branch
        print $"[scheduler] ($ticket.jira_key) decomposed"
    } else {
        mark-not-ready $ticket.jira_key $check.reason
    }
}

# --- main loop ---

def main [] {
    load-dotenv
    validate-config
    print "[scheduler] starting"
    init-db

    loop {
        print $"[scheduler] polling at (now-iso)"

        # 1. fetch tickets from Jira
        let tickets = (fetch-jira-tickets)
        print $"[scheduler] found ($tickets | length) sprint tickets"

        # 2. upsert into DB
        upsert-tickets $tickets

        # 3. get candidates: pending + stale not_ready
        let pending = (get-pending-tickets)
        let stale = (get-stale-not-ready-tickets)
        let candidates = ($pending | append $stale)

        print $"[scheduler] ($candidates | length) candidates \(($pending | length) pending, ($stale | length) stale not_ready\)"

        # 4. process each candidate
        for candidate in $candidates {
            try {
                process-candidate $candidate
            } catch { |e|
                print $"[scheduler] ERROR processing ($candidate.jira_key): ($e.msg)"
            }
        }

        print $"[scheduler] sleeping ($POLL_INTERVAL)"
        sleep $POLL_INTERVAL
    }
}
