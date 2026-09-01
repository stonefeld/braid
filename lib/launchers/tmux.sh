#!/usr/bin/env bash
# Launcher — tmux.
#
# Perfectly good for running a wave. One session per worker, named after its branch, so
# `tmux ls` is a wave view and attaching is one command.

launcher_available() { command -v tmux >/dev/null 2>&1; }

launcher_launch() {
    local worktree="${1:?worktree}" title="${2:?title}" command="${3:?command}"
    launcher_probe "tmux new-session -d -s $title"
    tmux new-session -d -s "$title" -c "$worktree" "bash -lc $(printf '%q' "$command")" || return 1
    note "tmux session $title (tmux attach -t $title)"
}

launcher_forget() {
    local title
    title=$(basename "${1:?worktree}")
    tmux kill-session -t "$title" 2>/dev/null || true
}
