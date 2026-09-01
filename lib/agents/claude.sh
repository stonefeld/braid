#!/usr/bin/env bash
# Adapter — Claude Code.
#
# The only agent with hooks, which is why it is the natural choice for the orchestrator
# seat: a PreToolUse guard runs *before* the permission system, so it denies a push
# with approvals off exactly as it would with them on. Workers do not need that — they
# are sealed in a worktree behind a pre-push hook — so putting the orchestrator on
# Claude and the workers on something else is a reasonable configuration.
#
# Everything below the launch command is a bonus. braid works without any of it.

: "${BRAID_PERMISSION_MODE:=bypassPermissions}"

agent_available() { command -v claude >/dev/null 2>&1; }

agent_version() { claude --version 2>/dev/null | head -1; }

agent_seat_model() {
    case "${1:?seat}" in
        design) echo fable ;;
        orchestrate) echo opus ;;
        work | *) echo sonnet ;;
    esac
}

agent_models() { echo "fable opus sonnet haiku"; }

# The contract arrives through the SessionStart hook, so the prompt only has to point
# at the slice. Keeping it short matters: it is what the agent reads first.
agent_injects_contract() { return 0; }

agent_command() {
    local worktree="$1" model="$2" prompt="$3"
    printf 'claude --model %q --permission-mode %q %q' \
        "$model" "$BRAID_PERMISSION_MODE" "$prompt"
}

# -p, because a detached launcher has no tty and the TUI needs one.
agent_command_headless() {
    local worktree="$1" model="$2" prompt="$3"
    printf 'claude -p --model %q --permission-mode %q %q' \
        "$model" "$BRAID_PERMISSION_MODE" "$prompt"
}

# Where transcripts live, for liveness. Claude Code encodes the worktree path by
# replacing every non-alphanumeric character with a dash, then truncating.
agent_transcript_dir() { printf '%s/.claude/projects' "$HOME"; }
