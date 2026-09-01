#!/usr/bin/env bash
# The scheduler.
#
# A wave is a schedule, not a level of the dependency graph, and every case here is one
# of the three things that separates them.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0
FAIL=0
ok() {
    printf '  \033[32mok\033[0m    %s\n' "$*"
    PASS=$((PASS + 1))
}
bad() {
    printf '  \033[31mFAIL\033[0m  %s\n' "$*"
    FAIL=$((FAIL + 1))
}

# id \t complexity \t setup \t blockers
schedule() {
    printf '%b' "$2" | python3 lib/schedule.py "$1" 2>/dev/null
}

expect() {
    local label="$1" capacity="$2" input="$3" want="$4" got
    got=$(schedule "$capacity" "$input")
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label"
        printf '        wanted: %s\n' "${want//$'\n'/ | }"
        printf '        got:    %s\n' "${got//$'\n'/ | }"
    fi
}

echo
echo "schedule"
echo

expect "independent slices share a wave" 4 \
    'a\tstandard\t0\t\nb\tstandard\t0\t\n' \
    'wave 1: a, b'

expect "a blocker pushes to the next wave" 4 \
    'a\tstandard\t0\t\nb\tstandard\t0\ta\n' \
    'wave 1: a
wave 2: b'

expect "a slice waits for its deepest blocker, not its first" 4 \
    'a\tstandard\t0\t\nb\tstandard\t0\ta\nc\tstandard\t0\ta b\n' \
    'wave 1: a
wave 2: b
wave 3: c'

# Capacity is what stops a wave from being a graph level. Nothing about the dependencies
# below says these four cannot run together — the machine does.
expect "capacity splits one level into several waves" 2 \
    'a\tstandard\t0\t\nb\tstandard\t0\t\nc\tstandard\t0\t\nd\tstandard\t0\t\n' \
    'wave 1: a, b
wave 2: c, d'

# Two slices that provision the expensive path share migration history and generated
# state, so they serialise even with no dependency between them.
expect "two setup slices never share a wave" 4 \
    'a\tstandard\t1\t\nb\tstandard\t1\t\n' \
    'wave 1: a
wave 2: b'

expect "one setup slice may share with ordinary ones" 4 \
    'a\tstandard\t1\t\nb\tstandard\t0\t\nc\tstandard\t0\t\n' \
    'wave 1: a, b, c'

# Re-running plan must not reshuffle a schedule that did not change, or every re-run is
# a diff somebody has to read.
expect "declaration order is stable" 4 \
    'z\tstandard\t0\t\nm\tstandard\t0\t\na\tstandard\t0\t\n' \
    'wave 1: z, m, a'

# A slice may legitimately wait on work outside this feature. It cannot be scheduled
# here, so it is reported on stderr and treated as done — never silently dropped, and
# never a reason to refuse the whole plan.
expect "an unknown blocker does not block" 4 \
    'a\tstandard\t0\t412\n' \
    'wave 1: a'
if printf 'a\tstandard\t0\t412\n' | python3 lib/schedule.py 4 2>&1 >/dev/null | grep -q 412; then
    ok "an unknown blocker is reported"
else
    bad "an unknown blocker is not reported"
fi

if printf 'a\tstandard\t0\tb\nb\tstandard\t0\ta\n' | python3 lib/schedule.py 4 >/dev/null 2>&1; then
    bad "a cycle is accepted"
else
    ok "a cycle is refused"
fi

if printf '' | python3 lib/schedule.py 4 >/dev/null 2>&1; then
    bad "an empty feature is accepted"
else
    ok "an empty feature is refused"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
