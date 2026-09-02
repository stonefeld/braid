#!/usr/bin/env bash
# The worker contract: bundled, extended, or replaced.
#
# Three states, and which one a repository is in is the whole of this file:
#
#   bundled           nothing in the repository. The engine's contract, and every
#                     upgrade reaches it.
#   bundled + rules   docs/worker-rules.md is appended under a heading braid supplies.
#                     Upgrades still reach the part braid owns.
#   replaced          docs/worker-contract.md is delivered instead, whole. Nothing
#                     braid ships afterwards ever reaches it.
#
# Replacement came first and was, for a while, the only option — so a project whose
# only need was a handful of house rules had to copy 118 lines to append six, and then
# own every one of them forever.
#
# Composed **once**, at spawn, into the worktree's .braid/contract.md; every delivery
# path reads that file rather than recomputing the text. Two paths computing the same
# contract independently is exactly how the prompt for an agent with no hooks once
# shipped with no contract in it at all.

[[ -n "${_BRAID_CONTRACT_SH:-}" ]] && return 0
_BRAID_CONTRACT_SH=1

# shellcheck source=git.sh
source "$BRAID_HOME/lib/git.sh"

contract_replacement() {
    local file="${1:?checkout}/docs/worker-contract.md"
    [[ -f "$file" ]] && printf '%s' "$file"
    return 0
}

contract_rules() {
    local file="${1:?checkout}/docs/worker-rules.md"
    [[ -f "$file" ]] && printf '%s' "$file"
    return 0
}

# bundled | bundled+rules | replaced
contract_state() {
    local checkout="${1:?checkout}"
    if [[ -n "$(contract_replacement "$checkout")" ]]; then
        printf 'replaced'
    elif [[ -n "$(contract_rules "$checkout")" ]]; then
        printf 'bundled+rules'
    else
        printf 'bundled'
    fi
}

# The contract this repository delivers, on stdout.
#
# The heading and the lead-in are braid's, not the project's: a rules file that has to
# introduce itself is a rules file that can forget to, and a worker reading an
# unannounced block of text at the end of its contract has no way to tell what weight
# it carries.
contract_compose() {
    local checkout="${1:?checkout}" replacement rules

    replacement=$(contract_replacement "$checkout")
    if [[ -n "$replacement" ]]; then
        cat "$replacement"
        return 0
    fi

    cat "$BRAID_HOME/docs/worker-contract.md"

    rules=$(contract_rules "$checkout")
    [[ -n "$rules" ]] || return 0
    printf '\n## House rules\n\n'
    printf '%s\n\n' "These are this project's own additions to the contract above. They carry the same weight as everything in it."
    cat "$rules"
}
