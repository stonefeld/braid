#!/usr/bin/env bash
# Adapter — OpenAI Codex CLI.
#
# Codex has hooks, natively, and they are the same shape as Claude Code's down to the
# event names: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest,
# Stop, SubagentStart, SubagentStop. They can also be committed per repository, in
# <repo>/.codex/hooks.json, exactly like Claude's .claude/settings.json. So the reason
# braid does not install into them is not that they are missing, or global.
#
# It is the trust model. Every hook entry has to be trusted by hash before it runs, and
# the trust is recorded in ~/.codex/config.toml under a key that begins with the
# **absolute path** of the file it came from:
#
#   [hooks.state."/abs/path/.codex/hooks.json:pre_tool_use:0:0"]
#   trusted_hash = "sha256:…"
#
# Which braid cannot satisfy, because braid's whole shape is worktrees. Every worker gets
# a fresh checkout at a path that has never existed before, so a committed hooks file
# arrives there untrusted no matter how many times anybody trusted it in the primary
# checkout. There is no "trust it once for this repository" to ask for.
#
# And it fails silently. An untrusted hooks file under `codex exec` does not run and
# nothing is printed about it — checked, in a real repository, not assumed. A guard you
# committed, reviewed, and believed in would simply never fire, in every worker, forever.
# --dangerously-bypass-hook-trust would defeat it, and a tool does not pass that on your
# behalf.
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
# No seat models are declared, and no model names are written down here at all. This CLI
# fetches its own catalogue at runtime, and the copy it fetches is already ahead of the
# copy compiled into it — 0.151.0 ships a list ending at `gpt-5.6-sol` and serves one
# beginning `gpt-6-astra`. A list frozen into braid would be wrong before the release
# that carried it was a week old, and wrong here means refusing the model somebody is
# paying for. braid does not read that catalogue either: it is an undocumented cache
# that a command wrote down, which is the one source the house rules say never to build
# on.
#
# There is also no tier alias to lean on. Claude has `opus` and `sonnet`, which stay put
# while the model behind them moves; every name Codex offers carries its version
# (`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-6-astra`), and the family alias
# `gpt-5.6` is an API spelling the CLI rejects. So there are exactly two ways to run it:
#
#   name nothing   the model in ~/.codex/config.toml runs every seat, and follows you
#                  when you change it there. This is the default, and it is why a
#                  `complexity:` level means nothing here until you say what it means.
#   name them      per repository, from the names `codex` itself lists under /model:
#
#                    BRAID_MODEL_ORCHESTRATE=…  BRAID_MODEL_WORK=…
#                    BRAID_MODEL_LOW=…  BRAID_MODEL_STANDARD=…  BRAID_MODEL_HIGH=…
#
# How hard it thinks is a second axis Codex keeps apart from which model runs. Braid's
# portable effort setting is translated to this config key per session; the raw form is
# still available for Codex-only levels or other configuration:
#
#   BRAID_CODEX_ARGS="--sandbox workspace-write -c model_reasoning_effort=high"
#
# Flags move between versions — `--full-auto` was the right answer and is gone from
# 0.151. `braid doctor` probes whichever flags are set here against the installed CLI's
# own help, so a rename is reported before a wave rather than discovered as eight
# workers that died at launch. When yours disagrees:
#
#   BRAID_CODEX_ARGS="-s danger-full-access"
#
# or drop to the generic adapter and give it the whole command line.

: "${BRAID_CODEX_ARGS:=--sandbox workspace-write}"

# What a seat with a terminal does about approvals. `codex exec` never asks anybody
# anything, so the flag exists only on the interactive CLI — and without it a worker
# in a pane stops on the first approval prompt with nobody sitting in front of it.
# Set it to `on-request` for a seat you intend to babysit.
: "${BRAID_CODEX_APPROVAL_POLICY:=never}"

agent_available() { command -v codex >/dev/null 2>&1; }

agent_version() { codex --version 2>/dev/null | head -1; }

agent_seat_model() { :; }

# Left to the repository. `braid setup` asks which model each complexity level means
# here, because that is the moment somebody with the CLI installed can answer it.
agent_complexity_model() { :; }

