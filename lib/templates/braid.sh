#!/usr/bin/env bash
# braid.sh — what this project is, in the terms braid asks about.
#
# The only file braid asks you to write, and the only one it reads from your repository.
# Committed, argued with, reviewed like anything else. All of it is optional: braid works
# in a repository with no tests, no build and nothing to provision, and this file is
# where that stops being true.
#
# Values first, functions second, because the values are what you came to change. Every
# value braid reads is named below and commented out — the file lists the whole surface
# without deciding any of it, and setting one activates the line where it already is.
#
# Why every value is `: "${VAR:=…}"` and never `VAR=…`, and which layer wins when two
# disagree: docs/reference/configuration.md.

# --- what each seat costs -----------------------------------------------------
#
# Grouped the way `braid doctor` prints it — one block per seat, one per complexity
# level — because that is the question you arrive with. An empty or absent value means
# the adapter decides, and where it declines, the agent's own CLI does.
#
# This is the largest lever there is on what a wave costs.

# design — grilling and planning. Brief, and the most expensive thing you buy.
# : "${BRAID_AGENT_DESIGN:=}"
# : "${BRAID_MODEL_DESIGN:=}"
# : "${BRAID_EFFORT_DESIGN:=}"

# orchestrate — judging other agents' work against their diffs, and integrating it.
# : "${BRAID_AGENT_ORCHESTRATE:=}"
# : "${BRAID_MODEL_ORCHESTRATE:=}"
# : "${BRAID_EFFORT_ORCHESTRATE:=}"

# work — implementing one slice. The model and effort here are what a complexity level
# falls back to when it says nothing of its own.
# : "${BRAID_AGENT_WORK:=}"
# : "${BRAID_MODEL_WORK:=}"
# : "${BRAID_EFFORT_WORK:=}"

# complexity: low — mechanical and fully specified.
# : "${BRAID_MODEL_LOW:=}"
# : "${BRAID_EFFORT_LOW:=}"

# complexity: standard — the everyday slice.
# : "${BRAID_MODEL_STANDARD:=}"
# : "${BRAID_EFFORT_STANDARD:=}"

# complexity: high — work that needs judgement rather than typing.
# : "${BRAID_MODEL_HIGH:=}"
# : "${BRAID_EFFORT_HIGH:=}"

# --- how this repository runs -------------------------------------------------

# Which agents this repository supports, best first. A decision, not a detection: an
# agent without hooks takes its contract from the prompt and its status from
# .braid/finish.sh, and adding one means confirming that is enough here.
# : "${BRAID_AGENTS:=claude}"

# A ceiling, not a target — the machine's own BRAID_MAX_WORKERS still applies and the
# lower of the two wins. Raise it only if provisioning here is genuinely cheap.
# : "${BRAID_MAX_WORKERS:=4}"

# Where slices come from: `files` reads BRAID_FEATURES_DIR, `github` reads a PRD issue's
# sub-issues through the gh CLI.
# : "${BRAID_SLICE_SOURCE:=files}"
# : "${BRAID_FEATURES_DIR:=braid/features}"

# What worker branches are called, and what nothing may ever push to.
# : "${BRAID_BRANCH_PREFIX:=agent}"
# : "${BRAID_PROTECTED_BRANCHES:=main master}"

# What a worker's own install and test run leaves behind that this project does not
# already ignore — because in your checkout it never appears. Applied per worktree
# through core.excludesFile, so neither this repository's .gitignore nor your own is
# touched. It matters because the contract tells every worker to commit everything.
# : "${BRAID_WORKER_IGNORE:=build/
# .cache/}"

# How this house gets from "we should build something" to a set of launchable slices.
# braid ships none of these and never runs them — it prints the list so that `braid
# design` opens onto something other than a blank session.
# : "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"

# --- what this project does ---------------------------------------------------

# Everything a worker needs before its first turn.
#
#   $1 worktree   $2 slug   $3 base branch   $4 needs-setup (0|1)
#
# Non-zero aborts the spawn and the half-made worktree is removed, so it is safe to fail
# here.
#
# Nothing a worker shares with another may be named the same twice. `worker_suffix` is
# the one piece braid can supply: a short name derived from the slice, stable across
# re-provisions, and recomputable in braid_teardown once the worktree is gone. What you
# build out of it is this project's business.
#
#   name=$(worker_suffix "$2")
#   printf 'PORT=%s\n' "$((8100 + name))" >>"$1/.env"
#   createdb "app_$name"
braid_provision() {
    :
}

# The mechanical half of the gate: build, typecheck, lint, tests. Whatever a human should
# not have to read a diff to check. Non-zero means the branch does not integrate.
#
# A green verify is not permission to integrate; a red one is a refusal.
braid_verify() {
    : # e.g. (cd "$1" && make check)
}

# Undo whatever provision created *outside* the worktree — a container, a schema, a
# queue. The worktree itself is git's to remove. Never fail a reap from here.
braid_teardown() {
    : # e.g. docker rm -f "app-$(worker_suffix "$2")"
}

# Undo what belongs to the **feature** rather than to one worker — the database every
# `setup: yes` worker of this feature seeded into, a shared container, a fixture store.
# It has to outlive every worker, so no reap drops it. `braid reap --feature` runs this
# once, after the feature has landed in the trunk.
#
#   $1 the feature's worktree   $2 the feature slug   $3 the trunk it landed in
braid_teardown_feature() {
    : # e.g. dropdb "app_$2"
}
