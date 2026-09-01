#!/usr/bin/env bash
# Where a worker runs, and what happens when that fails.
#
# braid needs exactly one thing from an agent development environment: *start this
# command in this directory, somewhere the human can see it.* Chained cards, display
# names and workspace status are decoration. A contract with one required function does
# not rot the way a contract with ten does — which matters, because these CLIs are other
# people's, and they change on their schedule.
#
# A launcher is:
#
#   launcher_available            can it be used right now?   (a probe, never a version)
#   launcher_launch <wt> <title> <command>                    required
#   launcher_headless             does it need the agent's headless form?  (optional)
#   launcher_forget <wt>          undo any registration on reap             (optional)
#
# Capability is probed, never version-checked. A version number does not tell you the
# shape of a JSON response changed, so a version gate rejects working setups and admits
# broken ones.

[[ -n "${_BRAID_LAUNCHER_SH:-}" ]] && return 0
_BRAID_LAUNCHER_SH=1

# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

BRAID_LAUNCHER_PROBE=""

# --- where the launcher comes from --------------------------------------------

# The user's own file shadows the built-in. This is the escape valve that makes the
# whole thing survivable: when herdr changes its contract and braid has not caught up,
# twenty lines here have you running today, in a file `braid upgrade` will never
# overwrite.
launcher_file() {
    local name="${1:?name}" override
    override="${XDG_CONFIG_HOME:-$HOME/.config}/braid/launchers/$name.sh"
    if [[ -f "$override" ]]; then
        printf '%s' "$override"
    elif [[ -f "$BRAID_HOME/lib/launchers/$name.sh" ]]; then
        printf '%s' "$BRAID_HOME/lib/launchers/$name.sh"
    else
        return 1
    fi
}

launcher_load() {
    local name="${1:?name}" file
    file=$(launcher_file "$name") || die "no launcher '$name' (built-in or in ~/.config/braid/launchers/)"
    unset -f launcher_available launcher_launch launcher_headless launcher_forget 2>/dev/null || true
    launcher_headless() { return 1; }
    launcher_forget() { :; }
    # shellcheck disable=SC1090
    source "$file"
    BRAID_LAUNCHER_FILE="$file"
}

# The environment braid is running inside, if any. Both orca and herdr mark their own
# terminals, which is a stronger signal than "is it installed" or even "is it running":
# on a machine with both open, the one you are sitting in is the one whose panel you
# will go looking in.
current_ade() {
    if [[ -n "${ORCA_TERMINAL_HANDLE:-}" ]]; then
        printf 'orca'
    elif [[ "${HERDR_ENV:-}" == 1 ]]; then
        printf 'herdr'
    fi
}

# Prints "<name> <certainty>", newline-terminated — callers read it with `read`, which
# returns non-zero on an unterminated line and, under `set -e`, would end the command
# with no message at all.
#
# Three certainties, and they decide what a failure means.
#
#   pinned     you named it            a failure is fatal
#   declared   the environment did     a failure is fatal — you are sitting there
#   inferred   braid guessed           walk the list; nothing was promised
launcher_resolve() {
    local ade name
    if [[ "${BRAID_LAUNCHER:-auto}" != auto ]]; then
        printf '%s pinned\n' "$BRAID_LAUNCHER"
        return 0
    fi
    ade=$(current_ade)
    if [[ -n "$ade" ]]; then
        printf '%s declared\n' "$ade"
        return 0
    fi
    printf '%s inferred\n' "$(launcher_candidates | head -1)"
}

# The usable launchers, best first. Only consulted when braid is guessing — and there
# walking the list is the whole point, so a launch that fails moves to the next one
# rather than giving up. Where the environment or the user said which one, there is no
# list: falling from one to another would put the worker in a panel nobody is watching,
# which looks exactly like a worker that failed to start.
launcher_candidates() {
    local name found=""
    for name in orca herdr tmux detached; do
        launcher_file "$name" >/dev/null || continue
        (
            launcher_load "$name"
            launcher_available
        ) || continue
        printf '%s\n' "$name"
        found=1
    done
    [[ -n "$found" ]] || printf 'detached\n'
}
