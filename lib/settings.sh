#!/usr/bin/env bash
# Every layer of configuration, resolved once per command.
#
# Named for what it resolves rather than for the concept, because `braid config` is a
# command and lib/<name>.sh is where the dispatcher looks for one.
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

[[ -n "${_BRAID_SETTINGS_SH:-}" ]] && return 0
_BRAID_SETTINGS_SH=1

# shellcheck source=git.sh
source "$BRAID_HOME/lib/git.sh"

# ~/.config/braid/config — this machine, not this repository. Sourced before the
# repository's file so that braid.sh's `:=` defaults do not clobber it.
# What a machine may say, which is: what is true of the machine. Anything else in that
# file is a decision this repository made and somebody reviewed, and a file nobody else
# can see must not be able to overrule one — that is not a missing feature, it is the
# reason the layers exist at all.
#
# Two are refused for a different reason than the rest. BRAID_PROTECTED_BRANCHES and
# BRAID_PUSH_GUARD decide what a worker may push to; an uncommitted file that widens
# either is a hole rather than a preference, and BRAID_AGENT_ROLE turns the guard off
# outright.
#
# The model and effort families are here because a person's budget is a real fact about
# that person and there is nowhere better yet. When a per-repository, per-person layer
# exists they belong there instead and this list gets shorter.
_BRAID_MACHINE_SETTINGS="BRAID_MAX_WORKERS BRAID_LAUNCHER BRAID_LAUNCHER_STRICT
BRAID_WORKTREE_ROOT BRAID_STALE_SECONDS BRAID_AGENT
BRAID_MODEL_DESIGN BRAID_MODEL_ORCHESTRATE BRAID_MODEL_WORK
BRAID_MODEL_LOW BRAID_MODEL_STANDARD BRAID_MODEL_HIGH
BRAID_EFFORT_DESIGN BRAID_EFFORT_ORCHESTRATE BRAID_EFFORT_WORK
BRAID_EFFORT_LOW BRAID_EFFORT_STANDARD BRAID_EFFORT_HIGH"

braid_setting_known() {
    local name="${1:?name}" candidate
    for candidate in $_BRAID_SETTINGS; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

braid_machine_allows() {
    local name="${1:?name}" candidate
    for candidate in $_BRAID_MACHINE_SETTINGS; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

# Read as data, never executed. A file braid does not write cannot be asked to assign
# with `:=`, and sourcing it meant the machine outranked the one thing it must lose to —
# a value somebody set for a single command. Applying only what is still unset is that
# order, without a trick to restore it afterwards.
#
# Refusals are collected rather than printed. This runs inside every command, and a
# warning on all of them is a warning nobody reads; `braid doctor` and `braid config`
# report what was refused, once, where somebody is looking for it.
_BRAID_MACHINE_REFUSED=""
braid_machine_config() {
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/braid/config" line name value why
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "" | [[:space:]]* | \#*) continue ;;
        esac
        if [[ "$line" != *=* || "$line" =~ ^[^A-Za-z_] ]]; then
            _BRAID_MACHINE_REFUSED="$_BRAID_MACHINE_REFUSED
${line%%=*}|is not KEY=value, and this file is read rather than run"
            continue
        fi
        name="${line%%=*}"
        value="${line#*=}"
        # One layer of quoting, because somebody will write them and a file read as data
        # has no shell to take them off.
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        if ! braid_machine_allows "$name"; then
            case "$name" in
                BRAID_PROTECTED_BRANCHES | BRAID_PUSH_GUARD | BRAID_AGENT_ROLE)
                    why="decides what a worker may push to, and this file is not committed"
                    ;;
                *)
                    braid_setting_known "$name" &&
                        why="is this repository's to decide, not one machine's" ||
                        why="is not a braid setting"
                    ;;
            esac
            _BRAID_MACHINE_REFUSED="$_BRAID_MACHINE_REFUSED
$name|$why"
            continue
        fi
        # Unset only: the environment said it first and outranks this file.
        [[ -n "${!name:-}" ]] || export "$name=$value"
    done <"$file"
}

# --- the project seam ---------------------------------------------------------

