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
# for the expensive ones. Cursor's IDs are namespaced and tiered, so it is
# `cursor-grok-4.6-high` and never the bare `grok-4.6` — get that wrong and the CLI
# prints "Cannot use this model", does nothing, and exits 0, which reaches braid as
# a worker with no diff and a finish.sh recording a success. No list here catches
# that (see agent_models); `cursor-agent --list-models` does, and is worth a run
# after a CLI upgrade. They drift, which is what BRAID_MODEL_* is for:
#
#   BRAID_MODEL_ORCHESTRATE=…    BRAID_MODEL_HIGH=…
#
# Flags move between versions. `braid doctor` probes whichever flags are set here
# against the installed CLI's own help, so a rename is reported before a wave rather
# than discovered as eight workers that died at launch. When yours disagrees:
#
#   BRAID_CURSOR_AGENT_ARGS="--force"
#   BRAID_CURSOR_AGENT_HEADLESS_ARGS="--trust"
#
# or drop to the generic adapter and give it the whole command line. Namespaced,
# unlike Codex's plain BRAID_AGENT_ARGS: that one came first and stays for
# compatibility, but every adapter from here on takes BRAID_<ADAPTER>_ARGS, so two
# agents configured on one machine cannot read each other's flags.
#
# Never pass `-w` / `--worktree`: braid already checked out its own worktree and
# runs the agent inside it. Cursor's own flag would open a second worktree under
# ~/.cursor/worktrees/ that braid knows nothing about.

: "${BRAID_CURSOR_AGENT_ARGS:=--force}"
: "${BRAID_CURSOR_AGENT_HEADLESS_ARGS:=--trust}"

agent_available() { command -v cursor-agent >/dev/null 2>&1; }

agent_version() { cursor-agent --version 2>/dev/null | head -1; }

# What a seat costs here. The seat says which role runs; the adapter says which
# model that is. Grok 4.6 is the flagship for the seats where judgement matters
# most; Composer 2.5 is the fast everyday model for the work seat.
#
# `-high` is Cursor's default tier for Grok rather than an upgrade — the CLI lists
# `cursor-grok-4.6-high` as plain "Cursor Grok 4.6".
# Left to the repository, for the reason lib/agents/README.md gives: every name this CLI
# offers carries its version — `composer-2.5`, `cursor-grok-4.6-high` — and there is no
# family alias underneath them to name instead. A version is the thing that moves, and a
# name that has moved fails hard here: the CLI answers "Cannot use this model", writes
# nothing and exits 0, so a wave on a stale name reads as a wave of empty successes.
# Naming nothing runs whatever the CLI is configured for, which always works.
#
# `braid config` asks which model each seat and each complexity level means here, which
# is the moment somebody with the CLI installed can read the answer off `--list-models`.
agent_seat_model() { :; }

agent_complexity_model() { :; }

# Nothing to validate against. `--list-models` answers with hundreds of names: every
# Claude, GPT, Gemini, Grok, Kimi and GLM tier the account can reach, plus `auto`.
# Any list written down here would be a snapshot that goes stale at the next release
# and refuses working configurations — the mapping above is this adapter's defaults,
# not the permitted set — so the escape hatches keep working:
#
#   BRAID_MODEL_HIGH=claude-opus-5-high     braid spawn --model gpt-5.2
agent_models() { :; }

agent_injects_contract() { return 1; }

# Cursor discovers skills from ~/.agents/skills/ and ~/.cursor/skills/ alike, in
# the CLI as well as the editor, and the installer links braid's into the shared
# directory. Skills are invoked from the `/` menu — which is the whole reason the
# prefix belongs to the adapter and not to the caller.
agent_loads_skills() { return 0; }
agent_skill_prefix() { printf '/'; }

# --force rather than nothing, and not for the reason it looks like: print mode
# already holds the write tool. What --force buys is the shell — "force allow
# commands unless explicitly denied". Denied, a worker cannot run the verify command
# or `git add`, and improvises around the wall instead of reporting it. --trust
# answers the workspace-trust prompt, which has nobody to answer it in a detached
# run; Cursor documents it as headless-only, so the interactive command must not see
# it. The worker is confined to its own worktree already, and braid_provision
# installed its dependencies before it started.
agent_auto_mode() {
    printf '%s %s' "$BRAID_CURSOR_AGENT_ARGS" "$BRAID_CURSOR_AGENT_HEADLESS_ARGS"
}

# --print as well as the configured flags: it is hardcoded into the headless command
# rather than living in BRAID_CURSOR_AGENT_ARGS, so nothing else would notice it
# being renamed, and the whole detached path rests on it. One --help, because the
# agent run is cursor-agent's top-level command — there is no subcommand whose own
# help could disagree, the way `codex exec --help` does.
agent_auto_mode_probe() {
    local flag flags help
    help=$(cursor-agent --help 2>/dev/null) || return 1
    grep -q -- '--print' <<<"$help" || return 1
    flags="$BRAID_CURSOR_AGENT_ARGS $BRAID_CURSOR_AGENT_HEADLESS_ARGS"
    for flag in $flags; do
        [[ "$flag" == -* ]] || continue
        grep -q -- "$flag" <<<"$help" || return 1
    done
    return 0
}

agent_command() {
    # shellcheck disable=SC2034  # fixed adapter signature; no worktree needed here
    # shellcheck disable=SC2034  # declared because the signature is the contract's
    local worktree="$1" model="$2" prompt="$3" effort="${4:-}"
    # shellcheck disable=SC2086  # BRAID_CURSOR_AGENT_ARGS is a flag list on purpose
    if [[ -n "$model" ]]; then
        printf 'cursor-agent %s --model %q %q' \
            "$BRAID_CURSOR_AGENT_ARGS" "$model" "$prompt"
    else
        printf 'cursor-agent %s %q' "$BRAID_CURSOR_AGENT_ARGS" "$prompt"
    fi
}

# -p, because a detached launcher has no tty and the TUI needs one. --trust is
# headless-only; keeping it out of BRAID_CURSOR_AGENT_ARGS is what lets the same
# adapter launch Cursor's interactive half without handing it an invalid flag.
agent_command_headless() {
    # shellcheck disable=SC2034  # fixed adapter signature; no worktree needed here
    # shellcheck disable=SC2034  # declared because the signature is the contract's
    local worktree="$1" model="$2" prompt="$3" effort="${4:-}"
    # shellcheck disable=SC2086  # both variables are flag lists on purpose
    if [[ -n "$model" ]]; then
        printf 'cursor-agent -p %s %s --model %q %q' \
            "$BRAID_CURSOR_AGENT_ARGS" "$BRAID_CURSOR_AGENT_HEADLESS_ARGS" \
            "$model" "$prompt"
    else
        printf 'cursor-agent -p %s %s %q' \
            "$BRAID_CURSOR_AGENT_ARGS" "$BRAID_CURSOR_AGENT_HEADLESS_ARGS" "$prompt"
    fi
}

# Where transcripts live, for liveness. Best effort: the IDE writes JSONL under
# ~/.cursor/projects/<workspace>/agent-transcripts/, while CLI sessions may live
# in ~/.cursor/chats/ as SQLite, which the idle check cannot read. A worker with
# no readable transcript still moves .braid/*.log and the git index, so the safe
# signals cover it — silence here never reads as death on its own.
agent_transcript_dir() { printf '%s/.cursor/projects' "$HOME"; }
