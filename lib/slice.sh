#!/usr/bin/env bash
# The braid block on a slice.
#
#     ```braid
#     complexity: standard
#     setup: no
#     blocked-by: 280, 281
#     ```
#
# It is *configuration of the slice*, not description of it — which is the rule that
# decides what may live here. Two keys are read at launch; a third records the ordering
# input. Acceptance criteria, scope and prose stay outside, where they are read by a
# worker rather than by a program.
#
# A fence rather than `**Key:** value` lines, for three reasons that all came from the
# same bug. The old parser was `grep -i -m1 "$key"` over the whole body, so a sentence
# mentioning a key beat the field itself; it then took the first word, which made any
# multi-value field unparseable. A fence cannot be reached by prose. It renders as a
# distinct block in a GitHub issue. And it *looks* like machine configuration, so nobody
# translates it into another language — which silently broke spawns in the codebase this
# lesson came from.

[[ -n "${_BRAID_SLICE_SH:-}" ]] && return 0
_BRAID_SLICE_SH=1

# shellcheck source=core.sh
source "$BRAID_HOME/lib/core.sh"

BRAID_SLICE_KEYS="complexity setup blocked-by"

# The contents of the first ```braid fence, or nothing. Anchored to the fence markers at
# the start of a line: there is no way for body prose to be mistaken for a field.
slice_block() {
    printf '%s\n' "${1?body}" | awk '
        !seen && /^[[:space:]]*```[[:space:]]*braid[[:space:]]*$/ { inblock = 1; seen = 1; next }
        inblock && /^[[:space:]]*```/ { inblock = 0; next }
        inblock { print }
    '
}

slice_has_block() {
    [[ -n "$(slice_block "${1?body}")" ]]
}

# Every key in the block, validated. A typo is an error rather than an absence: `setups:
# no` would otherwise read as "setup was not specified", and the difference between a
# misspelt field and a missing one is the difference between a wave that serialises and
# a wave that collides.
slice_validate() {
    local body="${1?body}" line key seen="" known
    while IFS= read -r line; do
        [[ -n "${line// /}" ]] || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *:* ]] ||
            die "braid block: '$line' is not 'key: value'"
        key=$(printf '%s' "${line%%:*}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

        known=0
        for candidate in $BRAID_SLICE_KEYS; do
            [[ "$key" == "$candidate" ]] && known=1
        done
        [[ "$known" -eq 1 ]] ||
            die "braid block: unknown key '$key' (expected: $BRAID_SLICE_KEYS)"

        case " $seen " in
            *" $key "*) die "braid block: '$key' appears twice" ;;
        esac
        seen="$seen $key"
    done < <(slice_block "$body")
}

slice_field() {
    local body="${1?body}" want="${2:?key}" line key value
    while IFS= read -r line; do
        [[ "$line" == *:* ]] || continue
        key=$(printf '%s' "${line%%:*}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [[ "$key" == "$want" ]] || continue
        value="${line#*:}"
        # Trimmed at both ends, and kept whole — a multi-value field is the reason the
        # old parser's `awk '{print $1}'` made blocked-by unreadable.
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        printf '%s' "$value"
        return 0
    done < <(slice_block "$body")
    return 1
}

# --- the fields ---------------------------------------------------------------

# How much judgement the work needs. Getting this wrong costs money or quality, never
# correctness, so a missing value takes the middle and says so.
slice_complexity() {
    local body="${1?body}" value
    value=$(slice_field "$body" complexity) || {
        printf 'standard'
        return 0
    }
    case "$value" in
        low | standard | high) printf '%s' "$value" ;;
        *) die "braid block: complexity '$value' (expected: low, standard, high)" ;;
    esac
}

# Whether this slice needs the expensive provision path. **Never defaulted.** Guessing
# `no` is the unsafe direction — the slice runs without the database or fixture it
# needed, in parallel with others, and fails strangely half an hour later — and guessing
# `yes` serialises a wave that did not need serialising. So it is required, and
# --setup/--no-setup is how a slice with no block is still spawnable.
slice_setup() {
    local body="${1?body}" value
    value=$(slice_field "$body" setup) ||
        die "braid block: 'setup' is required (yes or no). Pass --setup / --no-setup to override."
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        yes | true | 1) printf '1' ;;
        no | false | 0) printf '0' ;;
        *) die "braid block: setup '$value' (expected: yes or no)" ;;
    esac
}

# --- blockers -----------------------------------------------------------------

# Ids as written inside the braid block: "280, 281", "#280 #281", "—". Every token is a
# candidate there, because the block holds nothing but fields.
slice_ids() {
    printf '%s' "${1-}" | tr ',#' '  ' | tr -s '[:space:]' '\n' |
        grep -E '^[0-9A-Za-z][0-9A-Za-z._-]*$' | LC_ALL=C sort -u | tr '\n' ' ' |
        sed 's/ $//'
}

# Ids as written in prose, where **only a #-prefixed token counts**. The prose section
# exists to be read and clicked — "- #280 the session store" — so treating every word as
# a candidate turns a description into four imaginary blockers, which is exactly what it
# did the first time this was run.
slice_ids_prose() {
    printf '%s' "${1-}" | grep -oE '#[0-9A-Za-z][0-9A-Za-z._-]*' | tr -d '#' |
        LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The `## Blocked by` section, which is where the human-readable copy lives — inside a
# code fence GitHub does not linkify #123, and losing navigation in a tracker costs more
# than the duplication does.
slice_blocked_by_prose() {
    printf '%s\n' "${1?body}" | awk '
        tolower($0) ~ /^#+[[:space:]]*blocked[[:space:]]+by/ { inside = 1; next }
        inside && /^#+[[:space:]]/ { inside = 0 }
        inside { print }
    '
}

# Both copies are written by braid plan, so they are generated rather than maintained.
# If they disagree, somebody edited one of them — and picking either in silence would
# reorder a wave on the strength of a guess.
slice_blocked_by() {
    local body="${1?body}" block prose
    block=$(slice_ids "$(slice_field "$body" blocked-by || true)")
    prose=$(slice_ids_prose "$(slice_blocked_by_prose "$body")")

    if [[ -n "$block" && -n "$prose" && "$block" != "$prose" ]]; then
        die "$(printf '%s\n' \
            "blocked-by disagrees with the '## Blocked by' section:" \
            "  braid block:      ${block:-(none)}" \
            "  ## Blocked by:    ${prose:-(none)}" \
            "both are written by braid plan — re-run it, or make them match by hand.")"
    fi
    printf '%s' "${block:-$prose}"
}
