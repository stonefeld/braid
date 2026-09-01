#!/usr/bin/env bash
# Launch one worker on one slice, in its own worktree.
#
#   braid spawn <path/to/slice.md> [options]
#
#     --complexity low|standard|high   how much judgement the work needs
#     --model NAME                     override the model the adapter would pick
#     --agent NAME                     override the agent for this worker
#     --base BRANCH                    what to cut from   (default: the branch you are on)
#     --setup / --no-setup             force or skip the expensive provision path
#     --no-launch                      make the worktree, start nothing
#     --prompt TEXT                    replace the launch prompt entirely
#
# Run it from the feature branch you are integrating into. The base is whatever branch
# you are standing on, so a worker spawned after a wave has landed already contains
# that wave's work.

set -euo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"
# shellcheck source=env.sh
source "$BRAID_HOME/lib/env.sh"
# shellcheck source=launcher.sh
source "$BRAID_HOME/lib/launcher.sh"
# shellcheck source=slice.sh
source "$BRAID_HOME/lib/slice.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; }

SLICE=""
COMPLEXITY=""
MODEL=""
BASE=""
BASE_EXPLICIT=0
NEEDS_SETUP=""
LAUNCH=1
PROMPT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --complexity)
            COMPLEXITY="${2:?--complexity needs a level}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        --agent)
            # Read back by agent_resolve through indirect expansion of the seat name,
            # which is why it is exported rather than passed.
            export BRAID_AGENT_WORK="${2:?--agent needs a name}"
            shift 2
            ;;
        --base)
            BASE="${2:?--base needs a branch}"
            BASE_EXPLICIT=1
            shift 2
            ;;
        --setup)
            NEEDS_SETUP=1
            shift
            ;;
        --no-setup)
            NEEDS_SETUP=0
            shift
            ;;
        --no-launch)
            LAUNCH=0
            shift
            ;;
        --prompt)
            PROMPT_OVERRIDE="${2:?--prompt needs text}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            SLICE="$1"
            shift
            ;;
    esac
done

[[ -n "$SLICE" ]] || {
    usage
    die "which slice?"
}
[[ -f "$SLICE" ]] || die "no such slice: $SLICE"

braid_config
refuse_worker_seat
agent_load work

CHECKOUT=$(primary_checkout)
# The worktree this was run from — the feature's, when you are sitting where you should
# be. orca hangs the worker's card off it; every other launcher ignores it.
PARENT_WORKTREE=$(current_worktree)
BASE="${BASE:-$(current_branch)}"
[[ "$BASE_EXPLICIT" -eq 1 ]] || refuse_trunk_base "$BASE"

BODY=$(cat "$SLICE")
[[ -n "$BODY" ]] || die "$SLICE is empty"
SLICE_ID=$(basename "$SLICE" .md)

# The braid block is the source; the flags override it. Validated whole rather than read
# key by key, so a typo is reported as a typo instead of silently reading as an absence.
slice_validate "$BODY"
[[ -n "$COMPLEXITY" ]] || COMPLEXITY=$(slice_complexity "$BODY")
[[ -n "$NEEDS_SETUP" ]] || NEEDS_SETUP=$(slice_setup "$BODY")

# The model resolves through complexity, never through a brand name in the slice.
# --model is the escape hatch for the one case the mapping gets wrong.
if [[ -z "$MODEL" ]]; then
    MODEL=$(agent_complexity "$COMPLEXITY")
fi
agent_check_model "$MODEL"

SLUG=$(slugify "$SLICE_ID")
BRANCH=$(worker_branch "$SLUG")
WORKTREE=$(worker_worktree_path "$SLUG")

[[ -e "$WORKTREE" ]] && die "$WORKTREE already exists — reap it first"
git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$BRANCH" &&
    die "branch $BRANCH already exists — reap it first"

