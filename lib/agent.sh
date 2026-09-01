#!/usr/bin/env bash
# Which agent runs which seat, and on which model.
#
# braid assumes only this much of an agent: it starts, it works in the directory it was
# started in, and it exits. Everything past that is per-agent and lives in
# lib/agents/<name>.sh, which is why those files are thirty lines and why an agent
# released next year works without a change here.
#
# Two facts are kept apart on purpose:
#
#   which agents are installed   a fact about this machine
#   which agents are supported   a decision this repository made and committed
#
# Detecting PATH and writing the winner into a committed file is how one person's
# laptop ends up configuring a team, so braid reports the first and obeys the second.

[[ -n "${_BRAID_AGENT_SH:-}" ]] && return 0
_BRAID_AGENT_SH=1

# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

# --- seats --------------------------------------------------------------------

# design       grilling, planning — the expensive seat, used briefly
# orchestrate  judging other agents' work and integrating it
# work         implementing one slice
#
# Tiers are named by seat rather than by brand so a vendor's model names appear in one
# file. BRAID_MODEL_WORK is only the default; a slice overrides it in its config block.
seat_var() {
    printf 'BRAID_%s_%s' "${1:?prefix}" "$(printf '%s' "${2:?seat}" | tr '[:lower:]-' '[:upper:]_')"
}

# --- resolution ---------------------------------------------------------------

agent_installed() {
    command -v "${1:?agent}" >/dev/null 2>&1
}

# `generic` is available exactly when it has been given a command to run, which is the
# same question for it that "is it on PATH" is for the others.
agent_usable() {
    local name="${1:?agent}"
    [[ -f "$BRAID_HOME/lib/agents/$name.sh" ]] || return 1
    if [[ "$name" == generic ]]; then
        [[ -n "${BRAID_AGENT_CMD:-}" ]] && agent_installed "${BRAID_AGENT_CMD%% *}"
    else
        agent_installed "$name"
    fi
}

agent_supported() {
    local name="${1:?agent}" candidate
    for candidate in $BRAID_AGENTS; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

# The agent for a seat, and why. Prints "<name> <reason>"; the reason is what doctor
# shows, because "why did it launch Claude" should not cost half an hour of reading
# shell.
#
#   1  BRAID_AGENT_<SEAT>            this seat, this session (or --agent)
#   2  BRAID_AGENT                   every seat, this session
#   3  ~/.config/braid/config        this machine          (sourced by braid_config)
#   4  BRAID_AGENTS, first usable    this repository, in order
#   5  error
agent_resolve() {
    local seat="${1:?seat}" want="" source="" var candidate

    var=$(seat_var AGENT "$seat")
    want="${!var:-}"
    [[ -n "$want" ]] && source="$var"

    if [[ -z "$want" && -n "${BRAID_AGENT:-}" ]]; then
        want="$BRAID_AGENT"
        source="BRAID_AGENT"
    fi

    if [[ -n "$want" ]]; then
        # A preference outside the repository's list never silently falls back to
        # something else. Adding an agent is a decision, not a discovery: an agent
        # without hooks takes its contract from the prompt and its status from
        # finish.sh, and somebody has to confirm that is enough *here*.
        agent_supported "$want" || die "$(
            printf '%s\n' \
                "'$want' (from $source) is not supported by this repository." \
                "  supported here: $BRAID_AGENTS" \
                "" \
                "  braid setup --add-agent $want    decide it, and commit the decision" \
                "  braid <cmd> --agent <supported>  just this once"
        )"
        agent_usable "$want" ||
            die "'$want' (from $source) is not installed on this machine"
        printf '%s %s' "$want" "$source"
        return 0
    fi

    for candidate in $BRAID_AGENTS; do
        agent_usable "$candidate" || continue
        printf '%s %s' "$candidate" "BRAID_AGENTS"
        return 0
    done

    die "$(
        printf '%s\n' \
            "no usable agent for the $seat seat." \
            "  supported here: $BRAID_AGENTS" \
            "  installed:      $(agents_installed || echo none)" \
            "" \
            "  install one, or set BRAID_AGENTS in braid.sh"
    )"
}

agents_installed() {
    local name found=""
    for name in "$BRAID_HOME"/lib/agents/*.sh; do
        name=$(basename "$name" .sh)
        agent_usable "$name" && found="$found $name"
    done
    [[ -n "$found" ]] && printf '%s' "${found# }"
}

# Source the adapter for a seat. After this the agent_* functions below are the
# adapter's, and BRAID_AGENT_RESOLVED says which one answered.
agent_load() {
    local seat="${1:?seat}" resolved
    # agent_resolve dies inside a command substitution, which only kills the subshell —
    # so its status has to be propagated or the caller sources lib/agents/.sh and
    # reports a missing file instead of the reason it actually failed.
    resolved=$(agent_resolve "$seat") || exit 1
    BRAID_AGENT_RESOLVED="${resolved%% *}"
    BRAID_AGENT_REASON="${resolved#* }"
    # shellcheck disable=SC1090
    source "$BRAID_HOME/lib/agents/$BRAID_AGENT_RESOLVED.sh"
    export BRAID_AGENT_RESOLVED
}

# --- models -------------------------------------------------------------------

# The tier for a seat: an explicit BRAID_MODEL_<SEAT>, else whatever the adapter
# recommends. An adapter that recommends nothing lets its CLI choose, which is the
# right answer for a vendor whose model names change faster than this repository can.
agent_model() {
    local seat="${1:?seat}" var
    var=$(seat_var MODEL "$seat")
    if [[ -n "${!var:-}" ]]; then
        printf '%s' "${!var}"
    else
        agent_seat_model "$seat"
    fi
}

# The model for a worker, from the slice's complexity rather than from a model name.
# A slice is the most agent-agnostic artifact braid has — it lives in an issue, written
# by a skill that does not know which agent will run it — so it says how much judgement
# the work needs and the adapter says what that is here.
#
#   BRAID_MODEL_<COMPLEXITY>   this repository, or this session
#   the adapter's mapping      where it is confident enough to have one
#   nothing                    the CLI chooses, which is right for a vendor whose
#                              model names change faster than braid can track
agent_complexity() {
    local level="${1:-standard}" var
    case "$level" in
        low | standard | high) ;;
        *) die "unknown complexity '$level' (expected: low, standard, high)" ;;
    esac
    var=$(seat_var MODEL "$level")
    if [[ -n "${!var:-}" ]]; then
        printf '%s' "${!var}"
    else
        agent_complexity_model "$level"
    fi
}

# Checked only where the adapter says what it accepts. A typo in a model name is
# otherwise discovered by the agent, in a panel, several minutes later.
agent_check_model() {
    local model="${1:-}" valid
    [[ -n "$model" ]] || return 0
    valid=$(agent_models)
    [[ -n "$valid" ]] || return 0
    grep -qw -- "$model" <<<"$valid" ||
        die "unknown model '$model' for $BRAID_AGENT_RESOLVED (accepts: $valid)"
}

# --- adapter defaults ---------------------------------------------------------

# Overridable from braid.sh, the same escape hatch every other seam has: a project can
# replace the launch command wholesale without editing an adapter that braid upgrade
# will replace.
agent_cmd() {
    if declare -F braid_agent_command >/dev/null; then
        braid_agent_command "$@"
    else
        agent_command "$@"
    fi
}

# For a launcher with no terminal. An interactive TUI started without a tty either
# refuses or hangs, and a hung worker with no output is the worst state to debug.
agent_cmd_headless() {
    if declare -F agent_command_headless >/dev/null; then
        agent_command_headless "$@"
    else
        agent_cmd "$@"
    fi
}
