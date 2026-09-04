#!/usr/bin/env bash
# Launch one worker on one slice, in its own worktree.
#
#   braid spawn <slice> [options]
#
# A slice is a path, or an id the configured source understands — a filename in the
# feature's folder, or an issue number.
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
# shellcheck source=contract.sh
source "$BRAID_HOME/lib/contract.sh"
# shellcheck source=env.sh
source "$BRAID_HOME/lib/env.sh"
# shellcheck source=launcher.sh
source "$BRAID_HOME/lib/launcher.sh"
# shellcheck source=source.sh
source "$BRAID_HOME/lib/source.sh"

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

braid_config
refuse_worker_seat
agent_load work

CHECKOUT=$(primary_checkout)
# The worktree this was run from — the feature's, when you are sitting where you should
# be. orca hangs the worker's card off it; every other launcher ignores it.
PARENT_WORKTREE=$(current_worktree)
BASE="${BASE:-$(current_branch)}"
[[ "$BASE_EXPLICIT" -eq 1 ]] || refuse_trunk_base "$BASE"

# The feature is the branch, which is how a bare id resolves without being told where
# to look.
export BRAID_FEATURE="${BRAID_FEATURE:-$(branch_slug "$BASE")}"
BODY=$(fetch_slice "$SLICE")
[[ -n "$BODY" ]] || die "slice '$SLICE' is empty"
# Two names, and they are not the same thing. The **id** is what the plan calls this
# slice — a filename, or an issue number — and it is what every later command looks it up
# by. The **slug** is what the branch and worktree are called, which for an issue takes
# the title too, because `agent/2` names nothing a person can read.
#
# Recording the slug as the id made reap file the landed marker under a name next could
# not find, so a wave that had integrated and been reaped read as never started.
if [[ -f "$SLICE" ]]; then
    SLICE_ID=$(basename "$SLICE" .md)
    SLUG=$(slugify "$SLICE_ID")
else
    SLICE_ID="$SLICE"
    SLUG=$(slugify "$(slice_display_id "$SLICE")")
fi

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

exclude_braid_dir "$WORKTREE"
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

# Composed here and nowhere else: the bundled contract, plus this repository's
# docs/worker-rules.md, or its docs/worker-contract.md replacing both. An agent with no
# hooks reads this file from its prompt and one with hooks reads it from the session
# hook, so both are reading the same bytes rather than repeating the same lookup.
contract_compose "$CHECKOUT" >"$WORKTREE/.braid/contract.md"

# The only thing standing between an agent with no hooks and the remote.
install_push_guard "$WORKTREE"

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

# The contract is the one thing a worker must not be able to miss, so it is delivered
# twice over depending on what the agent can do.
#
# An agent with a session hook gets it before its first turn, and the prompt only has to
# point at the slice — but it still restates the two rules whose absence costs something,
# because a headless run is one turn long and a worker that finishes without committing
# has done work nobody can integrate. That is not hypothetical: it is what the first real
# wave did.
#
# An agent without hooks gets the whole contract inline. Nothing else would ever give it
# one, which is the difference between "works with any agent CLI" and "works with Claude".
if [[ -n "$PROMPT_OVERRIDE" ]]; then
    PROMPT="$PROMPT_OVERRIDE"
elif agent_injects_contract; then
    PROMPT="$(
        printf '# Your assigned slice\n\n'
        cat "$WORKTREE/.braid/slice.md"
        printf '%s\n' \
            '' '---' '' \
            'Implement it completely. Your operating contract was loaded at the start of' \
            'this session; follow it exactly. Two parts of it are not advice:' \
            '' \
            '  - You never touch the remote. No push, no gh, no PRs.' \
            '  - You commit everything before you finish, and you write .braid/report.md.' \
            '    Your working tree is never read by anyone. Uncommitted work is lost work.' \
            '' \
            'The slice is also on disk at .braid/slice.md.'
    )"
else
    PROMPT="$(
        cat "$WORKTREE/.braid/contract.md"
        printf '\n\n---\n\n# Your assigned slice\n\n'
        cat "$WORKTREE/.braid/slice.md"
        printf '%s\n' \
            '' '---' '' \
            'Implement the slice above, completely. The contract that precedes it is not' \
            'advice. Both are also on disk, at .braid/contract.md and .braid/slice.md.'
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
