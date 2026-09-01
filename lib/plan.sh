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

# shellcheck source=slice.sh
source "$BRAID_HOME/lib/slice.sh"
# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

FEATURE=""
DRY=0
CAPACITY=""

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
DIR="$(primary_checkout)/$BRAID_FEATURES_DIR/$FEATURE"
[[ -d "$DIR" ]] || die "$(printf '%s\n' \
    "no feature at $DIR" \
    "  a feature is a folder: its slices are the files in it, and the folder is their parent." \
    "  mkdir -p $DIR and write the slices, or pass a different name.")"

CAPACITY="${CAPACITY:-$BRAID_MAX_WORKERS}"
PLAN="$DIR/plan.md"

# Every .md in the folder except the two braid owns. The id is the filename, which is
# also what spawn takes and what the branch is named after — one identifier, derivable
# from any of the others.
TABLE=""
COUNT=0
for file in "$DIR"/*.md; do
    [[ -f "$file" ]] || continue
    id=$(basename "$file" .md)
    case "$id" in prd | plan | README) continue ;; esac
    body=$(cat "$file")
    slice_validate "$body"
    TABLE+="$id	$(slice_complexity "$body")	$(slice_setup "$body")	$(slice_blocked_by "$body")
"
    COUNT=$((COUNT + 1))
done
[[ "$COUNT" -gt 0 ]] || die "no slices in $DIR (a slice is any .md that is not prd.md or plan.md)"

note "$COUNT slices, capacity $CAPACITY"
WAVES=$(printf '%s' "$TABLE" | python3 "$BRAID_HOME/lib/schedule.py" "$CAPACITY") ||
    die "could not schedule these slices"

echo
printf '%s\n' "$WAVES" | while read -r line; do
    printf '  %s\n' "$line"
done
echo

if [[ "$DRY" -eq 1 ]]; then
    note "--dry-run: $PLAN not written"
    exit 0
fi

# Rewrite only the fence. Everything else in the file is human-written and is the
# reason the file is worth committing at all.
python3 - "$PLAN" "$FEATURE" "$WAVES" <<'PY'
import pathlib
import re
import sys

path, feature, waves = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
fence = "```braid\n" + waves.strip() + "\n```"

if path.exists():
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(
        r"```braid\n.*?\n```", fence, original, count=1, flags=re.DOTALL
    )
    if count == 0:
        # A plan somebody wrote by hand, or one whose fence they deleted. Prepend rather
        # than guess where it belonged.
        updated = fence + "\n\n" + original
    path.write_text(updated, encoding="utf-8")
    print(f"updated {path}")
else:
    path.write_text(
        f"""# Plan — {feature}

{fence}

## Contracts

<Only what spans slices: an interface two of them implement, an invariant they must
both hold, the shape of data passed between them. Anything that belongs to one slice
belongs in that slice.>

## Traps

<What will bite: coexistence with a legacy path, a chokepoint that has to keep
working, a module that looks unrelated and is not.>
""",
        encoding="utf-8",
    )
    print(f"wrote {path}")
PY
