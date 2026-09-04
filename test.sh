#!/usr/bin/env bash
# Run braid's tests.
#
#   ./test.sh                every suite
#   ./test.sh e2e            one of them, by name
#   ./test.sh slice schedule several
#   ./test.sh --list         what there is
#
# Needs exactly what braid needs — git 2.20, bash 3.2, python3 3.9 — and nothing else.
# `shellcheck` is used if it is on your PATH and skipped, loudly, if it is not.
#
# **No agent is ever launched, and no network is ever used.** A worker is simulated by
# committing in its worktree and running .braid/finish.sh, which is exactly what a real
# worker does; a tracker is simulated by a `gh` on PATH that answers from files. The two
# things that cannot be tested are the agent and the shape of somebody else's JSON, and
# nothing here pretends otherwise.
#
# Everything runs against a temporary HOME and a temporary XDG_DATA_HOME, so an installed
# braid on this machine is never touched. That is worth knowing before you run it on the
# laptop that is halfway through a feature.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# name:what it defends
SUITES=(
    "compat:the invariants that rot silently — bash 3.2, stdlib python, the manifest"
    "slice:the braid block parser"
    "schedule:deriving waves from blockers, serialisation and capacity"
    "e2e:a whole feature, end to end, in a repository created thirty seconds ago"
)

if [[ -t 1 ]]; then
    B=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' DIM=$'\033[2m' OFF=$'\033[0m'
else
    B='' RED='' GREEN='' DIM='' OFF=''
fi

usage() {
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    echo
    for entry in "${SUITES[@]}"; do
        printf '  %-10s %s\n' "${entry%%:*}" "${entry#*:}"
    done
}

WANTED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --list)
            for entry in "${SUITES[@]}"; do printf '%s\n' "${entry%%:*}"; done
            exit 0
            ;;
        -*)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
        *)
            WANTED+=("$1")
            shift
            ;;
    esac
done

# Named suites are checked before any of them runs. A typo that silently runs nothing
# looks exactly like a suite that passes.
if [[ "${#WANTED[@]}" -gt 0 ]]; then
    for name in "${WANTED[@]}"; do
        [[ -f "test/$name.sh" ]] || {
            echo "no suite '$name' — try: $(./test.sh --list | tr '\n' ' ')" >&2
            exit 1
        }
    done
else
    for entry in "${SUITES[@]}"; do WANTED+=("${entry%%:*}"); done
fi

command -v git >/dev/null 2>&1 || {
    echo "git is required" >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required" >&2
    exit 1
}
command -v shellcheck >/dev/null 2>&1 ||
    printf '%s  shellcheck is not installed — compat will skip it, and CI will not%s\n' \
        "$DIM" "$OFF" >&2

FAILED=()
for name in "${WANTED[@]}"; do
    printf '\n%s──── %s%s\n' "$B" "$name" "$OFF"
    if bash "test/$name.sh"; then :; else FAILED+=("$name"); fi
done

echo
if [[ "${#FAILED[@]}" -eq 0 ]]; then
    [[ "${#WANTED[@]}" -eq 1 ]] && WORD=suite || WORD=suites
    printf '%sall %d %s passed%s\n\n' "$GREEN" "${#WANTED[@]}" "$WORD" "$OFF"
    exit 0
fi
printf '%sfailed: %s%s\n' "$RED" "${FAILED[*]}" "$OFF"
printf '  run one on its own for the detail:  ./test.sh %s\n\n' "${FAILED[0]}"
exit 1
