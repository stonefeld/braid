#!/usr/bin/env bash
# braid.sh — how this project provisions, verifies and cleans up.
#
# The only file braid asks you to write. Assign with `: "${VAR:=value}"` so the
# environment can still win for one command.

: "${BRAID_AGENTS:=claude}"

braid_provision() {
    local worktree="$1" slug="$2"

    provision_env "$worktree" "$slug"

    # A worktree is a fresh checkout, so it has no virtualenv. Built here rather than
    # shared with the primary checkout: two workers installing into one environment is
    # the same collision as two workers on one port, and harder to see.
    if [[ -f "$worktree/pyproject.toml" ]] && command -v uv >/dev/null 2>&1; then
        (cd "$worktree" && uv sync) >"$worktree/.braid/install.log" 2>&1 ||
            {
                warn "uv sync failed — see $worktree/.braid/install.log"
                return 1
            }
    fi
}

braid_verify() {
    local worktree="$1"
    (cd "$worktree" && python3 -m pytest -q)
}

braid_teardown() {
    :
}

# Undo what belongs to the **feature** rather than to one worker — the database every
# `setup: yes` worker of this feature seeded into, a shared container, a fixture store.
# It has to outlive every worker (the next serialized one is cut from a tree that already
# holds the previous one's migrations), so no reap drops it. `braid reap --feature` runs
# this once, after the feature has landed in the trunk.
#
#   $1 the feature's worktree   $2 the feature slug   $3 the trunk it landed in
braid_teardown_feature() {
    : # e.g. dropdb "app_$2"
}
