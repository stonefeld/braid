#!/usr/bin/env bash
# Adapter — anything with a command line.
#
# Not a fallback: this is the reason braid can claim to be agent-agnostic at all. Give
# it a template and it runs whatever you like.
#
#   BRAID_AGENT=generic
#   BRAID_AGENT_CMD='my-agent run --model {model} --prompt {prompt}'
#
# {prompt}, {model} and {worktree} are substituted with properly quoted values. The
# command runs with the worktree as its working directory.
#
# Nothing is lost by using it. The contract is in the prompt and status is written by
# .braid/finish.sh when the process exits — neither needs the agent to cooperate, or
# even to have started successfully.

: "${BRAID_AGENT_CMD:=}"

agent_available() {
    [[ -n "$BRAID_AGENT_CMD" ]] || return 1
    command -v "${BRAID_AGENT_CMD%% *}" >/dev/null 2>&1
}

agent_version() { printf '%s' "${BRAID_AGENT_CMD%% *}"; }

agent_seat_model() { :; }

# Nothing to map. Set BRAID_MODEL_LOW / _STANDARD / _HIGH if your agent takes a model.
agent_complexity_model() { :; }

agent_models() { :; }

agent_injects_contract() { return 1; }

# No skill mechanism, so a skill has to arrive as text like everything else does.
agent_loads_skills() { return 1; }

# Nothing to probe: whatever unattended means for your agent is already in the template
# you gave BRAID_AGENT_CMD.
agent_auto_mode() { printf 'in BRAID_AGENT_CMD'; }
agent_auto_mode_probe() { return 0; }

agent_command() {
    local worktree="$1" model="$2" prompt="$3" template="$BRAID_AGENT_CMD"
    [[ -n "$template" ]] ||
        die "BRAID_AGENT=generic needs BRAID_AGENT_CMD (see lib/agents/generic.sh)"
    template="${template//\{prompt\}/$(printf '%q' "$prompt")}"
    template="${template//\{model\}/$(printf '%q' "$model")}"
    template="${template//\{worktree\}/$(printf '%q' "$worktree")}"
    printf '%s' "$template"
}

agent_transcript_dir() { :; }
