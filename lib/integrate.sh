#!/usr/bin/env bash
# Weave one worker's branch into the feature branch.
#
#   braid integrate <slug>
#   braid integrate --continue <slug>     after resolving a rebase conflict
#   braid integrate --abort <slug>        put the worker back where it was
#
#     --no-verify     skip the project's gate  (say why in your summary)
#
# rebase, then merge --ff-only, so the feature branch reads as though every commit had
# been written on it in order. That is the braid: parallel strands, one rope.
#
# The split is judgement versus mechanics. Deciding whether a diff matches its report
# and meets its acceptance criteria is irreducibly judgement, and is why the orchestrator
# is an expensive seat. This sequence is not: it is four commands in a fixed order, run
# four times a wave from memory, where the intermediate verify is the one that gets
# skipped.
#
# On trouble it **stops in a resolvable state** rather than undoing anything — the
# contract `git rebase` already established, and the reason the orchestrator does not
# lose the conflict it is best placed to resolve.

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"

MODE=integrate
VERIFY=1
SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --continue)
            MODE=continue
            shift
            ;;
        --abort)
            MODE=abort
            shift
            ;;
        --no-verify)
            VERIFY=0
            shift
            ;;
        -h | --help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            SLUG="$1"
            shift
            ;;
    esac
done

braid_config
refuse_worker_seat
[[ -n "$SLUG" ]] || die "usage: braid integrate <slug>"
# Stripped here, not while parsing arguments: the prefix is configuration, and
# braid_config has not run yet at that point.
SLUG="${SLUG#"$BRAID_BRANCH_PREFIX"/}"

FEATURE=$(current_branch)
BRANCH=$(worker_branch "$SLUG")
WORKTREE=$(worker_worktree_path "$SLUG")
[[ -d "$WORKTREE" ]] || die "no worker worktree at $WORKTREE"

rebase_in_progress() {
    local dir
    for dir in rebase-merge rebase-apply; do
        [[ -d "$(git -C "$WORKTREE" rev-parse --git-path "$dir")" ]] && return 0
    done
    return 1
}

conflicted_files() {
    git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null
}

stop_on_conflict() {
    warn "$(printf '%s\n' \
        "rebase stopped on a conflict. it is still in progress, in the worker's worktree —" \
        "which is where its context is, and where you can see what it was trying to do." \
        "" \
        "  worktree:  $WORKTREE" \
        "  conflicts:" \
        "$(conflicted_files | sed 's/^/    /')" \
        "" \
        "  resolve there, git add, then:  braid integrate --continue $SLUG" \
        "  or give up on this one:        braid integrate --abort $SLUG")"
    exit 2
}

case "$MODE" in
    abort)
        rebase_in_progress || die "no rebase in progress in $WORKTREE"
        git -C "$WORKTREE" rebase --abort || die "could not abort the rebase in $WORKTREE"
        note "aborted — $BRANCH is back where it was"
        exit 0
        ;;
    continue)
        rebase_in_progress || die "no rebase in progress in $WORKTREE"
        [[ -z "$(conflicted_files)" ]] ||
            die "$(printf '%s\n' \
                "there are still unmerged files in $WORKTREE:" \
                "$(conflicted_files | sed 's/^/  /')" \
                "resolve them and git add them first.")"
        # GIT_EDITOR, or --continue opens one and hangs a command nobody is watching.
        GIT_EDITOR=true git -C "$WORKTREE" rebase --continue || stop_on_conflict
        note "rebase completed"
        ;;
    integrate)
        rebase_in_progress &&
            die "a rebase is already in progress in $WORKTREE — braid integrate --continue $SLUG"

        # Refused before anything moves. A rebase does not carry a working tree, so
        # uncommitted work is not merely left behind — it is left behind while the
        # branch's history moves out from under it.
        if [[ -n "$(git -C "$WORKTREE" status --porcelain -- ':!.braid' 2>/dev/null)" ]]; then
            die "$(printf '%s\n' \
                "$BRANCH has uncommitted changes. a rebase would leave them stranded." \
                "$(git -C "$WORKTREE" status --short -- ':!.braid' | sed 's/^/  /')" \
                "send the worker back to commit them, or commit them yourself.")"
        fi

        ahead=$(git -C "$WORKTREE" rev-list --count "$FEATURE..$BRANCH" 2>/dev/null || echo 0)
        [[ "$ahead" -gt 0 ]] ||
            die "$BRANCH has no commits that $FEATURE does not — nothing to integrate"

        note "rebasing $BRANCH onto $FEATURE ($ahead commits)"
        GIT_EDITOR=true git -C "$WORKTREE" rebase "$FEATURE" || stop_on_conflict
        ;;
esac

# Fast-forward only, always. A merge commit here would be braid failing at the one thing
# it is named after: if the feature branch cannot fast-forward, the rebase did not
# actually finish, and finding that out as a merge commit is finding out too late.
note "fast-forwarding $FEATURE"
git merge --ff-only "$BRANCH" >/dev/null ||
    die "$FEATURE would not fast-forward to $BRANCH — the rebase did not leave it linear"

HEAD_NOW=$(git rev-parse --short HEAD)
ok "$FEATURE is at $HEAD_NOW"

if [[ "$VERIFY" -eq 0 ]]; then
    warn "gate skipped (--no-verify) — say so in your summary"
    note "next: braid reap $SLUG"
    exit 0
fi

# After every fast-forward, not only the last. Two changes that each pass alone can fail
# together, and running the gate once at the end tells you that something broke without
# telling you which merge did it.
if bash "$BRAID_HOME/lib/verify.sh"; then
    note "next: braid reap $SLUG"
    exit 0
fi

warn "$(printf '%s\n' \
    "$FEATURE is broken, and the merge that broke it is the one just made ($SLUG)." \
    "" \
    "  not reaping — $BRANCH still exists and its worktree is intact." \
    "  fix it on $FEATURE in its own commit, or:  git reset --hard $HEAD_NOW^")"
exit 5
