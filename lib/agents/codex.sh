#!/usr/bin/env bash
# Adapter — OpenAI Codex CLI.
#
# No hook system, so two things move, and braid handles both:
#
#   the contract   goes into the prompt instead of arriving at session start
#   status         written by .braid/finish.sh on exit, not by a Stop hook
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
# Flags differ between versions. If yours rejects these:
#
#   BRAID_AGENT_ARGS="--full-auto"
#
# or drop to the generic adapter and give it the whole command line.

: "${BRAID_AGENT_ARGS:=--full-auto}"

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

agent_command() {
    local worktree="$1" model="$2" prompt="$3"
    # shellcheck disable=SC2086  # BRAID_AGENT_ARGS is a flag list on purpose
    if [[ -n "$model" ]]; then
        printf 'codex exec %s --model %q %q' "$BRAID_AGENT_ARGS" "$model" "$prompt"
    else
        printf 'codex exec %s %q' "$BRAID_AGENT_ARGS" "$prompt"
    fi
}

agent_transcript_dir() { printf '%s/.codex/sessions' "$HOME"; }
