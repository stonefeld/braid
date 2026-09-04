#!/usr/bin/env bash
# The repository: where it is, what branch you are on, which worktrees are workers.
#
# braid never writes down where you are. Every answer here is derived from git at the
# moment it is asked, because in this workflow people do things by hand — cut a branch
# in another terminal, kill a worker, delete a worktree — and a recorded location is
# wrong the first time they do.

[[ -n "${_BRAID_GIT_SH:-}" ]] && return 0
_BRAID_GIT_SH=1

# shellcheck source=core.sh
source "$BRAID_HOME/lib/core.sh"

# --- where we are -------------------------------------------------------------

# The primary checkout — the one clone every worktree hangs off. Resolved through
# --git-common-dir, which answers the same from inside any worktree, so a command run
# in a worker finds the same repository as one run in the feature branch.
primary_checkout() {
    local common
    common=$(git rev-parse --git-common-dir 2>/dev/null) || die "not inside a git repository"
    [[ "$common" = /* ]] || common="$(pwd)/$common"
    cd "$(dirname "$common")" && pwd
}

# The worktree the command was run from, which is a different question.
current_worktree() {
    git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

repo_name() {
    basename "$(primary_checkout)"
}

current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null || die "not inside a git repository"
}

# --- names --------------------------------------------------------------------

slugify() {
    printf '%s' "$1" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' |
        cut -c1-48
}

# "feat/checkout-flow" -> "checkout-flow"
branch_slug() {
    local branch="${1:?branch}"
    slugify "${branch#*/}"
}

worker_branch() {
    printf '%s/%s' "$BRAID_BRANCH_PREFIX" "${1:?slug}"
}

worker_worktree_path() {
    printf '%s/%s-%s' "$BRAID_WORKTREE_ROOT" "$BRAID_BRANCH_PREFIX" "${1:?slug}"
}

# --- protection ---------------------------------------------------------------

is_protected_branch() {
    local branch="${1:?branch}" protected
    for protected in $BRAID_PROTECTED_BRANCHES; do
        [[ "$branch" == "$protected" ]] && return 0
    done
    return 1
}

is_worker_branch() {
    [[ "${1:?branch}" == "$BRAID_BRANCH_PREFIX/"* ]]
}

# Orchestration runs from the feature branch. Run from inside a worker, commands like
# `wave` would cut workers off a worker, and `integrate` would fast-forward the wrong
# branch — both recoverable, neither obvious for an hour.
refuse_worker_seat() {
    is_worker_branch "$(current_branch)" &&
        die "this is a worker worktree — orchestration runs from the feature branch"
    return 0
}

# A worker cut from the trunk is not merely based on the wrong tree: its commits are
# checked against that base before it can be reaped, and for mid-feature work they will
# never reach the trunk, so it can never be cleaned up. Nearly always it means the
# command was run in the primary checkout by mistake.
refuse_trunk_base() {
    local base="${1:?base}"
    is_protected_branch "$base" && die "$(
        printf '%s' \
            "refusing to cut a worker from '$base' — you are probably in the primary checkout " \
            "rather than a feature worktree. cd to the feature worktree, or pass --base $base " \
            "if you mean it (reap will then hold the worker until its commits reach $base)."
    )"
    return 0
}

# --- .braid/, in any worktree braid works in -----------------------------------