# Nothing to validate against. The CLI performs no check of its own — it sends whatever
# name it is given and lets the API refuse it — so a list here would be braid's opinion
# rather than the CLI's, and the only list braid could form is the stale one above.
agent_models() { :; }

# What a tier costs in thinking, beside what it costs in model. The shape mirrors the
# model tiers above it: the two seats that decide things reason hard because they run
# briefly and a bad judgement there costs a whole wave, while the levels vary because
# varying is what a level is for. `xhigh` is left out on purpose — that is the level
# somebody chooses, not one braid chooses for them.
agent_seat_effort() {
    case "${1:?seat}" in
        design | orchestrate) echo high ;;
        work | *) echo medium ;;
    esac
}

agent_level_effort() {
    case "${1:?complexity}" in
        low) echo low ;;
        high) echo high ;;
        standard | *) echo medium ;;
    esac
}

agent_injects_contract() { return 1; }

# Codex keeps skills in ~/.codex/skills, which links into the shared ~/.agents/skills the
# agents use between them, and the installer puts braid's there. It invokes them with `$`
# rather than `/` — which is the whole reason the prefix belongs to the adapter and not to
# the caller.
agent_loads_skills() { return 0; }
agent_skill_prefix() { printf '$'; }

# workspace-write rather than --dangerously-bypass-approvals-and-sandbox. A worker is
# already confined to its own worktree, and its dependencies were installed by
# braid_provision before it started, so the sandbox costs it nothing it needs — and a
# default whose own name says "dangerously" is not a default.
agent_auto_mode() { printf '%s --ask-for-approval %s' "$BRAID_CODEX_ARGS" "$BRAID_CODEX_APPROVAL_POLICY"; }
# Both spellings, because braid launches both: the TUI for a seat with a terminal and
# `codex exec` for a detached one, and they do not accept the same flags —
# --ask-for-approval is rejected outright by exec, which has nobody to ask.
agent_auto_mode_probe() {
    local flag
    for flag in $BRAID_CODEX_ARGS; do
        [[ "$flag" == -* ]] || continue
        codex --help 2>/dev/null | grep -q -- "$flag" || return 1
        codex exec --help 2>/dev/null | grep -q -- "$flag" || return 1
    done
    codex --help 2>/dev/null | grep -q -- '--ask-for-approval'
}

agent_effort_mode() { printf -- '-c model_reasoning_effort=<level>'; }
agent_effort_probe() {
    codex --help 2>/dev/null | grep -q -- '--config' &&
        codex exec --help 2>/dev/null | grep -q -- '--config'
}

# The interactive CLI, not `codex exec`. This is the seat somebody is sitting in front
# of — `braid setup` asking what the verify command is, `braid design` grilling a spec,
# an orchestrator judging a branch — and `codex exec` is documented as "run Codex
# non-interactively": it reads the prompt, works until it decides it is finished, and
# has no way to ask a question. `braid setup` under it looked like an agent doing
# things to the repository and never getting to the conversation, because that is
# exactly what it was.
agent_command() {
    # shellcheck disable=SC2034  # the adapter signature is fixed; this agent needs no worktree
    local worktree="$1" model="$2" prompt="$3" effort="${4:-}" command
    command="codex $BRAID_CODEX_ARGS --ask-for-approval $(
        printf '%q' "$BRAID_CODEX_APPROVAL_POLICY"
    )"
    [[ -z "$model" ]] || command="$command --model $(printf '%q' "$model")"
    [[ -z "$effort" ]] || command="$command -c $(printf '%q' "model_reasoning_effort=$effort")"
    printf '%s %q' "$command" "$prompt"
}

# For a launcher with no terminal. `exec` is the right tool here and the wrong one
# above: it is the half of this CLI that runs without anybody watching.
agent_command_headless() {
    # shellcheck disable=SC2034  # the adapter signature is fixed; this agent needs no worktree
    local worktree="$1" model="$2" prompt="$3" effort="${4:-}" command
    command="codex exec $BRAID_CODEX_ARGS"
    [[ -z "$model" ]] || command="$command --model $(printf '%q' "$model")"
    [[ -z "$effort" ]] || command="$command -c $(printf '%q' "model_reasoning_effort=$effort")"
    printf '%s %q' "$command" "$prompt"
}

agent_transcript_dir() { printf '%s/.codex/sessions' "$HOME"; }
