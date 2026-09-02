#!/usr/bin/env bash
# Tear a worker down, once its work is somewhere safe.
#
#   braid reap <slug>
#   braid reap --merged          every worker whose commits are in the branch it was cut from
#   braid reap --feature [slug]  what the whole feature provisioned, once it has landed
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
# shellcheck source=slice.sh
source "$BRAID_HOME/lib/slice.sh"

FORCE=0
MERGED=0
FEATURE=0
SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --merged)
            MERGED=1
            shift
            ;;
        --feature)
            FEATURE=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# --- the feature ---------------------------------------------------------------

# The branch a feature slug names. Scanned rather than reconstructed: feat/, fix/ and
# chore/ all slugify alike, so there is no way back from "auth" to "feat/auth" that does
# not involve looking.
feature_branch() {
    local want="${1:?slug}" ref
    while read -r ref; do
        [[ -n "$ref" ]] || continue
        is_worker_branch "$ref" && continue
        is_protected_branch "$ref" && continue
        [[ "$(branch_slug "$ref")" == "$want" ]] || continue
        printf '%s' "$ref"
        return 0
    done < <(git -C "$CHECKOUT" for-each-ref --format='%(refname:short)' refs/heads/)
    return 1
}

# The worktree a branch is checked out in, if any. The feature's own, normally — which
# is where its provisioning was done from and therefore what the teardown hook expects.
worktree_for_branch() {
    local want="${1:?branch}" worktree
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        [[ "$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)" == "$want" ]] || continue
        printf '%s' "$worktree"
        return 0
    done < <(git -C "$CHECKOUT" worktree list --porcelain | sed -n 's/^worktree //p')
    return 1
}

# The ids this feature's landed refs are filed under. Read from the plan *and* from the
# folder, because either alone is wrong at a predictable moment: a slice added after the
# last `braid plan` is not in the plan, and a slice whose file was deleted after it
# landed is not in the folder.
#
# Never from the tracker. `reap` does not reach the network — the whole point of the
# ancestry test below is that it answers from local refs — and a cleanup that needs `gh`
# to be logged in is a cleanup that fails on the one afternoon it matters.
feature_slice_ids() {
    local feature="${1:?feature}" dir plan line file
    {
        plan="$CHECKOUT/$BRAID_FEATURES_DIR/$feature/plan.md"
        if [[ -f "$plan" ]]; then
            while IFS= read -r line; do
                case "$line" in
                    wave*) printf '%s' "${line#*:}" | tr ',' '\n' ;;
                esac
            done < <(slice_block "$(cat "$plan")")
        fi
        dir="$CHECKOUT/$BRAID_FEATURES_DIR/$feature"
        for file in "$dir"/*.md; do
            [[ -f "$file" ]] || continue
            case "$(basename "$file" .md)" in
                prd | plan | README) ;;
                *) basename "$file" .md ;;
            esac
        done
    } | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | LC_ALL=C sort -u
}

# What outlives every worker: a database seeded once and shared by all of a feature's
# `setup: yes` workers, a container, a fixture store. No per-worker reap may drop it —
# the next serialized worker is cut from a tree that already contains the previous one's
# migrations — so it is dropped here, once, after the feature has landed.
#
# "Landed" is tested against the local trunk, exactly as reaping a worker tests it
# against its base. braid never fetches to find out: `git fetch` is the human's, and a
# tool that goes to the network to decide whether it may delete something is a tool that
# deletes on a stale answer.
reap_feature() {
    local slug="${1:-}" branch worktree trunk="" contained=0 unmerged live=""
    local candidate id ids removed=0

    if [[ -n "$slug" ]]; then
        branch=$(feature_branch "$slug") ||
            die "no local branch whose name slugifies to '$slug'"
    else
        branch=$(current_branch)
        is_protected_branch "$branch" &&
            die "'$branch' is the trunk. stand on the feature branch, or name it: braid reap --feature <slug>"
        slug=$(branch_slug "$branch")
    fi

    # Workers first, and this is not merely tidiness: braid_teardown_feature undoes what
    # a still-running worker is using, and a worker reaped afterwards would run its own
    # teardown against a resource that no longer exists.
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        [[ "$(worker_base "$worktree")" == "$branch" ]] || continue
        live="$live $(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    done < <(worker_worktrees all)
    [[ -z "$live" ]] || die "$(printf '%s\n' \
        "workers are still off $branch:$live" \
        "  integrate what is finished, then:  braid reap --merged")"

    # The first protected branch that exists is what "landed" is measured against; if one
    # of them contains the feature, that is the one reported to the hook as its base.
    for candidate in $BRAID_PROTECTED_BRANCHES; do
        git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$candidate" || continue
        [[ -n "$trunk" ]] || trunk="$candidate"
        if git -C "$CHECKOUT" merge-base --is-ancestor "$branch" "$candidate" 2>/dev/null; then
            trunk="$candidate"
            contained=1
            break
        fi
    done

    if [[ "$contained" -eq 0 ]]; then
        unmerged=$(git -C "$CHECKOUT" rev-list --count "${trunk:-HEAD}..$branch" 2>/dev/null || echo '?')
        if [[ "$FORCE" -eq 0 ]]; then
            die "$(printf '%s\n' \
                "$branch has $unmerged commits that are not in ${trunk:-the trunk} yet." \
                "  the PR has not merged, or you have not fetched it. braid never looks:" \
                "    git fetch && git checkout ${trunk:-main} && git pull" \
                "  or tear it down anyway:  braid reap --feature --force")"
        fi
        warn "$branch: $unmerged commits are not in ${trunk:-the trunk} yet (--force)"
    fi

    worktree=$(worktree_for_branch "$branch") || worktree="$CHECKOUT"

    if braid_overridden braid_teardown_feature; then
        note "braid_teardown_feature $slug"
        braid_teardown_feature "$worktree" "$slug" "${trunk:-}" ||
            warn "braid_teardown_feature failed — the refs below were still cleaned"
    else
        info "no braid_teardown_feature in braid.sh — nothing of this feature's to undo"
    fi

    # The last braid-owned state a finished feature leaves behind. Kept until now
    # because `braid next` reads them to know a slice was built rather than never
    # started; once the feature is in the trunk there is nothing left to be unsure about.
    ids=$(feature_slice_ids "$slug")
    for id in $ids; do
        git -C "$CHECKOUT" show-ref --verify --quiet "refs/braid/landed/$id" || continue
        git -C "$CHECKOUT" update-ref -d "refs/braid/landed/$id" &&
            removed=$((removed + 1))
    done
    ok "reaped the feature $slug ($removed landed refs)"
}

if [[ "$FEATURE" -eq 1 ]]; then
    [[ "$MERGED" -eq 0 ]] || die "--feature and --merged are different jobs — run them one at a time"
    reap_feature "$SLUG"
    exit 0
fi

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

[[ -n "$SLUG" ]] || die "usage: braid reap <slug> | braid reap --merged | braid reap --feature"
SLUG="${SLUG#"$BRAID_BRANCH_PREFIX"/}"
WORKTREE=$(worker_worktree_path "$SLUG")
[[ -d "$WORKTREE" ]] || die "no worker worktree at $WORKTREE"
reap_one "$WORKTREE"
