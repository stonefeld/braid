#!/usr/bin/env bash
# Adapter — anything with a command line.
#
# Not a fallback: this is the reason braid can claim to be agent-agnostic at all. Give
# it a template and it runs whatever you like.
#
#   BRAID_AGENT=generic
#   BRAID_GENERIC_CMD='my-agent run --model {model} --prompt {prompt}'
#
# {prompt}, {model}, {effort} and {worktree} are substituted with properly quoted
# values. The command runs with the worktree as its working directory.
#
# Nothing is lost by using it. The contract is in the prompt and status is written by
# .braid/finish.sh when the process exits — neither needs the agent to cooperate, or
# even to have started successfully.

: "${BRAID_GENERIC_CMD:=}"

agent_available() {
    [[ -n "$BRAID_GENERIC_CMD" ]] || return 1
    command -v "${BRAID_GENERIC_CMD%% *}" >/dev/null 2>&1
}

agent_version() { printf '%s' "${BRAID_GENERIC_CMD%% *}"; }

agent_seat_model() { :; }

# Nothing to map. Set BRAID_MODEL_LOW / _STANDARD / _HIGH if your agent takes a model.
agent_complexity_model() { :; }

agent_models() { :; }

agent_injects_contract() { return 1; }

# Unknown agent, so a skill arrives as text — which is all a skill ever was, and the
# reason braid can claim to work with something it has never heard of.
agent_loads_skills() { return 1; }

# Nothing to probe, and therefore no probe. A probe asks the installed CLI whether the
# flags this adapter sets still exist; this adapter sets none, because the whole command
# line came from the person. `braid doctor` reports the absence, which is true, rather
# than a check that returned success without asking anything.
agent_auto_mode() { printf 'in BRAID_GENERIC_CMD'; }
agent_effort_mode() { printf '{effort} in BRAID_GENERIC_CMD'; }

agent_command() {
    local worktree="$1" model="$2" prompt="$3" effort="${4:-}" template="$BRAID_GENERIC_CMD"
    [[ -n "$template" ]] ||
        die "BRAID_AGENT=generic needs BRAID_GENERIC_CMD (see lib/agents/generic.sh)"
    # Bash >=5.2's patsub_replacement turns an unescaped '&' in the replacement below
    # into the matched text, mangling any '&' in the prompt (e.g. 2>&1 -> 2>{prompt}1).
    shopt -u patsub_replacement 2>/dev/null || true
    template="${template//\{prompt\}/$(printf '%q' "$prompt")}"
    template="${template//\{model\}/$(printf '%q' "$model")}"
    template="${template//\{effort\}/$(printf '%q' "$effort")}"
    template="${template//\{worktree\}/$(printf '%q' "$worktree")}"
    printf '%s' "$template"
}

agent_transcript_dir() { :; }
