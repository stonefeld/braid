#!/usr/bin/env bash
# Launcher — orca.
#
# Beyond starting the terminal, orca is told the worker's lineage so its card hangs off
# the feature's. That part is best-effort by construction: an unparented card is
# cosmetic, and aborting a spawn that already provisioned real resources is not.

# Resolving the CLI is not paranoia. On Linux, outside orca's own terminals, bare `orca`
# is the GNOME screen reader — calling it starts speech on someone's machine. That is
# the kind of mistake a tool gets to make exactly once.
orca_cli() {
    if [[ -n "${ORCA_CLI_COMMAND:-}" ]]; then
        printf '%s' "$ORCA_CLI_COMMAND"
    elif [[ -n "${ORCA_DEV_REPO_ROOT:-}" ]]; then
        printf 'orca-dev'
    elif [[ "$(uname -s)" == Linux && -z "${ORCA_TERMINAL_HANDLE:-}" ]]; then
        command -v orca-ide >/dev/null 2>&1 && printf 'orca-ide'
    else
        command -v orca >/dev/null 2>&1 && printf 'orca'
    fi
}

# Installed is not usable: the app can be closed. Never starts it — spawning a worker
# should not open a desktop application.
launcher_available() {
    local cli
    cli=$(orca_cli) && [[ -n "$cli" ]] || return 1
    "$cli" status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("ok") and d.get("result", {}).get("runtime", {}).get("reachable") else 1)
' 2>/dev/null
}

launcher_launch() {
    local worktree="${1:?worktree}" title="${2:?title}" command="${3:?command}"
    local cli terminal handle="" surface=""

    cli=$(orca_cli) && [[ -n "$cli" ]] || {
        launcher_probe "resolving the orca CLI (set ORCA_CLI_COMMAND)"
        return 1
    }

    # orca picks a worktree up from git without any registration step, but not instantly
    # — its scan lands a few seconds after `worktree add` returns, and until then every
    # selector for it answers selector_not_found. Waited for rather than raced.
    launcher_probe "$cli worktree show --worktree path:$worktree"
    for _ in $(seq 1 30); do
        "$cli" worktree show --worktree "path:$worktree" --json >/dev/null 2>&1 && break
        sleep 1
    done

    if [[ -n "${BRAID_PARENT_WORKTREE:-}" ]]; then
        "$cli" worktree set --worktree "path:$worktree" \
            --parent-worktree "path:$BRAID_PARENT_WORKTREE" \
            --display-name "$title" --workspace-status in-progress --json >/dev/null 2>&1 ||
            note "orca would not chain this card — the worker is fine either way"
    fi

    launcher_probe "$cli terminal create --worktree path:$worktree"
    terminal=$("$cli" terminal create \
        --worktree "path:$worktree" --title "$title" --command "$command" --json) || return 1

    # `terminal create` falls back to a background handle when the UI cannot adopt the
    # tab, and still exits 0. A worker nobody can see is not worth failing the launch
    # over, but it has to be said out loud.
    read -r handle surface < <(printf '%s' "$terminal" | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin).get("result", {}).get("terminal", {})
except Exception:
    t = {}
print(t.get("handle") or "", t.get("surface") or "")
' 2>/dev/null) || true

    if [[ -n "$surface" && "$surface" != visible ]]; then
        warn "orca did not adopt a visible tab (surface: $surface) — read it with: $cli terminal read --terminal $handle"
    fi
    note "orca terminal${handle:+ $handle}"
}

launcher_forget() {
    local worktree="${1:?worktree}" cli
    launcher_available || return 0
    cli=$(orca_cli) && [[ -n "$cli" ]] || return 0
    "$cli" worktree rm --worktree "path:$worktree" --force --json >/dev/null 2>&1 ||
        note "orca kept a record of $worktree — remove the card by hand if it lingers"
    return 0
}
