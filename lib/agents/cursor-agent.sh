#!/usr/bin/env bash
# Adapter — Cursor CLI (`cursor-agent`, new primary entrypoint `agent`).
#
# Cursor has hooks — `.cursor/hooks.json`, project-level and committed like Claude
# Code's. braid does not install into them yet, and the reason is not effort:
#
#   - CLI hook support is partial and version-dependent. Depending on the build only
#     `beforeShellExecution` / `afterShellExecution`, `postToolUse`, `stop` and
#     `sessionStart` fire in the CLI, and at least one Linux release invoked none at
#     all. A contract delivered by `sessionStart` would arrive on some machines and
#     never on others.
#   - `sessionStart` runs fire-and-forget; it cannot deny a `git push` mid-session
#     the way Claude's PreToolUse guard can.
#
# So for now two things arrive by other means, and braid handles both:
#
#   the contract   goes into the prompt instead of arriving at session start
#   status         written by .braid/finish.sh on exit, not by a stop hook
#
# What does not carry over is the PreToolUse guard: nothing can deny a `git push`
# mid-session. The per-worktree pre-push hook replaces it — narrower, but it is the
# part that actually costs something to clean up.
#
# The adapter is named after the `cursor-agent` binary rather than the shorter
# `agent`, which is the new primary entrypoint. Installs ship both names pointing
# at the same binary, but `agent` is generic enough to collide with something else
# on PATH, and `agent_usable` answers "is it on PATH" by the adapter's name — so
# the specific name is the honest one. If only `agent` exists here, symlink it.
#
# First-party models are pinned, Claude-style: Composer for the cheap seats, Grok
# for the expensive ones. They will drift — that is what BRAID_MODEL_* is for:
#
#   BRAID_MODEL_ORCHESTRATE=…    BRAID_MODEL_HIGH=…
#
# Flags move between versions. `braid doctor` probes whichever flags are set here
# against the installed CLI's own help, so a rename is reported before a wave
# rather than discovered as eight workers that died at launch. When yours disagrees:
#
#   BRAID_CURSOR_AGENT_ARGS="--force"
#
# or drop to the generic adapter and give it the whole command line.
#
# Never pass `-w` / `--worktree`: braid already checked out its own worktree and
# runs the agent inside it. Cursor's own flag would open a second worktree under
# ~/.cursor/worktrees/ that braid knows nothing about.

: "${BRAID_CURSOR_AGENT_ARGS:=--force --trust}"

agent_available() { command -v cursor-agent >/dev/null 2>&1; }

agent_version() { cursor-agent --version 2>/dev/null | head -1; }

# What a seat costs here. The seat says which role runs; the adapter says which
# model that is. Grok 4.6 is the flagship for the seats where judgement matters
# most; Composer 2.5 is the fast everyday model for the work seat.
agent_seat_model() {
    case "${1:?seat}" in
        design) echo grok-4.6 ;;
        orchestrate) echo grok-4.6 ;;
        work | *) echo composer-2.5 ;;
    esac
}

# What a slice's complexity means here. The slice says how much judgement the work
# needs; the adapter says which model that is. A slice that named a model directly
# would be unusable in a repository whose workers run something else.
agent_complexity_model() {
    case "${1:?complexity}" in
        low) echo composer-2.5-fast ;;
        high) echo grok-4.6 ;;
        standard | *) echo composer-2.5 ;;
    esac
}

agent_models() { echo "grok-4.6 grok-4.5 composer-2.5 composer-2.5-fast"; }

agent_injects_contract() { return 1; }

# Cursor discovers skills from ~/.agents/skills/ and ~/.cursor/skills/ alike, in
# the CLI as well as the editor, and the installer links braid's into the shared
# directory. Skills are invoked from the `/` menu — which is the whole reason the
# prefix belongs to the adapter and not to the caller.
agent_loads_skills() { return 0; }
agent_skill_prefix() { printf '/'; }

# --force rather than nothing. Without it a print-mode run proposes changes and
# applies none — a worker that finishes with an empty diff and a glowing report.
# --trust skips the workspace-trust prompt, which has nobody to answer it in a
# detached run. A worker is already confined to its own worktree, and its
# dependencies were installed by braid_provision before it started.
agent_auto_mode() { printf '%s' "$BRAID_CURSOR_AGENT_ARGS"; }
agent_auto_mode_probe() {
    local flag
    for flag in $BRAID_CURSOR_AGENT_ARGS; do
        [[ "$flag" == -* ]] || continue
        cursor-agent --help 2>/dev/null | grep -q -- "$flag" || return 1
    done
    return 0
}

agent_command() {
    # shellcheck disable=SC2034  # the adapter signature is fixed; this agent needs no worktree
    local worktree="$1" model="$2" prompt="$3"
    # shellcheck disable=SC2086  # BRAID_CURSOR_AGENT_ARGS is a flag list on purpose
    if [[ -n "$model" ]]; then
        printf 'cursor-agent %s --model %q %q' "$BRAID_CURSOR_AGENT_ARGS" "$model" "$prompt"
    else
        printf 'cursor-agent %s %q' "$BRAID_CURSOR_AGENT_ARGS" "$prompt"
    fi
}

# -p, because a detached launcher has no tty and the TUI needs one. --force is
# what makes print mode write files rather than describe them.
agent_command_headless() {
    # shellcheck disable=SC2034  # the adapter signature is fixed; this agent needs no worktree
    local worktree="$1" model="$2" prompt="$3"
    # shellcheck disable=SC2086  # BRAID_CURSOR_AGENT_ARGS is a flag list on purpose
    if [[ -n "$model" ]]; then
        printf 'cursor-agent -p %s --model %q %q' "$BRAID_CURSOR_AGENT_ARGS" "$model" "$prompt"
    else
        printf 'cursor-agent -p %s %q' "$BRAID_CURSOR_AGENT_ARGS" "$prompt"
    fi
}

# Where transcripts live, for liveness. Best effort: the IDE writes JSONL under
# ~/.cursor/projects/<workspace>/agent-transcripts/, while CLI sessions may live
# in ~/.cursor/chats/ as SQLite, which the idle check cannot read. A worker with
# no readable transcript still moves .braid/*.log and the git index, so the safe
# signals cover it — silence here never reads as death on its own.
agent_transcript_dir() { printf '%s/.cursor/projects' "$HOME"; }
