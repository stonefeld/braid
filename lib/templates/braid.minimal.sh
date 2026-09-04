#!/usr/bin/env bash
# braid.sh — how this project provisions, verifies and cleans up.
#
# The only file braid asks you to write. Committed, argued with, reviewed like any
# other config. Everything here is optional: braid works in a repository with no tests,
# no build and no .env, and this file is where that stops being true.
#
# Assign with `: "${VAR:=value}"`, never `VAR=value`. That is what lets the environment
# win for one command without editing a committed file.

# Which agents this repository supports, best first. A decision, not a detection: an
# agent without hooks takes its contract from the prompt and its status from
# .braid/finish.sh, and adding one means confirming that is enough here.
: "${BRAID_AGENTS:=claude}"

# How many workers may run at once. A ceiling, not a target — the machine's own
# BRAID_MAX_WORKERS still applies, and the lower of the two wins. Raise it only if
# provisioning here is genuinely cheap.
# : "${BRAID_MAX_WORKERS:=4}"

# Everything a worker needs before its first turn.
#
#   $1 worktree   $2 slug   $3 base branch   $4 needs-setup (0|1)
#
# Non-zero aborts the spawn and the half-made worktree is removed, so it is safe to
# fail here.
braid_provision() {
    provision_env "$1" "$2" # .env copied from the primary checkout, with its own BRAID_PORT
}

# The mechanical half of the gate: build, typecheck, lint, tests. Whatever a human
# should not have to read a diff to check. Non-zero means the branch does not integrate.
#
# A green verify is not permission to integrate; a red one is a refusal.
braid_verify() {
    : # e.g. (cd "$1" && make check)
}

# Undo whatever provision created *outside* the worktree — a container, a schema, a
# queue. The worktree itself is git's to remove. Never fail a reap from here.
braid_teardown() {
    : # e.g. docker rm -f "app-$2"
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
#   : "${BRAID_WORKER_IGNORE:=build/
#   .cache/}"

# How this house gets from "we should build something" to a set of launchable slices.
# braid ships none of these and never runs them — it prints the list so that `braid
# design` opens onto something other than a blank session.
#
#   : "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"
