#!/usr/bin/env bash
# The braid block parser.
#
# Every case here is a way the old `grep -i -m1 "$key"` parser was wrong. They are worth
# pinning because each failure is silent: a wave launches, and the consequence arrives
# half an hour later as two workers in the same file or a worker without its database.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export BRAID_HOME="${BRAID_HOME:-$(pwd)}"
# shellcheck source=../lib/slice.sh
source "$BRAID_HOME/lib/slice.sh"

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

# Every accessor dies on bad input, so each case runs in a subshell and is judged on its
# output and status together.
expect() {
    local label="$1" want="$2" got status
    shift 2
    got=$("$@" 2>&1)
    status=$?
    if [[ "$status" -eq 0 && "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label — wanted '$want', got '$got' (exit $status)"
    fi
}

expect_die() {
    local label="$1" pattern="$2" got status
    shift 2
    got=$("$@" 2>&1)
    status=$?
    if [[ "$status" -ne 0 && "$got" == *"$pattern"* ]]; then
        ok "$label"
    else
        bad "$label — wanted a failure mentioning '$pattern', got '$got' (exit $status)"
    fi
}

echo
echo "slice"
echo

WELL_FORMED='# Add the OAuth callback

```braid
complexity: high
setup: yes
blocked-by: 280, 281
```

## What to build

Build it.

## Blocked by

- #280 the session store
- #281 the token service
'

expect "complexity"          "high"      slice_complexity "$WELL_FORMED"
expect "setup yes is 1"      "1"         slice_setup "$WELL_FORMED"
expect "blocked-by, whole"   "280 281"   slice_blocked_by "$WELL_FORMED"

# --- the bug this format exists for -------------------------------------------

# Prose above the block used to win, because the match was an unanchored substring over
# the whole body. This is the single most expensive failure the old parser had: a slice
# that needed a database ran without one.
PROSE_TRAP='# Rate limiting

This slice needs setup: yes for the redis fixture — or it would, if we were not
reusing the one from 01. Agent model: opus was considered and rejected.

```braid
complexity: low
setup: no
```
'
expect "prose above the block does not win (setup)"      "0"   slice_setup "$PROSE_TRAP"
expect "prose above the block does not win (complexity)" "low" slice_complexity "$PROSE_TRAP"

# The old parser took only the first word, so a multi-value field was unreadable and
# `blocked-by` silently became one id.
MULTI='```braid
setup: no
blocked-by: 12, 13, 14
```
'
expect "multi-value fields survive" "12 13 14" slice_blocked_by "$MULTI"

# --- required, never guessed --------------------------------------------------

expect_die "setup is required" "'setup' is required" slice_setup '```braid
complexity: low
```
'
expect_die "a typo is an error, not an absence" "unknown key 'setups'" slice_validate '```braid
setups: no
```
'
expect_die "a repeated key is an error" "appears twice" slice_validate '```braid
setup: no
setup: yes
```
'
expect_die "a non-field line is an error" "is not" slice_validate '```braid
setup no
```
'
expect_die "an unknown complexity is an error" "expected: low, standard, high" \
    slice_complexity '```braid
complexity: enormous
setup: no
```
'

# --- defaults and absences ----------------------------------------------------

expect "complexity defaults to standard" "standard" slice_complexity '```braid
setup: no
```
'
expect "no block at all yields no blockers" "" slice_blocked_by '# Just a title

Some prose.
'

# --- the two copies of blocked-by ---------------------------------------------

expect "the two copies agreeing is fine" "12 13" slice_blocked_by '```braid
setup: no
blocked-by: 12, 13
```

## Blocked by
#13, #12
'
expect_die "the two copies disagreeing is an error" "disagrees" slice_blocked_by '```braid
setup: no
blocked-by: 12, 13
```

## Blocked by
#12 only
'
expect "prose words are not ids" "280 281" slice_blocked_by '```braid
setup: no
```

## Blocked by
- #280 the session store
- #281 the token service
'
expect "prose alone is enough" "9" slice_blocked_by '```braid
setup: no
```

## Blocked by
#9
'
expect "a later section ends the prose list" "9" slice_blocked_by '```braid
setup: no
```

## Blocked by
#9

## Acceptance
- closes #77
'

# --- only the first fence -----------------------------------------------------

expect "a later braid fence is documentation, not config" "0" slice_setup '```braid
setup: no
```

## Notes

Other slices write:

```braid
setup: yes
```
'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
