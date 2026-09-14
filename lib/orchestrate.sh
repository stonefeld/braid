#!/usr/bin/env bash
# Open the orchestrator seat on this feature.
#
#   braid orchestrate
#
#     --model NAME    override the tier for this one session
#     --effort LEVEL  override reasoning effort for this one session
#     --agent NAME    which agent takes the seat, for this one session
#     --here          take over this terminal instead of opening a window
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
EFFORT=""
HERE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL=$(flag_value --model "${2-}") || exit 1
            shift 2
            ;;
        --effort)
            EFFORT=$(flag_value --effort "${2-}") || exit 1
            shift 2
            ;;
        --agent)
            # Read back by agent_resolve through indirect expansion of the seat name.
            VALUE=$(flag_value --agent "${2-}") || exit 1
            export BRAID_AGENT_ORCHESTRATE="$VALUE"
            shift 2
            ;;
        --here)
            HERE=1
            shift
            ;;
        -h | --help)
            braid_help "$0"
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
EFFORT="${EFFORT:-$(agent_effort orchestrate)}"
agent_check_effort "$EFFORT"

WORKTREE=$(current_worktree)
# Before the agent starts, because the first thing it is told is to write its long
# command output there.
ensure_seat_dir "$WORKTREE"
PROMPT=$(agent_skill_prompt braid-orchestrate)

if [[ "$HERE" -eq 1 ]]; then
    note "$BRAID_RUN_AGENT${MODEL:+ ($MODEL)}${EFFORT:+, effort $EFFORT} — orchestrating $(current_branch) here"
    BRAID_RUN_SEAT=orchestrate eval "$(agent_cmd "$WORKTREE" "$MODEL" "$PROMPT" "$EFFORT")"
    exit 0
fi

# Its own window, for the same reason a worker gets one: you want to watch it, and you
# want your own terminal back. --here is for when you would rather not.
read -r LAUNCHER CERTAINTY < <(launcher_resolve)
launcher_load "$LAUNCHER"
note "$BRAID_RUN_AGENT${MODEL:+ ($MODEL)}${EFFORT:+, effort $EFFORT} — orchestrating $(current_branch) in $LAUNCHER ($CERTAINTY)"

COMMAND="cd $(printf '%q' "$WORKTREE") && BRAID_RUN_SEAT=orchestrate $(agent_cmd "$WORKTREE" "$MODEL" "$PROMPT" "$EFFORT")"
if ! launcher_launch "$WORKTREE" "braid-$(branch_slug "$(current_branch)")" "$COMMAND"; then
    warn "$(printf '%s\n' \
        "could not open a window in $LAUNCHER." \
        "  last call: ${BRAID_RUN_LAUNCHER_PROBE:-unknown}" \
        "  run it here instead:  braid orchestrate --here")"
    exit 4
fi
note "watch it there, and this terminal with: braid status"
