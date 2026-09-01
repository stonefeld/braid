#!/usr/bin/env bash
# What every worker is doing.
#
#   braid status [options]
#   braid wait   [options]
#
#     --all         every worker in the repository, not only this branch's
#     --reports     print each finished worker's report
#     --wait        block until this wave settles
#     --timeout N   how long to block before returning 3   (default: 480)
#
# `wait` returns when every worker has reached a terminal state, or exits 3 after the
# timeout, which just means call it again. **Never write a polling loop of your own.** A
# loop that stops only when everything says `done` hangs forever on a worker that died
# at launch — that one is reported `stale`, and a stale worker is something to go and
# read, not something to keep waiting for.

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"

SCOPE=mine
REPORTS=0
WAIT=0
TIMEOUT=480

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            SCOPE=all
            shift
            ;;
        --reports)
            REPORTS=1
            shift
            ;;
        --wait)
            WAIT=1
            shift
            ;;
        --timeout)
            TIMEOUT="${2:?--timeout needs seconds}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

braid_config

# Colour is a courtesy to a person, and noise to the orchestrator that parses this.
state_colour() {
    case "$1" in
        done) printf '%s' "$_C_GREEN" ;;
        dirty | stale) printf '%s' "$_C_YELLOW" ;;
        done-no-report) printf '%s' "$_C_YELLOW" ;;
        *) printf '' ;;
    esac
}

print_table() {
    local worktree branch state ahead idle launcher found=0
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        found=1
        branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
        state=$(worker_state "$worktree")
        ahead=$(worker_commits_ahead "$worktree" 2>/dev/null || echo 0)
        idle=$(worker_idle_seconds "$worktree")

        printf '%s%-15s%s %-40s %s commits' \
            "$(state_colour "$state")" "$state" "$_C_OFF" "$branch" "${ahead:-0}"
        [[ "$state" == working && -n "$idle" ]] && printf ', quiet %ss' "$idle"
        printf '\n'

        # Degraded visibility is a state, not a warning that scrolled past at spawn.
        # The orchestrator sees it on every check and puts it in its wave summary, so
        # the human learns at the next natural checkpoint instead of being interrupted.
        launcher=$(worker_field "$worktree" launcher)
        if [[ "$launcher" == *failed* ]]; then
            printf '  %s⚠ no panel — %s%s\n' "$_C_YELLOW" "$launcher" "$_C_OFF"
            printf '    %s/.braid/session.log · .braid/launch-error.log\n' "$worktree"
        fi

        if [[ "$REPORTS" -eq 1 && -f "$worktree/.braid/report.md" ]]; then
            sed 's/^/    /' "$worktree/.braid/report.md"
            printf '\n'
        fi
    done < <(worker_worktrees "$SCOPE")
    [[ "$found" -eq 1 ]] || printf 'no workers off %s\n' "$(current_branch)"
}

all_settled() {
    local worktree found=0
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        found=1
        worker_is_terminal "$worktree" || return 1
    done < <(worker_worktrees "$SCOPE")
    [[ "$found" -eq 1 ]]
}

if [[ "$WAIT" -eq 0 ]]; then
    print_table
    exit 0
fi

# Polling, but in one place and with a bound. The alternative — every orchestrator
# writing its own loop — is where the "wait for everything to say done" bug lives.
started=$(date +%s)
while true; do
    if all_settled; then
        note "wave settled"
        print_table
        exit 0
    fi
    elapsed=$(($(date +%s) - started))
    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
        print_table
        note "still working after ${elapsed}s — run wait again"
        exit 3
    fi
    progress "waiting… ${elapsed}s"
    sleep 10
done
