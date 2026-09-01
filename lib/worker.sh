#!/usr/bin/env bash
# What a worker is doing, read off the filesystem.
#
# .braid/status is the contract between a worker and the orchestrator. It is written
# *for* the worker — by its agent's stop hook if it has one, by finish.sh when the
# process exits otherwise — so it happens whether the agent cooperated, crashed, or was
# never installed.
#
# The agent development environment's panel is a nicer view of this same file, never
# the source of truth. That is why the same wave runs identically in orca, herdr, tmux
# or detached, and why status works over ssh from a phone.

[[ -n "${_BRAID_WORKER_SH:-}" ]] && return 0
_BRAID_WORKER_SH=1

# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

worker_field() {
    local worktree="${1:?worktree}" key="${2:?key}"
    [[ -f "$worktree/.braid/$key" ]] && cat "$worktree/.braid/$key"
}

worker_status_field() {
    local worktree="${1:?worktree}" key="${2:?key}"
    [[ -f "$worktree/.braid/status" ]] || return 1
    sed -n "s/^${key}=//p" "$worktree/.braid/status" | head -1
}

# Where this worker's agent keeps transcripts, if it keeps any. Read per worktree
# rather than from the current configuration: a wave may mix agents, and the worker
# recorded which one it got.
worker_transcript_dir() {
    local worktree="${1:?worktree}" agent
    agent=$(worker_field "$worktree" agent) || return 0
    [[ -n "$agent" && -f "$BRAID_HOME/lib/agents/$agent.sh" ]] || return 0
    (
        # shellcheck disable=SC1090
        source "$BRAID_HOME/lib/agents/$agent.sh"
        declare -F agent_transcript_dir >/dev/null && agent_transcript_dir
    )
}

# Seconds since anything about this worker last moved, or nothing when no signal
# resolves. Silence must never read as death: a worktree that cannot be measured is
# never called stale.
#
# Newest signal wins, and each catches something the others miss:
#   - the agent's transcript, rewritten every turn — the only one that sees an agent
#     thinking, reading or editing without touching git;
#   - .braid/*.log, which grows through a long build or test run;
#   - the git index, which moves on every add and commit.
worker_idle_seconds() {
    local worktree="${1:?worktree}" gitdir transcripts
    gitdir=$(git -C "$worktree" rev-parse --git-dir 2>/dev/null || echo "")
    transcripts=$(worker_transcript_dir "$worktree")
    python3 - "$worktree" "$gitdir" "$transcripts" <<'PY'
import os
import re
import sys
import time

worktree, gitdir = sys.argv[1], sys.argv[2]
transcripts = sys.argv[3] if len(sys.argv) > 3 else ""
newest = 0.0


def seen(path):
    global newest
    try:
        newest = max(newest, os.path.getmtime(path))
    except OSError:
        pass


braid_dir = os.path.join(worktree, ".braid")
seen(braid_dir)
try:
    for entry in os.listdir(braid_dir):
        if entry.endswith(".log"):
            seen(os.path.join(braid_dir, entry))
except OSError:
    pass
if gitdir:
    seen(os.path.join(gitdir, "index"))

# Transcript directories are named after the encoded worktree path, which agents
# truncate at different lengths. Matching either direction only ever makes a worker
# look more alive than it is, never less — which is the safe way to be wrong here.
slug = re.sub(r"[^A-Za-z0-9]", "-", worktree)
try:
    for name in os.listdir(transcripts) if transcripts else []:
        if not (slug.startswith(name) or name.startswith(slug)):
            continue
        session = os.path.join(transcripts, name)
        for entry in os.listdir(session):
            if entry.endswith(".jsonl"):
                seen(os.path.join(session, entry))
except OSError:
    pass

if newest:
    print(int(time.time() - newest))
PY
}

# working          no terminal state yet, and something moved recently
# stale            no terminal state, and nothing has moved — go and read it
# done             finished, committed, wrote a report
# done-no-report   committed but said nothing — read the diff, silence is not success
# dirty            stopped with uncommitted work; a rebase would lose it
#
# `stale` is the state a waiting loop must respect. `working` only means "no status
# file", which a worker that died before its first turn also satisfies — so waiting for
# everything to reach `done` waits forever on exactly the failure you most need to see.
worker_state() {
    local worktree="${1:?worktree}" state idle
    state=$(worker_status_field "$worktree" state) && [[ -n "$state" ]] && {
        printf '%s' "$state"
        return 0
    }
    idle=$(worker_idle_seconds "$worktree")
    if [[ -n "$idle" && "$idle" -gt "$BRAID_STALE_SECONDS" ]]; then
        printf 'stale'
    else
        printf 'working'
    fi
}

worker_is_terminal() {
    case "$(worker_state "$1")" in
        done | done-no-report | dirty | stale) return 0 ;;
        *) return 1 ;;
    esac
}
