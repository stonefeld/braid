#!/usr/bin/env bash
# Derive a feature's wave schedule from its slices.
#
#   braid plan [feature] [options]
#
#     --dry-run          print the schedule, write nothing
#     --capacity N       workers per wave  (default: BRAID_MAX_WORKERS)
#
# You do not write waves by hand. The blockers are the input, the schedule is derived
# from them under the constraints braid knows about — serialisation and capacity — and
# what you do is argue with the result.
#
# Re-runnable by construction. Only the braid fence in plan.md is rewritten; the
# Contracts and Traps sections are yours and are carried across untouched, because they
# hold the one thing nothing else can: what spans slices.

set -uo pipefail

# shellcheck source=source.sh
source "$BRAID_HOME/lib/source.sh"

FEATURE=""
DRY=0
CAPACITY=""
PRD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY=1
            shift
            ;;
        --capacity)
            CAPACITY="${2:?--capacity needs a number}"
            shift 2
            ;;
        --prd)
            PRD="${2:?--prd needs an issue number}"
            PRD="${PRD#\#}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            FEATURE="$1"
            shift
            ;;
    esac
done

braid_config
refuse_worker_seat

# The feature is the branch you are on, because that is the branch its workers will be
# cut from. Naming one explicitly is for planning a feature you are not standing in.
[[ -n "$FEATURE" ]] || FEATURE=$(branch_slug "$(current_branch)")
DIR="$(slice_dir "$FEATURE")"
CAPACITY="${CAPACITY:-$BRAID_MAX_WORKERS}"

# A PRD given once is remembered, so every later command finds the feature's slices
# without being told again. Written before anything else needs it, because with a tracker
# the plan itself lives in that issue and cannot be found without it.
if [[ "$BRAID_SLICE_SOURCE" == github ]]; then
    if [[ -n "$PRD" ]]; then
        remember_prd "$FEATURE" "$PRD"
    else
        PRD=$(feature_prd "$FEATURE" 2>/dev/null || true)
    fi
fi
if [[ "$BRAID_SLICE_SOURCE" == files ]]; then
    [[ -d "$DIR" ]] || die "$(printf '%s\n' \
        "no feature at $DIR" \
        "  a feature is a folder: its slices are the files in it, and the folder is their parent." \
        "  mkdir -p $DIR and write the slices, or pass a different name.")"
    mkdir -p "$DIR"
fi

# The braid block is parsed the same from a file and from an issue body, which is the
# whole point of putting it in the markdown rather than in a tracker's own fields.
# Read into a variable first, so a failure to *list* the slices is distinguishable from
# there being none. Consumed through `< <(…)` the list ran in a subshell, where a die ends
# only the subshell — so a logged-out gh printed why it could not reach the tracker and
# then plan carried on and said "no slices found for 'auth'", which is a different and
# wrong explanation of the same event.
IDS=$(BRAID_FEATURE="$FEATURE" BRAID_PRD="$PRD" list_slices "$FEATURE") || exit 1

TABLE=""
COUNT=0
while read -r id; do
    [[ -n "$id" ]] || continue
    body=$(BRAID_FEATURE="$FEATURE" fetch_slice "$id")
    slice_validate "$body"
    # Each field in its own substitution, each failure caught here: a `die` inside
    # `$(...)` ends only the subshell, and the plan used to carry on with an empty
    # column as if the slice had answered.
    complexity=$(slice_complexity "$body") || die "#$id: unusable braid block"
    setup=$(slice_setup "$body") || die "#$id: unusable braid block"
    blockers=$(slice_blocked_by "$body") || die "#$id: unusable braid block"
    TABLE+="$id	$complexity	$setup	$blockers
"
    COUNT=$((COUNT + 1))
done <<<"$IDS"
[[ "$COUNT" -gt 0 ]] ||
    die "no slices found for '$FEATURE' (source: $BRAID_SLICE_SOURCE)"

note "$COUNT slices from $BRAID_SLICE_SOURCE${PRD:+ (PRD #$PRD)}, capacity $CAPACITY"
WAVES=$(printf '%s' "$TABLE" | python3 "$BRAID_HOME/lib/schedule.py" "$CAPACITY") ||
    die "could not schedule these slices"

echo
printf '%s\n' "$WAVES" | while read -r line; do
    printf '  %s\n' "$line"
done
echo

if [[ "$DRY" -eq 1 ]]; then
    note "--dry-run: nothing written"
    exit 0
fi

# The document as it stands — a file, or the PRD issue's own body — or nothing at all the
# first time. Only the fence in it belongs to braid; everything else is the reason the
# document is worth having.
EXISTING=$(fetch_plan "$FEATURE" 2>/dev/null || true)

# Through the environment, not a pipe: `python3 -` already reads its program from stdin,
# so a heredoc and a pipe cannot both be there — the heredoc wins and the document
# silently arrives empty, which would rewrite somebody's PRD body as a bare template.
UPDATED=$(BRAID_PLAN_DOCUMENT="$EXISTING" \
    python3 - "$FEATURE" "$WAVES" "${PRD:-}" <<'PYEOF'
import os
import re
import sys

feature, waves = sys.argv[1], sys.argv[2]
prd = sys.argv[3] if len(sys.argv) > 3 else ""
document = os.environ.get("BRAID_PLAN_DOCUMENT", "")

body = (f"prd: #{prd}\n" if prd else "") + waves.strip()
fence = "```braid\n" + body + "\n```"

SECTIONS = """
## Contracts

<Only what spans slices: an interface two of them implement, an invariant they must
both hold, the shape of data passed between them. Anything that belongs to one slice
belongs in that slice.>

## Traps

<What will bite: coexistence with a legacy path, a chokepoint that has to keep
working, a module that looks unrelated and is not.>
"""

updated, count = re.subn(r"```braid\n.*?\n```", fence, document, count=1, flags=re.DOTALL)
if count == 0:
    if document.strip():
        # A PRD body, or a plan whose fence somebody deleted. Appended rather than
        # prepended: the document is the point and the schedule is an appendix to it,
        # which is the wrong way round the moment the document is an issue people read.
        updated = document.rstrip() + "\n\n" + fence + "\n"
    else:
        updated = f"# Plan \u2014 {feature}\n\n{fence}\n"

# Added once and never re-added: they are the human's, an empty pair of headings is a
# prompt to fill them in, and a second pair below the filled-in ones is a mess.
if not re.search(r"^##\s+Contracts", updated, flags=re.M):
    updated = updated.rstrip() + "\n" + SECTIONS

sys.stdout.write(updated)
PYEOF
)

WHERE=$(write_plan "$FEATURE" "$UPDATED")
if [[ -n "$EXISTING" ]]; then
    note "updated the plan in $WHERE"
else
    note "wrote the plan to $WHERE"
fi
