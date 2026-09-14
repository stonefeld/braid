#!/usr/bin/env bash
# Shared primitives. Source it, do not run it.
#
# Everything the engine says goes to stderr, and anything that moves goes there only
# when stderr is a terminal. These commands are read by an agent at least as often as
# by a person: a spinner on stdout fills an orchestrator's context with frames, and
# colour codes corrupt what it parses. stdout is for answers.

[[ -n "${BRAID_HOME:-}" ]] || {
    echo "error: core.sh sourced without BRAID_HOME — run commands through bin/braid" >&2
    exit 1
}

if [[ -t 2 ]]; then
    _C_RED=$'\033[31m' _C_GREEN=$'\033[32m' _C_YELLOW=$'\033[33m'
    _C_DIM=$'\033[2m' _C_OFF=$'\033[0m'
else
    _C_RED='' _C_GREEN='' _C_YELLOW='' _C_DIM='' _C_OFF=''
fi

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

note() { printf '==> %s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$_C_YELLOW" "$_C_OFF" "$*" >&2; }

ok() { printf '  %sok%s    %s\n' "$_C_GREEN" "$_C_OFF" "$*" >&2; }
bad() { printf '  %sFAIL%s  %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
meh() { printf '  %swarn%s  %s\n' "$_C_YELLOW" "$_C_OFF" "$*" >&2; }
info() { printf '  --    %s\n' "$*" >&2; }

# Transient progress. Never reaches a pipe, a log or an agent's context — so it is safe
# to put in front of anything slow, and it must never carry information that is not
# The value of a flag that takes one.
#
# Two things `"${2:?--model needs a name}"` did not do. A missing value surfaced as bash's
# own message — `lib/spawn.sh: line 53: 2: --model needs a name` — without the prefix every
# other error in braid carries. And nothing checked that the value was not itself a flag,
# so `braid spawn --model --effort high` ran on a model called `--effort` and took `high`
# for the slice.
#
# It dies inside a command substitution, which only kills the subshell, so a caller has to
# propagate:  MODEL=$(flag_value --model "${2-}") || exit 1
flag_value() {
    local flag="${1:?flag}" value="${2-}"
    [[ -n "$value" ]] || die "$flag needs a value"
    [[ "$value" != -?* ]] || die "$flag needs a value, and '$value' is another flag"
    printf '%s' "$value"
}

# The header comment of a command file, printed as its --help. From line two to the first
# line that is not a comment, found rather than counted: a range with a number in it has
# to be maintained against the comment it describes, and the failure when it is not is
# help that stops mid-sentence or runs on into the shell.
braid_help() {
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${1:?file}" >&2
}

# also said permanently somewhere.
progress() {
    [[ -t 2 ]] || return 0
    printf '\r%s  %s%s\033[K' "$_C_DIM" "$*" "$_C_OFF" >&2
}

progress_done() {
    [[ -t 2 ]] || return 0
    printf '\r\033[K' >&2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "${2:-$1 is required but not installed}"
}

braid_version() {
    cat "$BRAID_HOME/VERSION" 2>/dev/null || echo unknown
}
