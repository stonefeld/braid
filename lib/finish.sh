#!/usr/bin/env bash
# Write .braid/status for a worker whose agent has just exited.
#
#   finish.sh [worktree]
#
# Copied into every worker's .braid/ and appended to its launch command, so it runs
# whatever happened: a clean exit, a crash, an agent that was never installed. This is
# what makes the control plane independent of the agent having hooks — and it is the
# difference between the orchestrator learning about a worker that died at launch now,
# and learning about it after twenty minutes of silence.
#
# Safe to run twice. The state is recomputed from git, so an agent whose own stop hook
# already wrote this file simply has it confirmed.

set -uo pipefail

WORKTREE="${1:-$(pwd)}"
cd "$WORKTREE" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

mkdir -p "$WORKTREE/.braid"

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
head=$(git rev-parse --short HEAD 2>/dev/null || echo "")

# Ordered by what the orchestrator must not miss. A dirty tree outranks a report,
# because a rebase would lose the uncommitted work and the report would still read as
# though everything had landed.
# .braid/ is excluded explicitly rather than trusted to .gitignore. It is braid's own
# scratch space — the report, the session log, this very status file — and a worker that
# marked itself dirty by writing its report would be held back from a rebase it was
# ready for, in a repository where setup had simply not run yet.
if [[ -n "$(git status --porcelain -- ':!.braid' 2>/dev/null)" ]]; then
    state="dirty"
elif [[ -f "$WORKTREE/.braid/report.md" ]]; then
    state="done"
else
    state="done-no-report"
fi

printf 'state=%s\nbranch=%s\nhead=%s\nat=%s\n' \
    "$state" "$branch" "$head" "$(date +%s)" >"$WORKTREE/.braid/status"
