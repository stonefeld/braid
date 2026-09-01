#!/usr/bin/env bash
# Launch a wave, never more than the machine can take at once.
#
#   braid wave 2                 the slices in wave 2 of plan.md
#   braid wave 01-schema 03-ui   these slices, whatever the plan says
#
#     --capacity N     workers at once  (default: BRAID_MAX_WORKERS)
#     --timeout N      how long to hold the queue open   (default: 900)
#     --dry-run        say what would launch, launch nothing
#
# The queue lives here rather than in the orchestrator's head. "Remember to only launch
# four" is exactly the instruction a model drops on the seventh iteration, and the cost
# of dropping it is a machine that stops responding in the middle of a wave.
#
# It returns once everything is **launched**, not once everything is done — `braid wait`
# is the waiting primitive, and keeping them separate means the wave command does not
# have to guess how long work takes.

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"
# shellcheck source=source.sh
source "$BRAID_HOME/lib/source.sh"

CAPACITY=""
TIMEOUT=900
DRY=0
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --capacity)
            CAPACITY="${2:?--capacity needs a number}"
            shift 2
            ;;
        --timeout)
            TIMEOUT="${2:?--timeout needs seconds}"
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        -h | --help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

braid_config
refuse_worker_seat

[[ "${#ARGS[@]}" -gt 0 ]] || die "usage: braid wave <number> | braid wave <slice> [slice…]"

CHECKOUT=$(primary_checkout)
FEATURE=$(branch_slug "$(current_branch)")
DIR="$CHECKOUT/$BRAID_FEATURES_DIR/$FEATURE"
PLAN="$DIR/plan.md"

# A single bare number is a wave in the plan; anything else is a list of slices. The
# ambiguity is resolved toward the plan because that is the common call, and a slice
# whose whole name is "2" would be unnameable for other reasons.
SLICES=()
if [[ "${#ARGS[@]}" -eq 1 && "${ARGS[0]}" =~ ^[0-9]+$ ]]; then
    [[ -f "$PLAN" ]] || die "no plan at $PLAN — run: braid plan"
    line=$(slice_field "$(cat "$PLAN")" "wave ${ARGS[0]}") ||
        die "$(printf '%s\n' \
            "wave ${ARGS[0]} is not in $PLAN. it has:" \
            "$(slice_block "$(cat "$PLAN")" | sed 's/^/  /')")"
    IFS=', ' read -r -a SLICES <<<"$line"
    note "wave ${ARGS[0]}: ${SLICES[*]}"
else
    SLICES=("${ARGS[@]}")
fi

# Resolved before anything launches — every one of them fetched, not merely named. Half
# a wave in flight and then "no such slice" is the worst moment to find out a name was
# wrong, and with a tracker it is also the worst moment to find out the network is down.
export BRAID_FEATURE="$FEATURE"
PATHS=()
for slice in "${SLICES[@]}"; do
    [[ -n "$slice" ]] || continue
    if [[ -f "$slice" ]]; then
        PATHS+=("$slice")
    elif [[ -f "$DIR/$slice.md" ]]; then
        PATHS+=("$DIR/$slice.md")
    elif fetch_slice "$slice" >/dev/null 2>&1; then
        PATHS+=("$slice")
    else
        die "no slice '$slice' (source: $BRAID_SLICE_SOURCE)"
    fi
done
[[ "${#PATHS[@]}" -gt 0 ]] || die "nothing to launch"

CAPACITY="${CAPACITY:-$BRAID_MAX_WORKERS}"

if [[ "$DRY" -eq 1 ]]; then
    note "would launch ${#PATHS[@]} workers, $CAPACITY at a time:"
    for path in "${PATHS[@]}"; do printf '  %s\n' "$path" >&2; done
    exit 0
fi

# Workers still going, from this wave or an earlier one that has not been reaped. Counted
# rather than tracked: a worker somebody launched by hand, or one left over from a wave
# that was interrupted, occupies the machine exactly as much as one braid started.
running_count() {
    local worktree n=0
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        worker_is_terminal "$worktree" || n=$((n + 1))
    done < <(worker_worktrees mine)
    printf '%s' "$n"
}

note "${#PATHS[@]} slices, $CAPACITY at a time"
STARTED=$(date +%s)
LAUNCHED=0
INDEX=0

while [[ "$INDEX" -lt "${#PATHS[@]}" ]]; do
    running=$(running_count)
    while [[ "$running" -lt "$CAPACITY" && "$INDEX" -lt "${#PATHS[@]}" ]]; do
        path="${PATHS[$INDEX]}"
        INDEX=$((INDEX + 1))
        if bash "$BRAID_HOME/lib/spawn.sh" "$path"; then
            LAUNCHED=$((LAUNCHED + 1))
            running=$((running + 1))
        else
            # One slice failing to launch does not cancel the wave. It is reported here
            # and it is absent from status, which is where the orchestrator will look.
            warn "could not launch $path — continuing with the rest of the wave"
        fi
    done

    [[ "$INDEX" -lt "${#PATHS[@]}" ]] || break

    elapsed=$(($(date +%s) - STARTED))
    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
        warn "$((${#PATHS[@]} - INDEX)) slices still queued after ${elapsed}s — run the same command again"
        exit 3
    fi
    progress "queue: $((${#PATHS[@]} - INDEX)) waiting for a slot… ${elapsed}s"
    sleep 10
done
progress_done

note "launched $LAUNCHED of ${#PATHS[@]}"
note "watch it with: braid status — then: braid wait"