# The things a repository may say about itself. All optional, all no-ops, because
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
#       Undo whatever provision made outside the worktree, for **one worker**. Never
#       fails a reap.
#
#   braid_teardown_feature <feature-worktree> <feature-slug> <base-branch>
#       Undo what is scoped to the whole feature rather than to one worker — a database
#       seeded once and shared by every `setup: yes` worker, a container, a fixture
#       store. It outlives every worker by design, so no per-worker reap may drop it;
#       `braid reap --feature` runs this, once, after the feature has landed. Never
#       fails that command.
#
#   braid_fetch_slice <id>
#       Where slices come from, when they come from neither files nor GitHub issues.
#       Given an id, print the slice's markdown.
#
#   braid_slice_launchable <id>
#       Whether an open sub-issue is work a worker could start. Non-zero withdraws it
#       from the schedule. Open is necessary and not sufficient — a spike, or an issue
#       waiting on an answer, is open and not launchable — and only the tracker's own
#       vocabulary can say which, which is why braid cannot.
braid_provision() { :; }
braid_verify() { :; }
braid_teardown() { :; }
braid_teardown_feature() { :; }
# Returns 0, so the default is "everything open is work" and the loop that calls it needs
# no branch for the case where nobody defined it.
braid_slice_launchable() { :; }

# --- what the seam is built from ----------------------------------------------

