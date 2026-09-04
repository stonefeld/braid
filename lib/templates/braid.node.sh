#!/usr/bin/env bash
# braid.sh — how this project provisions, verifies and cleans up.
#
# The only file braid asks you to write. Assign with `: "${VAR:=value}"` so the
# environment can still win for one command.

: "${BRAID_AGENTS:=claude}"

braid_provision() {
    local worktree="$1" slug="$2"

    # .env from the primary checkout, with this worker's own BRAID_PORT so its dev
    # server cannot answer for — or attach to — anybody else's.
    provision_env "$worktree" "$slug"

    # Long, and its output matters when it fails, so it goes to a file rather than
    # scrolling past in a panel nobody was watching.
    (cd "$worktree" && npm ci --no-audit --no-fund) >"$worktree/.braid/install.log" 2>&1 ||
        {
            warn "npm ci failed — see $worktree/.braid/install.log"
            return 1
        }
}

braid_verify() {
    local worktree="$1"
    (cd "$worktree" && npm run --if-present typecheck && npm test)
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

# What a worker's own install and test run leaves behind that this project does not
# already ignore — because in your checkout it never appears. Applied per worktree
# through core.excludesFile, so neither this repository's .gitignore nor your own
# checkout is touched, and your global ignores are kept.
#
# It matters because the contract tells every worker to commit everything: whatever is
# left lying about in a worktree is one `git add -A` away from the feature branch.
#
#   : "${BRAID_WORKER_IGNORE:=coverage/
#   .next/
#   *.tsbuildinfo}"
