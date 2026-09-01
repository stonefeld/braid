#!/usr/bin/env bash
# Launcher — no environment at all.
#
# The floor, and an honest one: it always works, and .braid/session.log is a real place
# to look. It is also what braid degrades to when an ADE fails and stopping the wave
# would be worse than losing a panel — the control plane does not notice the
# difference, because braid status reads the filesystem either way.

launcher_available() { return 0; }

# No terminal, so the agent has to be started in whatever headless form it has. An
# interactive TUI with no tty either refuses or hangs, and a hung worker producing no
# output is the worst state to debug.
launcher_headless() { return 0; }

launcher_launch() {
    # shellcheck disable=SC2034  # the launcher signature is fixed; there is no tab to title
    local worktree="${1:?worktree}" title="${2:-}" command="${3:?command}"
    (nohup bash -lc "$command" >"$worktree/.braid/session.log" 2>&1 &)
}
