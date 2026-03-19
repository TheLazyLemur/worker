CREATE TABLE IF NOT EXISTS tickets (
    jira_key TEXT PRIMARY KEY,
    summary TEXT NOT NULL,
    description TEXT,
    description_hash TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'not_ready', 'decomposed', 'needs_intervention', 'done')),  -- pending | not_ready | decomposed | needs_intervention | done
    worktree_path TEXT,
    base_branch TEXT,
    manual INTEGER NOT NULL DEFAULT 0,
    total_iterations INTEGER NOT NULL DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS subtasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ticket_id TEXT NOT NULL REFERENCES tickets(jira_key),
    description TEXT NOT NULL,
    sort_order INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'failed', 'done')),  -- pending | in_progress | failed | done
    spec_model TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
    quality_model TEXT NOT NULL DEFAULT 'claude-sonnet-4-6',
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);