# Anything that fails between here and launch leaves a worktree that cannot be used and
# that blocks the retry, so unwind it and let the command simply be run again.
CREATED=""
unwind() {
    local status=$?
    if [[ $status -ne 0 && -n "$CREATED" ]]; then
        note "spawn failed — removing the half-made worktree so you can run it again"
        braid_teardown "$CREATED" "$SLUG" >/dev/null 2>&1 || true
        git -C "$CHECKOUT" worktree remove --force "$CREATED" >/dev/null 2>&1 || true
        git -C "$CHECKOUT" branch -D "$BRANCH" >/dev/null 2>&1 || true
    fi
}
trap unwind EXIT

note "worktree $WORKTREE off $BASE ($BRAID_AGENT_RESOLVED${MODEL:+ $MODEL}, setup: $NEEDS_SETUP)"
mkdir -p "$(dirname "$WORKTREE")"
git -C "$CHECKOUT" worktree add -b "$BRANCH" "$WORKTREE" "$BASE" >/dev/null
CREATED="$WORKTREE"

# What the orchestrator later reads back. The base especially: it cannot be
# reconstructed from the slug, and reap checks the worker's commits against it before
# deleting anything.
mkdir -p "$WORKTREE/.braid"

# Excluded per worktree, not left to the project's .gitignore. .braid/ is braid's own
# scratch space — the slice, the report, the session log — and if a worker can commit it
# then every worker in a wave commits a different version of the same paths, and every
# integration after the first one conflicts on files the slice never mentioned. That is
# a baffling failure, and it would depend on whether somebody had run setup.
# The common directory, not the worktree's own: git does not read info/exclude from a
# linked worktree's git dir, only from the shared one. Checked, not assumed.
EXCLUDE=$(git -C "$WORKTREE" rev-parse --git-common-dir)
[[ "$EXCLUDE" = /* ]] || EXCLUDE="$WORKTREE/$EXCLUDE"
EXCLUDE="$EXCLUDE/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF '.braid/' "$EXCLUDE" 2>/dev/null || printf '.braid/\n' >>"$EXCLUDE"
printf '%s' "$BASE" >"$WORKTREE/.braid/base"
printf '%s' "$SLICE_ID" >"$WORKTREE/.braid/slice-id"
printf '%s' "$BRAID_AGENT_RESOLVED" >"$WORKTREE/.braid/agent"
printf '%s' "$MODEL" >"$WORKTREE/.braid/model"
printf '%s' "$COMPLEXITY" >"$WORKTREE/.braid/complexity"
printf '%s' "$(braid_version)" >"$WORKTREE/.braid/braid-version"
printf '%s\n' "$BODY" >"$WORKTREE/.braid/slice.md"

# Copied in, not referenced: this is what writes .braid/status when the agent exits, and
# it has to work in a worktree that knows nothing about where braid is installed.
cp "$BRAID_HOME/lib/finish.sh" "$WORKTREE/.braid/finish.sh"
chmod +x "$WORKTREE/.braid/finish.sh"

# Materialising the slice here is what lets the no-network rule be absolute: a worker
# never needs the tracker, or anything else, to know what it is building.
braid_provision "$WORKTREE" "$SLUG" "$BASE" "$NEEDS_SETUP" ||
    die "braid_provision failed for $WORKTREE"

if [[ "$LAUNCH" -eq 0 ]]; then
    note "ready, not launched — cd $WORKTREE"
    CREATED=""
    exit 0
fi

# Past here the worktree is complete and usable, so a launch failure is something to
# report and leave alone rather than to unwind.
CREATED=""

if [[ -n "$PROMPT_OVERRIDE" ]]; then
    PROMPT="$PROMPT_OVERRIDE"
else
    PROMPT="$(
        printf '# Your assigned slice\n\n'
        cat "$WORKTREE/.braid/slice.md"
        printf '\n\n---\n\nImplement it completely. It is also on disk at .braid/slice.md.\n'
    )"
fi

# orca hangs the worker's card off whichever worktree spawned it — the feature's, when
# you are sitting where you should be.
export BRAID_PARENT_WORKTREE="$PARENT_WORKTREE"

read -r LAUNCHER CERTAINTY < <(launcher_resolve)
launcher_load "$LAUNCHER"

build_command() {
    local agent_command
    if launcher_headless; then
        agent_command=$(agent_cmd_headless "$WORKTREE" "$MODEL" "$PROMPT")
    else
        agent_command=$(agent_cmd "$WORKTREE" "$MODEL" "$PROMPT")
    fi
    # finish.sh runs whatever happened to the agent — a clean exit, a crash, a CLI that
    # was never installed. It is what makes the control plane independent of hooks.
    printf 'cd %q && { %s; }; bash .braid/finish.sh %q' "$WORKTREE" "$agent_command" "$WORKTREE"
}

try_launch() {
    local name="${1:?name}"
    launcher_load "$name"
    note "launching in $name ($CERTAINTY)"
    launcher_launch "$WORKTREE" "$BRAID_BRANCH_PREFIX-$SLUG" "$(build_command)"
}

if try_launch "$LAUNCHER"; then
    printf '%s' "$LAUNCHER" >"$WORKTREE/.braid/launcher"
    note "watch it with: braid status"
    exit 0
fi

# Guessing wrong is not a failure — the list exists to be walked. Only where braid was
# *told* where to go is there nowhere else to legitimately go.
if [[ "$CERTAINTY" == inferred ]]; then
    while read -r NEXT; do
        [[ -n "$NEXT" && "$NEXT" != "$LAUNCHER" ]] || continue
        if try_launch "$NEXT"; then
            printf '%s' "$NEXT" >"$WORKTREE/.braid/launcher"
            note "watch it with: braid status"
            exit 0
        fi
    done < <(launcher_candidates)
fi

# It failed. What that means depends on who is reading, and braid can tell: a person
# sitting in front of it has a terminal, an orchestrator calling through a tool does not.
{
    printf 'launcher:  %s (%s)\n' "$LAUNCHER" "$CERTAINTY"
    printf 'file:      %s\n' "${BRAID_LAUNCHER_FILE:-?}"
    printf 'last call: %s\n' "${BRAID_LAUNCHER_PROBE:-unknown}"
} >"$WORKTREE/.braid/launch-error.log"

# Strict everywhere braid was told where to go, never where it merely guessed — there,
# guessing again is the entire point.
STRICT=0
[[ "$CERTAINTY" != inferred ]] && STRICT=1
[[ "${BRAID_LAUNCHER_STRICT:-0}" == 1 ]] && STRICT=1

if [[ "$STRICT" -eq 1 && -t 2 ]]; then
    # You are here. Stopping costs thirty seconds; putting the worker somewhere you are
    # not looking costs the twenty minutes it takes to notice.
    warn "$(printf '%s\n' \
        "the worktree is ready. braid could not open it in $LAUNCHER." \
        "" \
        "  what it needed:  run the agent, visibly, in $WORKTREE" \
        "  last call:       ${BRAID_LAUNCHER_PROBE:-unknown}" \
        "" \
        "  by hand:      cd $WORKTREE && $(agent_cmd "$WORKTREE" "$MODEL" 'the slice is in .braid/slice.md')" \
        "  teach braid:  ${XDG_CONFIG_HOME:-$HOME/.config}/braid/launchers/$LAUNCHER.sh")"
    exit 4
fi

# Nobody is watching this call, so stopping a wave over a panel is the wrong trade.
# Continue detached and make the degradation permanent in status rather than a warning
# that scrolls past — the orchestrator sees it on every check and reports it.
warn "$LAUNCHER failed to launch — continuing detached, see .braid/launch-error.log"
printf 'detached (%s failed)' "$LAUNCHER" >"$WORKTREE/.braid/launcher"
launcher_load detached
launcher_launch "$WORKTREE" "$BRAID_BRANCH_PREFIX-$SLUG" "$(build_command)"
note "watch it with: braid status"
