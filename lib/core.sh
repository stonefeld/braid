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
