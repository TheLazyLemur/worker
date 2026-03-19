const CONFIG_DIR = (path self | path dirname)

def --env load-dotenv [] {
    let env_file = ($CONFIG_DIR | path join ".env")
    if not ($env_file | path exists) { return }
    let vars = (open $env_file
        | lines
        | where { |l| let t = ($l | str trim); $t != "" and not ($t | str starts-with "#") }
        | each { |l|
            let idx = ($l | str index-of "=")
            if $idx >= 0 {
                { ($l | str substring ..<($idx) | str trim): ($l | str substring ($idx + 1).. | str trim) }
            }
        }
        | compact
        | reduce { |it, acc| $acc | merge $it })
    load-env $vars
}

def validate-config [] {
    mut missing = []
    if ($env | get -o GIT_BASE_BRANCH | default "" | is-empty) { $missing = ($missing | append "GIT_BASE_BRANCH") }
    if ($missing | is-not-empty) {
        error make { msg: $"missing required env vars: ($missing | str join ', '). Set them in .env or export them." }
    }
}

def jira-configured [] {
    let project = ($env | get -o JIRA_PROJECT | default "")
    let assignee = ($env | get -o JIRA_ASSIGNEE | default "")
    ($project | is-not-empty) and ($assignee | is-not-empty)
}

# Polling
const POLL_INTERVAL = 5min
const NOT_READY_COOLDOWN = 5min

# Ralph loop
const MAX_ITERATIONS_PER_PASS = 20
const LIFETIME_CAP = 160

# Test command — run from the worktree root after each iteration
# Override via TEST_COMMAND env var
def test-command [] {
    $env | get -o TEST_COMMAND | default "make test"
}
