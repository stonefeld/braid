#!/usr/bin/env bash
# Open the orchestrator seat on this feature.
#
#   braid orchestrate
#
#     --model NAME   override the tier for this one session
#     --here         take over this terminal instead of opening a window
#
# A fresh context window, on the tier this repository calls `orchestrate`, in the feature
# worktree, already holding the instructions for running a wave.
#
# Fresh matters. The orchestrator's whole job is judging other agents' work against their
# diffs, and a session that just spent an hour designing the feature is the worst possible
# reader of it: it knows what the code was meant to be, which is exactly the thing it is
# supposed to be checking.

set -uo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"
# shellcheck source=launcher.sh
source "$BRAID_HOME/lib/launcher.sh"

MODEL=""
HERE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        --here)
            HERE=1
            shift
            ;;
        -h | --help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

braid_config
refuse_worker_seat
is_protected_branch "$(current_branch)" &&
    die "orchestration runs on a feature branch, not on '$(current_branch)'"

agent_load orchestrate || exit 1
MODEL="${MODEL:-$(agent_model orchestrate)}"
agent_check_model "$MODEL"

WORKTREE=$(current_worktree)
PROMPT=$(agent_skill_prompt braid-orchestrate)

if [[ "$HERE" -eq 1 ]]; then
    note "$BRAID_AGENT_RESOLVED${MODEL:+ ($MODEL)} — orchestrating $(current_branch) here"
    BRAID_SEAT=orchestrate eval "$(agent_cmd "$WORKTREE" "$MODEL" "$PROMPT")"
    exit 0
fi

# Its own window, for the same reason a worker gets one: you want to watch it, and you
# want your own terminal back. --here is for when you would rather not.
read -r LAUNCHER CERTAINTY < <(launcher_resolve)
launcher_load "$LAUNCHER"
note "$BRAID_AGENT_RESOLVED${MODEL:+ ($MODEL)} — orchestrating $(current_branch) in $LAUNCHER ($CERTAINTY)"

COMMAND="cd $(printf '%q' "$WORKTREE") && BRAID_SEAT=orchestrate $(agent_cmd "$WORKTREE" "$MODEL" "$PROMPT")"
if ! launcher_launch "$WORKTREE" "braid-$(branch_slug "$(current_branch)")" "$COMMAND"; then
    warn "$(printf '%s\n' \
        "could not open a window in $LAUNCHER." \
        "  last call: ${BRAID_LAUNCHER_PROBE:-unknown}" \
        "  run it here instead:  braid orchestrate --here")"
    exit 4
fi
note "watch it there, and this terminal with: braid status"
