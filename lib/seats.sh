#!/usr/bin/env bash
# The one question braid asks that costs money.
#
# Which agent, which model and how hard it reasons, for each seat and each complexity
# level. It is asked in two places — once by `braid init`, at the only moment somebody
# is certain to be looking, and any time afterwards by `braid config` — so it lives in
# neither of them.
#
# Every answer is written through braid_sh_set, so an empty one keeps whatever was
# resolving before rather than writing an empty value over it.

[[ -n "${_BRAID_SEATS_SH:-}" ]] && return 0
_BRAID_SEATS_SH=1

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"

# --- which agent, model and effort runs each seat -------------------------------

# What a seat resolves to right now: "<agent> <model>", or nothing when no agent in the
# repository's list is installed here. Loaded in a subshell, because agent_load sources
# an adapter into the shell that calls it and there are several of these.
seat_now() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 1
        printf '%s %s' "$BRAID_RUN_AGENT" "$(agent_model "$1")"
    ) 2>/dev/null
}

# The same for a complexity level, which has no agent of its own: a slice says how much
# judgement the work needs and the agent on the `work` seat says what that is here.
level_now() {
    (
        agent_load work 2>/dev/null || exit 1
        agent_complexity "${1:?level}"
    ) 2>/dev/null
}

seat_effort_now() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 1
        if [[ "$1" == work ]]; then
            agent_complexity_effort standard
        else
            agent_effort "$1"
        fi
    ) 2>/dev/null
}

level_effort_now() {
    (
        agent_load work 2>/dev/null || exit 1
        agent_complexity_effort "${1:?level}"
    ) 2>/dev/null
}

# Refused the way the seat itself would refuse it, but without taking setup down with
# it: agent_check_model dies, which is right when a wave is about to start and wrong
# when somebody is typing an answer and can simply be asked again.
model_ok() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 0
        agent_check_model "$2"
    ) >/dev/null 2>&1
}

# How an empty model or effort reads. It is not missing: it means the CLI picks, which is
# the right answer for defaults that can change faster than a committed file can.
shown() { printf '%s' "${1:-(the CLI chooses)}"; }

# One answer, with the current value as the default and empty meaning "keep it".
ask_value() {
    local label="${1:?label}" current="${2:-}" answer
    printf '  %-22s [%s]: ' "$label" "$(shown "$current")" >&2
    read -r answer || answer=""
    printf '%s' "$answer"
}

# Ask for one model, refuse what the seat's agent would refuse, and report the
# assignment rather than performing it. It runs inside a command substitution, so it
# cannot write anything the caller would see — which is the whole reason the answers are
# collected first and applied once, together.
ask_model() {
    local seat="${1:?seat}" label="${2:?label}" current="${3:-}" tier="${4:-$1}" model
    while :; do
        model=$(ask_value "$label" "$current")
        [[ -n "$model" ]] || return 0
        if model_ok "$seat" "$model"; then
            printf '%s %s' "$(seat_var MODEL "$tier")" "$model"
            return 0
        fi
        warn "that is not a model $(seat_now "$seat" | cut -d' ' -f1) accepts"
    done
}

ask_effort() {
    local tier="${1:?tier}" label="${2:?label}" current="${3:-}" seat="${4:?seat}" effort
    while :; do
        effort=$(ask_value "$label" "$current")
        [[ -n "$effort" ]] || return 0
        if (
            agent_load "$seat" 2>/dev/null || exit 1
            agent_check_effort "$effort"
        ) >/dev/null 2>&1; then
            printf '%s %s' "$(seat_var EFFORT "$tier")" "$effort"
            return 0
        fi
        warn "'$effort' is not a supported effort for $(seat_now "$seat" | cut -d' ' -f1)"
    done
}

