#!/usr/bin/env bash
# Launcher — herdr.
#
# herdr is young and its CLI contract will move. That is expected rather than a problem:
# capability is probed here, never version-checked, and a user whose herdr has moved
# ahead of braid drops a replacement in ~/.config/braid/launchers/herdr.sh and is
# running the same afternoon.

launcher_available() {
    command -v herdr >/dev/null 2>&1 || return 1
    # The probe is the call braid actually depends on, not `herdr --version`. A version
    # number cannot tell you the shape of this response changed.
    herdr pane list 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(panes, list) else 1)
' 2>/dev/null
}

launcher_launch() {
    local worktree="${1:?worktree}" title="${2:?title}" command="${3:?command}" pane

    launcher_probe "herdr workspace create --cwd $worktree --label $title"
    herdr workspace create --cwd "$worktree" --label "$title" --no-focus >/dev/null || return 1

    launcher_probe "herdr pane list"
    pane=$(herdr pane list | python3 -c '
import json, sys
target = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    sys.exit(1)
match = [p for p in panes if p.get("cwd") == target and not p.get("agent")]
print(match[0]["pane_id"] if match else "")
' "$worktree") || return 1
    [[ -n "$pane" ]] || return 1

    launcher_probe "herdr pane run $pane"
    herdr pane run "$pane" "$command" >/dev/null || return 1
    note "herdr pane $pane"
}