# Excluded per repository, not left to the project's .gitignore. .braid/ is braid's own
# scratch space — the slice, the report, the session log, whatever an agent was told to
# write there — and if it can be committed then every worker in a wave commits a
# different version of the same paths, and every integration after the first conflicts on
# files no slice mentioned. That is a baffling failure, and it would depend on whether
# somebody had run setup.
#
# The common directory, not the worktree's own: git does not read info/exclude from a
# linked worktree's git dir, only from the shared one. Checked, not assumed.
exclude_braid_dir() {
    local worktree="${1:?worktree}" exclude
    exclude=$(git -C "$worktree" rev-parse --git-common-dir) || return 0
    [[ "$exclude" = /* ]] || exclude="$worktree/$exclude"
    exclude="$exclude/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    grep -qxF '.braid/' "$exclude" 2>/dev/null || printf '.braid/\n' >>"$exclude"
}

# The seat's own .braid/. Workers get one at spawn; the design and orchestrator seats got
# nothing, and the contract they run under says "anything that might take minutes goes to
# a file under .braid/". An agent told that, in a worktree with no such directory,
# improvises — one real run left forty `.braid-verify-<slug>.log` files and 1.1 MB beside
# the checkout, which `.gitignore`'s `.braid/` does not match and `git add -A` would have
# swept in.
#
# Created rather than documented: the directory existing is what makes the instruction
# true, and no amount of wording in a skill substitutes for it.
ensure_seat_dir() {
    local worktree="${1:?worktree}"
    mkdir -p "$worktree/.braid"
    exclude_braid_dir "$worktree"
}

# --- the push guard -----------------------------------------------------------

# An agent without a PreToolUse hook cannot be stopped mid-session from running
# `git push`. A per-worktree pre-push hook can, and git enforces it, so it is
# agent-agnostic by construction — which makes it the only remote protection that exists
# for Codex, for generic, and for whatever comes next.
#
# Per worktree rather than repository-wide, so the human's own checkout keeps whatever
# hooks it had. `--no-verify` bypasses it, and that is correct: this guards against an
# agent doing it by reflex, not against a person who means it.
install_push_guard() {
    local worktree="${1:?worktree}" checkout
    [[ "${BRAID_PUSH_GUARD:-1}" == 1 ]] || return 0
    checkout=$(primary_checkout)

    # Per-worktree config has to be enabled on the repository before a worktree can have
    # any. Enabling it changes nothing on its own.
    git -C "$checkout" config extensions.worktreeConfig true 2>/dev/null || {
        warn "could not enable per-worktree config — no push guard in $worktree"
        return 0
    }
    git -C "$worktree" config --worktree core.hooksPath .braid/githooks 2>/dev/null || {
        warn "could not set a per-worktree hooksPath — no push guard in $worktree"
        return 0
    }

    mkdir -p "$worktree/.braid/githooks"
    cat >"$worktree/.braid/githooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
cat >&2 <<'MSG'
Workers do not push. Commit locally and write .braid/report.md — the orchestrator
rebases your branch onto the feature branch and handles everything remote.

A pushed worker branch has to be cleaned up by hand, and an opened pull request starts
CI that re-runs on every later push. That timing is the human's call, not yours.
MSG
exit 1
HOOK
    chmod +x "$worktree/.braid/githooks/pre-push"
}

# --- worker worktrees ---------------------------------------------------------

# The base a worker was cut from, recorded in full at spawn. Never reconstructed from
# the slug: feat/, fix/ and chore/ all slugify alike, and a wrong answer here makes
# reap skip the check that stops it deleting unintegrated work.
worker_base() {
    local worktree="${1:?worktree}"
    [[ -f "$worktree/.braid/base" ]] && cat "$worktree/.braid/base"
}

# Every worker worktree in this repository. With no argument, only those cut from the
# branch you are standing on — with two people orchestrating different features out of
# one clone, an unfiltered list means `wait` never returns until the whole team is
# idle. `all` is the override.
worker_worktrees() {
    local scope="${1:-mine}" here="" worktree branch
    [[ "$scope" == mine ]] && here=$(current_branch)

    git -C "$(primary_checkout)" worktree list --porcelain |
        sed -n 's/^worktree //p' |
        while read -r worktree; do
            [[ -n "$worktree" ]] || continue
            branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
            is_worker_branch "$branch" || continue
            if [[ -n "$here" ]]; then
                [[ "$(worker_base "$worktree")" == "$here" ]] || continue
            fi
            printf '%s\n' "$worktree"
        done
}

# How far ahead of its base a worker is. Zero commits is the shape of a worker that
# died at launch, which looks identical to one still thinking until you ask.
worker_commits_ahead() {
    local worktree="${1:?worktree}" base
    base=$(worker_base "$worktree") || return 1
    [[ -n "$base" ]] || return 1
    git -C "$worktree" rev-list --count "$base..HEAD" 2>/dev/null || printf '0'
}