# A short unique name for anything a worker must not share: a port, a schema, a queue,
# a container. Derived from the slice id, so it is the same every time that worker is
# re-provisioned — a worker sent back to fix something keeps the name its notes refer
# to — and recomputable from the slug alone, so braid_teardown can still name what it
# has to remove after the worktree is gone.
#
# It lives here rather than beside a helper that only spawn sourced, which is what made
# that last sentence untrue: reap runs braid_teardown and never loaded the file.
#
# What the name is *for* is the repository's business. braid knows that parallel workers
# must not collide on a shared name; it does not know whether yours is a port.
worker_suffix() {
    local slug="${1:?slug}"
    if [[ "$slug" =~ ^([0-9]+)(-|$) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'h%s' "$(printf '%s' "$slug" | cksum | cut -d' ' -f1)"
    fi
}

# Whether the repository actually replaced one of them. Compared against the no-op body
# rather than asked with `declare -F`, which is true of the defaults too — and a tool
# that reports a gate it does not have is worse than one that reports no gate at all.
_BRAID_NOOP_BODY="$(declare -f braid_verify | sed '1d')"
braid_overridden() {
    declare -F "$1" >/dev/null || return 1
    [[ "$(declare -f "$1" | sed '1d')" != "$_BRAID_NOOP_BODY" ]]
}

# Every value a person may set — a decision rather than a survey. A name here is one
# `braid config` offers and the reference documents, and adding one means somebody meant
# to. The seat and level families are spelled out rather than assembled, because a list
# you can read is the whole point of having one.
_BRAID_SETTINGS="BRAID_AGENTS BRAID_MAX_WORKERS BRAID_LAUNCHER BRAID_LAUNCHER_STRICT
BRAID_BRANCH_PREFIX BRAID_PROTECTED_BRANCHES BRAID_WORKTREE_ROOT BRAID_SLICE_SOURCE
BRAID_FEATURES_DIR BRAID_WORKER_IGNORE BRAID_DESIGN_STEPS BRAID_STALE_SECONDS
BRAID_PUSH_GUARD BRAID_AGENT BRAID_AGENT_ROLE
BRAID_AGENT_DESIGN BRAID_MODEL_DESIGN BRAID_EFFORT_DESIGN
BRAID_AGENT_ORCHESTRATE BRAID_MODEL_ORCHESTRATE BRAID_EFFORT_ORCHESTRATE
BRAID_AGENT_WORK BRAID_MODEL_WORK BRAID_EFFORT_WORK
BRAID_MODEL_LOW BRAID_EFFORT_LOW
BRAID_MODEL_STANDARD BRAID_EFFORT_STANDARD
BRAID_MODEL_HIGH BRAID_EFFORT_HIGH"

# Set one `: "${VAR:=value}"` in braid.sh — rewritten where the line exists, appended
# where it does not. Always the `:=` form, which is what lets the environment win for a
# single command without editing a committed file.
#
# A third argument is a heading for whatever is being appended, written once. Every other
# line in this file explains itself; a block of assignments arriving at the end with
# nothing over them reads like something that fell in.
braid_sh_set() {
    python3 - "${1:?name}" "${2-}" "${3:-}" "${4:-braid.sh}" <<'PY'
import pathlib
import re
import sys

name, value, heading, target = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
path = pathlib.Path(target)
text = path.read_text(encoding="utf-8") if path.exists() else ""
# The comment marker is optional and is dropped when one is written. The template
# ships every value braid reads, commented out, so that the file lists the whole
# surface without deciding any of it — and setting one has to activate the line where
# it already is rather than append a second copy at the end.
pattern = re.compile(r'(?m)^#? ?(: "\$\{%s:=)([^}]*)(\}")' % re.escape(name))
if pattern.search(text):
    # A literal replacement, never a template: re.sub reads \g and \1 in a replacement
    # string, and everything being written here came from somebody typing it.
    text = pattern.sub(lambda m: m.group(1) + value + m.group(3), text, count=1)
else:
    lines = text.rstrip("\n").split("\n") if text.strip() else []
    block = ""
    if heading and heading not in text:
        block = "\n\n# " + heading + "\n"
    elif lines and lines[-1].startswith(': "${BRAID_'):
        # Several of these are appended in a row, and a blank line between each turns
        # one decision into a scattered list.
        block = "\n"
    elif lines:
        block = "\n\n"
    text = "\n".join(lines) + block + ': "${%s:=%s}"' % (name, value) + "\n"
path.write_text(text, encoding="utf-8")
PY
}

braid_config() {
    local checkout
    checkout=$(primary_checkout)

    braid_machine_config

    # The repository's own file, after the machine's and before the defaults. Its
    # `: "${VAR:=…}"` assignments therefore lose to anything already set and win over
    # everything below.
    #
    # Read from the branch you are standing on, not from the primary checkout: a hook a
    # feature adds to its own braid.sh has to govern that feature's run, which is the
    # entire reason to add one mid-feature.
    _BRAID_PROJECT_FILE="${_BRAID_PROJECT_FILE:-$(branch_path braid.sh)}"
    if [[ -f "$_BRAID_PROJECT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$_BRAID_PROJECT_FILE"
    fi

    # Which agents this repository supports, best first. A committed decision, narrowed
    # by `braid init`; until then braid accepts any adapter it has, because before
    # setup the repository has not decided anything for a preference to contradict.
    : "${BRAID_AGENTS:=claude codex cursor-agent generic}"
    : "${BRAID_BRANCH_PREFIX:=agent}"
    : "${BRAID_PROTECTED_BRANCHES:=main master}"
    : "${BRAID_WORKTREE_ROOT:=$HOME/.braid/worktrees/$(basename "$checkout")}"
    # Where a feature's slices and its plan live in files mode. One folder per feature:
    # the folder is the parent and the files are its children, which is the parent /
    # sub-issue relation without needing a tracker to have the primitive.
    : "${BRAID_FEATURES_DIR:=braid/features}"

    # Where slices are read from. `files` needs nothing; `github` needs the gh CLI and a
    # PRD issue whose sub-issues are the slices. The braid block is parsed identically
    # from either, which is what lets a slice move between them unchanged.
    : "${BRAID_SLICE_SOURCE:=files}"

    # What a worker's own test and install run leaves behind that this project does not
    # already ignore — because in your checkout it never appears. Applied per worktree,
    # so neither the project's .gitignore nor your own checkout is touched. Empty by
    # default: a repository that never mentions this keeps the git configuration it had.
    : "${BRAID_WORKER_IGNORE:=}"

    # How this house gets from "we should build something" to a set of launchable
    # slices. braid ships none of these steps and never runs them — grilling, writing a
    # spec, cutting it into tickets are somebody else's skills, and the glue test says
    # braid must not grow a layer that reshapes their output.
    #
    # But refusing to *own* them turned into refusing to *name* them, and the result was
    # a person opening `braid design` to a blank session with nothing to go on. The rest
    # of that rule is "push it into configuration those skills already read", and this is
    # that: a list braid prints and never interprets.
    #
    #   : "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"
    : "${BRAID_DESIGN_STEPS:=}"

    : "${BRAID_STALE_SECONDS:=1200}"
    : "${BRAID_PUSH_GUARD:=1}"

    # How many workers may run at once. A machine fact: nine parallel agents kill some
    # laptops and not others. A repository whose provisioning is heavy may lower it,
    # never raise it past what the machine said.
    : "${BRAID_MAX_WORKERS:=4}"

    export BRAID_BRANCH_PREFIX BRAID_PROTECTED_BRANCHES BRAID_AGENTS
    export BRAID_WORKTREE_ROOT BRAID_MAX_WORKERS BRAID_FEATURES_DIR BRAID_SLICE_SOURCE
    export BRAID_WORKER_IGNORE BRAID_DESIGN_STEPS
}
