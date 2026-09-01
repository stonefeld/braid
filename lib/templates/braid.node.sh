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
