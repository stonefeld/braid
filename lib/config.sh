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

braid_config() {
    local checkout
    checkout=$(primary_checkout)

    braid_machine_config

    : "${BRAID_NAME:=$(basename "$checkout")}"

    # Which agents this repository supports, best first. A committed decision, narrowed
    # by `braid setup`; until then braid accepts any adapter it has, because before
    # setup the repository has not decided anything for a preference to contradict.
    : "${BRAID_AGENTS:=claude codex generic}"
    : "${BRAID_BRANCH_PREFIX:=agent}"
    : "${BRAID_PROTECTED_BRANCHES:=main master}"
    : "${BRAID_WORKTREE_ROOT:=$HOME/.braid/worktrees/$(basename "$checkout")}"
    : "${BRAID_PORT_BASE:=8100}"
    : "${BRAID_PORT_RANGE:=400}"
    : "${BRAID_STALE_SECONDS:=1200}"
    : "${BRAID_PUSH_GUARD:=1}"

    # How many workers may run at once. A machine fact: nine parallel agents kill some
    # laptops and not others. A repository whose provisioning is heavy may lower it,
    # never raise it past what the machine said.
    : "${BRAID_MAX_WORKERS:=4}"

    export BRAID_NAME BRAID_BRANCH_PREFIX BRAID_PROTECTED_BRANCHES BRAID_AGENTS
    export BRAID_WORKTREE_ROOT BRAID_MAX_WORKERS
}
