#!/usr/bin/env bash
# Configuration, resolved once per command.
#
# Three layers, and the order is the whole point:
#
#   environment  >  the repository's braid.sh  >  these defaults
#
# which is why braid.sh assigns with `: "${VAR:=value}"` rather than `VAR=value`. A
# repository states what it needs; a person overrides it for one command without
# editing a committed file.
#
# What belongs where is not a matter of taste. A repository's settings are decisions a
# team made and reviewed — the branch prefix, which agents are supported, what verify
# runs. A machine's settings are facts about one computer — how many agents it survives,
# which agent that person prefers. Conflating them is how one laptop configures a team.

[[ -n "${_BRAID_CONFIG_SH:-}" ]] && return 0
_BRAID_CONFIG_SH=1

# shellcheck source=git.sh
source "$BRAID_HOME/lib/git.sh"

# ~/.config/braid/config — this machine, not this repository. Sourced before the
# repository's file so that braid.sh's `:=` defaults do not clobber it.
braid_machine_config() {
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/braid/config"
    if [[ -f "$file" ]]; then
        # shellcheck disable=SC1090
        source "$file"
    fi
}

# --- the project seam ---------------------------------------------------------

# The four things a repository may say about itself. All optional, all no-ops, because
# braid has to work in a repository created twenty minutes ago that has no tests, no
# build and no .env — and the only way that claim stays true is if nothing here is
# required.
#
#   braid_provision <worktree> <slug> <base> <needs-setup:0|1>
#       Everything a worker needs before its first turn: .env, a database, an install.
#       Runs after the worktree exists and before the agent starts. Non-zero aborts the
#       spawn and the half-made worktree is removed.
#
#   braid_verify <worktree>
#       The mechanical half of the gate — build, typecheck, lint, tests. Whatever a
#       human should not have to eyeball. Non-zero means the branch does not integrate.
#
#   braid_teardown <worktree> <slug>
#       Undo whatever provision made outside the worktree. Never fails a reap.
#
#   braid_fetch_slice <id>
#       Print a slice's markdown to stdout. Override to read from something other than
#       files or GitHub issues.
braid_provision() { :; }
braid_verify() { :; }
braid_teardown() { :; }

# Whether the repository actually replaced one of them. Compared against the no-op body
# rather than asked with `declare -F`, which is true of the defaults too — and a tool
# that reports a gate it does not have is worse than one that reports no gate at all.
_BRAID_NOOP_BODY="$(declare -f braid_verify | sed '1d')"
braid_overridden() {
    declare -F "$1" >/dev/null || return 1
    [[ "$(declare -f "$1" | sed '1d')" != "$_BRAID_NOOP_BODY" ]]
}

braid_config() {
    local checkout
    checkout=$(primary_checkout)

    braid_machine_config

    # The repository's own file, after the machine's and before the defaults. Its
    # `: "${VAR:=…}"` assignments therefore lose to anything already set and win over
    # everything below.
    BRAID_PROJECT_FILE="${BRAID_PROJECT_FILE:-$checkout/braid.sh}"
    if [[ -f "$BRAID_PROJECT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$BRAID_PROJECT_FILE"
    fi

    : "${BRAID_NAME:=$(basename "$checkout")}"

    # Which agents this repository supports, best first. A committed decision, narrowed
    # by `braid setup`; until then braid accepts any adapter it has, because before
    # setup the repository has not decided anything for a preference to contradict.
    : "${BRAID_AGENTS:=claude codex generic}"
    : "${BRAID_BRANCH_PREFIX:=agent}"
    : "${BRAID_PROTECTED_BRANCHES:=main master}"
    : "${BRAID_WORKTREE_ROOT:=$HOME/.braid/worktrees/$(basename "$checkout")}"
    # Where a feature's slices and its plan live in files mode. One folder per feature:
    # the folder is the parent and the files are its children, which is the parent /
    # sub-issue relation without needing a tracker to have the primitive.
    : "${BRAID_FEATURES_DIR:=braid/features}"

    : "${BRAID_PORT_BASE:=8100}"
    : "${BRAID_PORT_RANGE:=400}"
    : "${BRAID_STALE_SECONDS:=1200}"
    : "${BRAID_PUSH_GUARD:=1}"

    # How many workers may run at once. A machine fact: nine parallel agents kill some
    # laptops and not others. A repository whose provisioning is heavy may lower it,
    # never raise it past what the machine said.
    : "${BRAID_MAX_WORKERS:=4}"

    export BRAID_PROJECT_FILE
    export BRAID_NAME BRAID_BRANCH_PREFIX BRAID_PROTECTED_BRANCHES BRAID_AGENTS
    export BRAID_WORKTREE_ROOT BRAID_MAX_WORKERS BRAID_FEATURES_DIR
}
