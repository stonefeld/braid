#!/usr/bin/env bash
# Tear a worker down, once its work is somewhere safe.
#
#   braid reap <slug>
#   braid reap --merged        every worker whose commits are in the branch it was cut from
#
#     --force     delete it anyway, and say what is being lost
#
# The check is against **the branch the worker was cut from**, recorded in .braid/base at
# spawn — never against whatever branch you happen to be standing on.
#
# That distinction is the whole of this file. `git branch -d` asks "is this merged into
# HEAD?", so reaping from the primary checkout, sitting on the trunk as anyone would,
# refuses to delete a branch that is perfectly well integrated into the feature branch —
# and reports it as unmerged, which is alarming and wrong. The tempting fix is to reach
# for -D, which does not fix the check, it removes it. So braid runs the ancestry test
# itself, against the right branch, and only then forces.

set -uo pipefail

# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"
# shellcheck source=launcher.sh
source "$BRAID_HOME/lib/launcher.sh"

FORCE=0
MERGED=0
SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --merged)
            MERGED=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
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
CHECKOUT=$(primary_checkout)

# Every commit on the worker's branch is already contained in the branch it was cut
# from. Asked of git directly, so a rebase-then-fast-forward — where the commits are the
# same content under different hashes — answers correctly.
is_integrated() {
    local branch="${1:?branch}" base="${2:?base}"
    git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$base" || return 1
    git -C "$CHECKOUT" merge-base --is-ancestor "$branch" "$base" 2>/dev/null
}

reap_one() {
    local worktree="${1:?worktree}" branch base slug unmerged launcher recorded

    branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) ||
        die "$worktree is not a git worktree"
    slug="${branch#"$BRAID_BRANCH_PREFIX"/}"
    base=$(worker_base "$worktree")
    [[ -n "$base" ]] ||
        die "$worktree has no .braid/base — it was not made by braid, reap it by hand"

    if ! is_integrated "$branch" "$base"; then
        unmerged=$(git -C "$CHECKOUT" rev-list --count "$base..$branch" 2>/dev/null || echo '?')
        if [[ "$FORCE" -eq 0 ]]; then
            die "$(printf '%s\n' \
                "$branch has $unmerged commits that are not in $base yet." \
                "  integrate it first:  braid integrate $slug" \
                "  or lose them:        braid reap $slug --force" \
                "" \
                "  (checked against $base, the branch it was cut from — not against" \
                "   $(current_branch), which is where you happen to be standing.)")"
        fi
        warn "$branch: losing $unmerged commits that are not in $base (--force)"
    fi

    # Read before anything is removed. Everything below destroys the worktree, and the
    # id the plan uses lives inside it — reading it afterwards silently fell back to the
    # branch slug, which is a different string as soon as a tracker is involved.
    recorded=$(worker_field "$worktree" slice-id)

    # Outside the worktree first, while everything that names it still exists.
    braid_teardown "$worktree" "$slug" >/dev/null 2>&1 || true

    # Checked before loading, never guarded with 2>/dev/null. launcher_load dies when
    # there is no such launcher — and a worker spawned with --no-launch has no
    # .braid/launcher at all — so the guarded form swallowed the message *and* the
    # command, and reap exited silently having done nothing.
    launcher=$(worker_field "$worktree" launcher | sed 's/ .*//')
    if [[ -n "$launcher" ]] && launcher_file "$launcher" >/dev/null 2>&1; then
        launcher_load "$launcher"
        launcher_forget "$worktree" >/dev/null 2>&1 || true
    fi

    git -C "$CHECKOUT" worktree remove --force "$worktree" ||
        die "could not remove $worktree"

    # The branch becomes a ref under refs/braid/landed/ before it is deleted. Deleting
    # it outright destroys the only evidence that this slice was ever built: afterwards
    # a slice with no branch and no worktree is indistinguishable from one that never
    # started, and `braid next` would call a wave finished that had not begun.
    #
    # A ref rather than a branch, so it stays out of `git branch`, out of the way, and
    # still answers "what commit did this slice land as" months later.
    if [[ "$FORCE" -eq 0 ]]; then
        # Keyed on the id the plan uses — the filename in files mode, the issue number
        # with a tracker — not on the branch slug, which also carries the issue's title.
        # Keying on the slug made `next` report integrated work as never started.
        git -C "$CHECKOUT" update-ref "refs/braid/landed/${recorded:-$slug}" "$branch" ||
            warn "could not record that $slug landed — braid next will call it unstarted"
    fi
    # -D, not -d: the ancestry check above already answered the question -d asks, and
    # answered it against the right branch.
    git -C "$CHECKOUT" branch -D "$branch" >/dev/null ||
        die "removed $worktree but could not delete $branch"

    ok "reaped $slug"
}

if [[ "$MERGED" -eq 1 ]]; then
    found=0
    reaped=0
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        found=1
        branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
        base=$(worker_base "$worktree")
        if [[ -n "$base" ]] && is_integrated "$branch" "$base"; then
            reap_one "$worktree"
            reaped=$((reaped + 1))
        else
            info "${branch#"$BRAID_BRANCH_PREFIX"/}: not integrated into ${base:-?}, left alone"
        fi
    done < <(worker_worktrees mine)
    [[ "$found" -eq 1 ]] || note "no workers off $(current_branch)"
    note "reaped $reaped"
    exit 0
fi

[[ -n "$SLUG" ]] || die "usage: braid reap <slug> | braid reap --merged"
SLUG="${SLUG#"$BRAID_BRANCH_PREFIX"/}"
WORKTREE=$(worker_worktree_path "$SLUG")
[[ -d "$WORKTREE" ]] || die "no worker worktree at $WORKTREE"
reap_one "$WORKTREE"
