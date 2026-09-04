#!/usr/bin/env bash
# What to run now, and why.
#
#   braid next
#
# The phase is derived every time — from git, from the worktrees, from the plan. Never
# from a file braid wrote down about where you were. In this workflow everybody does
# things by hand: an issue created in a browser, a plan edited, a worker killed. A
# stored phase is wrong the first time that happens, and it sends you to the wrong step
# with total confidence, which is the worst failure available to the command whose job
# is to guide.
#
# Where two signals disagree, or where one genuinely cannot be resolved, it says so
# instead of picking.

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"
# shellcheck source=source.sh
source "$BRAID_HOME/lib/source.sh"

braid_config
CHECKOUT=$(primary_checkout)
BRANCH=$(current_branch)

step() { printf '\n%snext%s → %s\n' "$_C_GREEN" "$_C_OFF" "$*" >&2; }
why() { printf '         %s\n' "$*" >&2; }

echo
printf '%s\n' "$BRANCH" >&2

# --- are you even in a position to start? -------------------------------------

if is_worker_branch "$BRANCH"; then
    why "this is a worker's worktree. it implements one slice and never orchestrates."
    step "cd $(worker_base "$(current_worktree)" || echo '<the feature worktree>')"
    exit 0
fi

if is_protected_branch "$BRANCH"; then
    why "workers are never cut from the trunk — their commits would be checked against"
    why "a branch they will never reach, so they could never be reaped."
    step "git checkout -b feat/<something>"
    exit 0
fi

FEATURE=$(branch_slug "$BRANCH")
DIR=$(slice_dir "$FEATURE")
PLAN="$DIR/plan.md"

TRUNK=""
for candidate in $BRAID_PROTECTED_BRANCHES; do
    git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$candidate" && {
        TRUNK="$candidate"
        break
    }
done
AHEAD=0
[[ -n "$TRUNK" ]] && AHEAD=$(git rev-list --count "$TRUNK..HEAD" 2>/dev/null || echo 0)

# --- design -------------------------------------------------------------------

SLICES=()
while read -r id; do
    [[ -n "$id" ]] || continue
    SLICES+=("$id")
done < <(BRAID_FEATURE="$FEATURE" list_slices "$FEATURE" 2>/dev/null || true)

if [[ "${#SLICES[@]}" -eq 0 ]]; then
    if [[ "$BRAID_SLICE_SOURCE" == github ]]; then
        why "no slices for '$FEATURE' in the tracker."
        why "a feature is a PRD issue and its sub-issues:  braid plan --prd <number>"
    else
        why "no slices in $BRAID_FEATURES_DIR/$FEATURE/."
    fi
    why "settle what you are building first. braid has no opinion about how — but it"
    why "will open the seat for you at the tier this repository calls 'design'."
    step "braid design      (then, in that session: /braid-plan)"
    exit 0
fi

# --- plan ---------------------------------------------------------------------

if [[ ! -f "$PLAN" ]]; then
    why "${#SLICES[@]} slices, no schedule."
    step "braid plan"
    exit 0
fi

PLAN_BODY=$(cat "$PLAN")
WAVES=()
while IFS= read -r line; do
    [[ "$line" =~ ^wave ]] && WAVES+=("$line")
done < <(slice_block "$PLAN_BODY")
[[ "${#WAVES[@]}" -gt 0 ]] || {
    why "$PLAN has no braid block — its wave schedule is missing."
    step "braid plan"
    exit 0
}

# Slices in the plan but not on disk, or the other way round. The plan is the intention
# and the folder is the fact; when they disagree, saying which is right is not braid's
# call to make silently.
PLANNED=""
for line in "${WAVES[@]}"; do
    PLANNED="$PLANNED $(printf '%s' "${line#*:}" | tr ',' ' ')"
done
DRIFT=""
for id in "${SLICES[@]}"; do
    case " $PLANNED " in *" $id "*) ;; *) DRIFT="$DRIFT $id" ;; esac
done
[[ -z "$DRIFT" ]] || {
    warn "slices not in the plan:$DRIFT — the schedule is out of date"
    why "braid plan is re-runnable; your Contracts and Traps survive it."
}

# --- where the waves are ------------------------------------------------------