# The table, then one question about the whole of it.
#
# This is the largest lever there is on what a wave costs, and every value in it is a
# default from an adapter — a guess about somebody else's budget. It is also the only
# moment anybody is looking: after this, the table is something you have to know to go
# and ask `braid doctor` for.
#
# Asked here rather than in the session below for the same reason the agent list is: the
# session is opened by the design seat, so its model is already spent by the time an
# agent could ask you about it.
seats_ask() {
    local seat level agent model effort answer row writes="" agents=0 width
    # Measured, not typed. The same table in braid doctor learned this the same way.
    width=$(agents_shipped | tr ' ' '\n' | awk '{ if (length > m) m = length } END { print m }')

    for seat in $BRAID_AGENTS; do
        agents=$((agents + 1))
    done

    echo >&2
    note "which agent, model and reasoning effort runs each seat?"
    for seat in design orchestrate work; do
        row=$(seat_now "$seat")
        [[ -n "$row" ]] || {
            meh "no agent resolves for the $seat seat — nothing to ask about yet"
            return 1
        }
        effort=$(seat_effort_now "$seat")
        info "$(printf "%-13s %-${width}s %-24s effort: %s" "$seat" "${row%% *}" \
            "$(shown "${row#* }")" "$(shown "$effort")")"
    done
    echo >&2
    note "and what a slice's complexity means, on the work seat?"
    for level in low standard high; do
        info "$(printf "%-13s %-${width}s %-24s effort: %s" "$level" "" \
            "$(shown "$(level_now "$level")")" "$(shown "$(level_effort_now "$level")")")"
    done
    echo >&2
    info "the table resolves repository overrides first, then the adapter or CLI default."
    info "it is the biggest lever there is on what a wave costs."

    printf '\n  change any of it? [y/N] ' >&2
    read -r answer || answer=""
    case "$answer" in
        [yY]*) ;;
        *) return 0 ;;
    esac
    echo >&2

    for seat in design orchestrate work; do
        row=$(seat_now "$seat")
        # Only where there is a choice to make. A repository that supports one agent
        # answered this one question ago.
        if [[ "$agents" -gt 1 ]]; then
            agent=$(ask_value "$seat agent" "${row%% *}")
            if [[ -n "$agent" ]]; then
                if agent_supported "$agent" && agent_usable "$agent"; then
                    # Written and exported at once: the seats below resolve against it,
                    # and so does the session this command opens when it is done.
                    braid_sh_set "$(seat_var AGENT "$seat")" "$agent" \
                        "Which agent takes which seat. Only the seats pinned here; the rest fall to BRAID_AGENTS, in order."
                    export "$(seat_var AGENT "$seat")=$agent"
                    row=$(seat_now "$seat")
                elif agent_supported "$agent"; then
                    warn "'$agent' is not installed here — left alone"
                else
                    warn "'$agent' is not in this repository's list ($BRAID_AGENTS) — left alone"
                fi
            fi
        fi
        answer=$(ask_model "$seat" "$seat model" "${row#* }")
        [[ -z "$answer" ]] || writes="$writes$answer
"
        if [[ "$seat" != work ]]; then
            answer=$(ask_effort "$seat" "$seat effort" "$(seat_effort_now "$seat")" "$seat")
            [[ -z "$answer" ]] || writes="$writes$answer
"
        fi
    done

    for level in low standard high; do
        answer=$(ask_model work "complexity: $level" "$(level_now "$level")" "$level")
        [[ -z "$answer" ]] || writes="$writes$answer
"
        answer=$(ask_effort "$level" "$level effort" "$(level_effort_now "$level")" work)
        [[ -z "$answer" ]] || writes="$writes$answer
"
    done

    [[ -n "$writes" ]] || {
        note "nothing changed — every row keeps its current value"
        return 0
    }

    # Written together, under a heading, rather than one line at a time as they were
    # answered. Assignments scattered down a file nobody reads twice are several things
    # to find later; a block with a sentence over it is one.
    # A here-string, not a pipe: a pipe puts the loop in a subshell and the exports
    # below would be lost with it — and the design seat's model has to reach the session
    # this command opens in a moment, which braid_config read braid.sh too early to see.
    while read -r var value; do
        [[ -n "$var" ]] || continue
        braid_sh_set "$var" "$value" \
            "What each seat and each complexity level costs. braid doctor resolves the whole table."
        export "$var=$value"
    done <<<"$writes"
    ok "braid.sh records what you changed; the rest keeps its current resolution"
}
