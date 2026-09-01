#!/usr/bin/env bash
# Open the design seat, in this worktree, at the right tier.
#
#   braid design                     start a session and take it from there
#   braid design "the payments flow" open it with something to chew on
#
#     --model NAME    override the tier for this one session
#
# This is a shortcut, not a workflow. **braid has no opinion about how you decide what to
# build** — grilling, a PRD, a conversation, a whiteboard photo — and this command carries
# none: it starts your agent, on the tier this repository calls `design`, in the worktree
# you are standing in, and gets out of the way.
#
# What it saves is the part that is fiddly and easy to get wrong: the tier's model name
# lives in one file, so this works the same whether the seat is Claude or Codex, and you
# stop choosing a model by hand at the moment you least want to think about it.
#
# The design seat and the orchestrator share this worktree, one after the other. The
# orchestrator wants a fresh window; this is where you already are.

set -uo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"

MODEL=""
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            PROMPT="${PROMPT:+$PROMPT }$1"
            shift
            ;;
    esac
done

braid_config
refuse_worker_seat

if is_protected_branch "$(current_branch)"; then
    warn "$(printf '%s\n' \
        "you are on '$(current_branch)'. cut a feature branch before designing on it:" \
        "  git checkout -b feat/<something>" \
        "the worktree you design in becomes the one the orchestrator runs in.")"
fi

agent_load design || exit 1
MODEL="${MODEL:-$(agent_model design)}"
agent_check_model "$MODEL"

note "$BRAID_AGENT_RESOLVED${MODEL:+ ($MODEL)} — the design seat, in $(current_worktree)"
[[ -z "$PROMPT" ]] && note "slices go in $BRAID_FEATURES_DIR/$(branch_slug "$(current_branch)")/, then: braid plan"

eval "$(agent_cmd "$(current_worktree)" "$MODEL" "$PROMPT")"
