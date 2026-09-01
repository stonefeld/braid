#!/usr/bin/env bash
# Run the project's mechanical gate.
#
#   braid verify              the worktree you are standing in
#   braid verify <slug>       one worker
#   braid verify --all        every worker off this branch
#
# This is only the half of the gate a script can judge. The other half is judgement:
# does the diff match the slice, and does the report match the diff. **A green verify is
# not permission to integrate; a red one is a refusal.**

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"

braid_config

# Said out loud rather than passed silently. A repository with no gate is a legitimate
# state — braid has to work in one created twenty minutes ago — but an orchestrator
# that reads "pass" from a check that ran nothing would integrate on it.
if ! braid_overridden braid_verify; then
    warn "no braid_verify in $BRAID_PROJECT_FILE — there is no mechanical gate, only the human one"
    exit 0
fi

verify_one() {
    local worktree="${1:?worktree}" label
    label=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || basename "$worktree")
    note "verifying $label"
    if braid_verify "$worktree"; then
        ok "$label"
        return 0
    fi
    # A red gate means different things on either side of an integration, and saying
    # "do not integrate" about a branch that already is one reads as a bug in braid.
    if is_worker_branch "$label"; then
        bad "$label — do not integrate this branch"
    else
        bad "$label"
    fi
    return 1
}

case "${1:-}" in
    --all)
        status=0
        found=0
        while read -r worktree; do
            [[ -n "$worktree" ]] || continue
            found=1
            verify_one "$worktree" || status=1
        done < <(worker_worktrees mine)
        [[ "$found" -eq 1 ]] || note "no workers off $(current_branch)"
        exit "$status"
        ;;
    "") verify_one "$(current_worktree)" ;;
    -h | --help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 0
        ;;
    *)
        slug="${1#"$BRAID_BRANCH_PREFIX"/}"
        worktree=$(worker_worktree_path "$slug")
        [[ -d "$worktree" ]] || die "no worker worktree at $worktree"
        verify_one "$worktree"
        ;;
esac
