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

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"

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
    local worktree="${1:?worktree}" agent file
    agent=$(worker_field "$worktree" agent) || return 0
    [[ -n "$agent" ]] || return 0
    file=$(agent_file "$agent") || return 0
    (
        # shellcheck disable=SC1090
        source "$file"
        declare -F agent_transcript_dir >/dev/null && agent_transcript_dir
    )
}

# What the worker's own session says, for an agent whose adapter can read one: when it
# last moved, whether its latest turn is `running` or `ended`, and since when. Nothing
# for an agent that cannot say, which is most of them and is not an error.
#
# Only sessions written since the worker was made are looked at, so a worktree path that
# is used twice never answers with the first worker's session.
worker_session() {
    local worktree="${1:?worktree}" agent file since
    agent=$(worker_field "$worktree" agent) || return 0
    [[ -n "$agent" ]] || return 0
    file=$(agent_file "$agent") || return 0
    since=$(stat -c %Y "$worktree/.braid/base" 2>/dev/null ||
        stat -f %m "$worktree/.braid/base" 2>/dev/null || echo 0)
    (
        # shellcheck disable=SC1090
        source "$file"
        declare -F agent_session >/dev/null && agent_session "$worktree" "$since"
    ) 2>/dev/null
}

# Seconds since anything about this worker last moved, or nothing when no signal
# resolves. Silence must never read as death: a worktree that cannot be measured is
# never called stale.
#
# Newest signal wins, and each catches something the others miss:
#   - the agent's transcript, rewritten every turn — the only one that sees an agent
#     thinking, reading or editing without touching git. Found by the directory it is
#     filed under, or handed over by an adapter that reads its own sessions;
#   - .braid/*.log, which grows through a long build or test run;
#   - the git index, which moves on every add and commit.
worker_idle_seconds() {
    local worktree="${1:?worktree}" gitdir transcripts session
    gitdir=$(git -C "$worktree" rev-parse --git-dir 2>/dev/null || echo "")
    transcripts=$(worker_transcript_dir "$worktree")
    session=$(worker_session "$worktree")
    python3 - "$worktree" "$gitdir" "$transcripts" "${session%% *}" <<'PY'
import os
import re
import sys
import time

worktree, gitdir = sys.argv[1], sys.argv[2]
transcripts = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    newest = float(sys.argv[4])
except (IndexError, ValueError):
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
#
# .braid/status is a record of one moment: the agent stopped, and this is what git said.
# Where the agent's own session can be read and has turned since, the session outranks
# it. A turn that is running is a worker that is working, whatever it had finished
# before — that is a worker sent back with a correction. A turn that has ended is
# settled now, and what it settled as is asked of git now, the way finish.sh asks.
worker_state() {
    local worktree="${1:?worktree}" state idle recorded turn turned
    state=$(worker_status_field "$worktree" state) || state=""
    recorded=$(worker_status_field "$worktree" at) || recorded=""
    read -r _ turn turned < <(worker_session "$worktree") || true
    case "${recorded:-0}${turned:-0}" in *[!0-9]*) turn="" ;; esac
    if [[ -n "${turn:-}" && "${turned:-0}" -gt "${recorded:-0}" ]]; then
        case "$turn" in
            running) state="" ;;
            ended)
                worker_settled_state "$worktree"
                return 0
                ;;
        esac
    fi
    [[ -z "$state" ]] || {
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

# What a worker that has stopped is, read off git at the moment of asking. finish.sh
# holds the same three lines, because it runs from a copy inside the worktree and cannot
# source this file; the order is argued there.
worker_settled_state() {
    local worktree="${1:?worktree}"
    if [[ -n "$(git -C "$worktree" status --porcelain -- ':!.braid' 2>/dev/null)" ]]; then
        printf 'dirty'
    elif [[ -f "$worktree/.braid/report.md" ]]; then
        printf 'done'
    else
        printf 'done-no-report'
    fi
}

# The files a worker has actually changed, relative to the branch it was cut from.
# Derived from the diff rather than declared up front: a slice was once asked to list the
# files it would touch, and it was abandoned because a refactor that touches four hundred
# files never lists them — so the field filled with "**" and the check it justified
# became decorative, which is worse than absent because it looks like protection.
worker_files() {
    local worktree="${1:?worktree}" base
    base=$(worker_base "$worktree") || return 0
    [[ -n "$base" ]] || return 0
    git -C "$worktree" diff --name-only "$base...HEAD" 2>/dev/null
}

# Files more than one worker in this wave has touched, with who touched them.
#
# This is the rule the whole thing depends on — no two slices in a wave touch the same
# file — and until now the only thing enforcing it was an orchestrator's judgement at
# planning time. Computed from what happened rather than what was intended, it costs one
# git diff per worker and it can be shown **while the wave is still running**, which is
# hours before the conflict would otherwise appear.
wave_overlaps() {
    local scope="${1:-mine}" worktree branch
    while read -r worktree; do
        [[ -n "$worktree" ]] || continue
        branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
        worker_files "$worktree" | while read -r file; do
            [[ -n "$file" ]] || printf ''
            [[ -n "$file" ]] && printf '%s\t%s\n' "$file" "${branch#*/}"
        done
    done < <(worker_worktrees "$scope") |
        LC_ALL=C sort -u |
        awk -F'\t' '
            # count is incremented first: referencing files[$1] to test it would create
            # the key, so `$1 in files` is true even the first time round.
            { if (count[$1]++) files[$1] = files[$1] ", " $2; else files[$1] = $2 }
            END { for (f in files) if (count[f] > 1) print f "\t" files[f] }
        ' | LC_ALL=C sort
}

worker_is_terminal() {
    case "$(worker_state "$1")" in
        done | done-no-report | dirty | stale) return 0 ;;
        *) return 1 ;;
    esac
}
