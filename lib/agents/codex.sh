#!/usr/bin/env bash
# Adapter — OpenAI Codex CLI.
#
# Codex has hooks — ~/.codex/hooks.json, and the schema is the same shape as Claude
# Code's. braid does not install into it yet, and the reason is not effort:
#
#   - it is registered per machine, not per repository. Claude's live in a committed
#     .claude/settings.json, which is what makes "this repository is set up for braid" a
#     reviewable fact. A global hook is a fact about a laptop.
#   - hooks are gated by a trust model, with hashes recorded in config.toml. What braid
#     would have to do to register one honestly has not been verified here, and
#     --dangerously-bypass-hook-trust is not something a tool should pass on your behalf.
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
# No seat models are declared. Model names change faster than this file can, and an
# adapter that guesses one is worse than an adapter that lets the CLI choose. Set them
# per repository:
#
#   BRAID_MODEL_ORCHESTRATE=…    BRAID_MODEL_WORK=…
#
# Flags move between versions — `--full-auto` was the right answer and is gone from
# 0.151. `braid doctor` probes whichever flags are set here against the installed CLI's
# own help, so a rename is reported before a wave rather than discovered as eight
# workers that died at launch. When yours disagrees:
#
#   BRAID_AGENT_ARGS="-s danger-full-access"
#
# or drop to the generic adapter and give it the whole command line.

: "${BRAID_AGENT_ARGS:=--sandbox workspace-write}"

agent_available() { command -v codex >/dev/null 2>&1; }

agent_version() { codex --version 2>/dev/null | head -1; }

agent_seat_model() { :; }

# Left to the repository. `braid setup` asks which model each complexity level means
# here, because that is the moment somebody with the CLI installed can answer it.
#
#   BRAID_MODEL_LOW=…  BRAID_MODEL_STANDARD=…  BRAID_MODEL_HIGH=…
agent_complexity_model() { :; }

# Anything the CLI accepts. Validating against a list braid cannot keep current would
# reject working configurations.
agent_models() { :; }

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
agent_auto_mode() { printf '%s' "$BRAID_AGENT_ARGS"; }
agent_auto_mode_probe() {
    local flag
    for flag in $BRAID_AGENT_ARGS; do
        [[ "$flag" == -* ]] || continue
        codex exec --help 2>/dev/null | grep -q -- "$flag" || return 1
    done
    return 0
}

agent_command() {
    # shellcheck disable=SC2034  # the adapter signature is fixed; this agent needs no worktree
    local worktree="$1" model="$2" prompt="$3"
    # shellcheck disable=SC2086  # BRAID_AGENT_ARGS is a flag list on purpose
    if [[ -n "$model" ]]; then
        printf 'codex exec %s --model %q %q' "$BRAID_AGENT_ARGS" "$model" "$prompt"
    else
        printf 'codex exec %s %q' "$BRAID_AGENT_ARGS" "$prompt"
    fi
}

agent_transcript_dir() { printf '%s/.codex/sessions' "$HOME"; }