# Asked in order of certainty. Integration is checked before the worktree, because a
# worker whose branch is already in the feature branch is done whether or not its
# worktree is still sitting there — and the earlier version, which looked at the
# worktree first, told you to integrate slices it had already integrated.
# The branch a plan id produced. In files mode the id is the slug; with a tracker the
# slug is the issue number plus its title, so the id is a prefix rather than the whole
# name. Matched against what exists rather than recomputed, which needs no network.
branch_for_id() {
    local id="${1:?id}" ref
    while read -r ref; do
        [[ -n "$ref" ]] || continue
        case "${ref#"$BRAID_BRANCH_PREFIX"/}" in
            "$id" | "$id"-*)
                printf '%s' "$ref"
                return 0
                ;;
        esac
    done < <(git -C "$CHECKOUT" for-each-ref --format='%(refname:short)' \
        "refs/heads/$BRAID_BRANCH_PREFIX/")
    printf '%s' "$(worker_branch "$(slugify "$id")")"
}

slice_state() {
    local id="${1:?id}" slug branch worktree
    branch=$(branch_for_id "$id")
    slug="${branch#"$BRAID_BRANCH_PREFIX"/}"
    worktree=$(worker_worktree_path "$slug")

    git -C "$CHECKOUT" show-ref --verify --quiet "refs/braid/landed/$id" && {
        printf 'done'
        return 0
    }

    if git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$branch"; then
        if git -C "$CHECKOUT" merge-base --is-ancestor "$branch" "$BRANCH" 2>/dev/null; then
            printf 'landed'
        elif [[ -d "$worktree" ]] && ! worker_is_terminal "$worktree"; then
            printf 'running'
        elif [[ -d "$worktree" ]]; then
            printf 'ready'
        else
            printf 'orphan'
        fi
        return 0
    fi
    printf 'todo'
}

echo >&2
RUNNING=()
READY=()
LANDED=()
TODO=()
NEXT_WAVE=""
for line in "${WAVES[@]}"; do
    label="${line%%:*}"
    counts=""
    for id in $(printf '%s' "${line#*:}" | tr ',' ' '); do
        [[ -n "$id" ]] || continue
        state=$(slice_state "$id")
        counts="$counts $state"
        case "$state" in
            running) RUNNING+=("$id") ;;
            ready) READY+=("$id") ;;
            landed) LANDED+=("$id") ;;
            orphan | todo)
                TODO+=("$id")
                [[ -n "$NEXT_WAVE" ]] || NEXT_WAVE="${label#wave }"
                ;;
        esac
    done
    summary=$(printf '%s' "$counts" | tr ' ' '\n' | grep -v '^$' | sort | uniq -c |
        awk '{printf "%s %s  ", $1, $2}')
    printf '  %-8s %s\n' "$label" "$summary" >&2
done

# --- what to do ---------------------------------------------------------------

if [[ "${#RUNNING[@]}" -gt 0 ]]; then
    why "${#RUNNING[@]} still working: ${RUNNING[*]}"
    step "braid wait          (then braid status --reports)"
    exit 0
fi

if [[ "${#READY[@]}" -gt 0 ]]; then
    why "${#READY[@]} finished and not integrated: ${READY[*]}"
    why "judge each against its diff, not its report, then:"
    step "braid integrate ${READY[0]}"
    exit 0
fi

if [[ "${#LANDED[@]}" -gt 0 ]]; then
    why "${#LANDED[@]} integrated and still holding a branch: ${LANDED[*]}"
    step "braid reap --merged"
    exit 0
fi

if [[ -n "$NEXT_WAVE" ]]; then
    why "${#TODO[@]} slices not started."
    # Said once, at the point where the seat changes. From inside the orchestrator this
    # is the command it runs itself, so repeating the suggestion later would be noise.
    if [[ -z "${BRAID_SEAT:-}" ]]; then
        why "the orchestrator runs the waves, in a session of its own."
        step "braid orchestrate      (or run it here: braid wave $NEXT_WAVE)"
    else
        step "braid wave $NEXT_WAVE"
    fi
    exit 0
fi

why "every slice in the plan is accounted for, and $AHEAD commits are on $BRANCH."
why "braid does not push or open pull requests — that timing is yours."
step "review the diff, push, and open the PR when you are ready"

# Only when the repository actually has something to tear down. A feature's shared
# resources — the database every `setup: yes` worker seeded into, a container — outlive
# every worker by design, so no reap has dropped them and nothing else will mention it.
if braid_overridden braid_teardown_feature; then
    echo >&2
    why "this repository defines braid_teardown_feature, and what it undoes is still up."
    step "braid reap --feature       once the PR has merged"
fi
