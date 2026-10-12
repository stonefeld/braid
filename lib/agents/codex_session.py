#!/usr/bin/env python3
"""What a Codex worker's session says about itself.

    codex_session.py <sessions dir> <worktree> <since>

Prints one line — ``<moved> <turn> <at>`` — or nothing when no session for the worktree
has been written since ``<since>``. ``moved`` is when any of its sessions was last
written; ``turn`` is ``running``, ``ended`` or ``unknown``; ``at`` is when that was.

Sessions are filed by date, not by directory, and name their working directory in the
first line, so a worker's is found by reading that line in every file written since the
worker was made. A subagent's session is the worker still moving, never the worker's own
turn: it ends long before the turn that started it does.

This reads a format nobody promised. It fails toward what braid did before it could read
anything: an event it does not recognise is a turn it does not know about.
"""

import calendar
import json
import os
import sys
import time

TURNS = {"task_started": "running", "task_complete": "ended", "turn_aborted": "ended"}


def written(record: dict, fallback: float) -> int:
    stamp = str(record.get("timestamp") or "")[:19]
    try:
        return calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return int(fallback)


def sessions(root: str, worktree: str, since: float) -> list[tuple[float, str, bool]]:
    """Every session written for the worktree since ``since``: (moved, path, own)."""
    found = []
    for folder, _, names in os.walk(root):
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(folder, name)
            try:
                moved = os.path.getmtime(path)
                if moved < since:
                    continue
                with open(path, encoding="utf-8", errors="replace") as handle:
                    meta = json.loads(handle.readline()).get("payload") or {}
                cwd = os.path.realpath(str(meta.get("cwd") or ""))
            except (OSError, ValueError, AttributeError):
                continue
            if cwd == worktree:
                found.append((moved, path, meta.get("thread_source") != "subagent"))
    return found


def turn(path: str, fallback: float) -> tuple[str, int]:
    """The last turn event in a session, and when it was written."""
    state, at = "unknown", 0
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if '"event_msg"' not in line:
                    continue
                try:
                    record = json.loads(line)
                    kind = (record.get("payload") or {}).get("type")
                except (ValueError, AttributeError):
                    continue
                if record.get("type") == "event_msg" and kind in TURNS:
                    state, at = TURNS[kind], written(record, fallback)
    except OSError:
        pass
    return state, at


def main(argv: list[str]) -> int:
    root, worktree = argv[1], os.path.realpath(argv[2])
    try:
        since = float(argv[3]) if len(argv) > 3 else 0.0
    except ValueError:
        since = 0.0
    found = sessions(root, worktree, since)
    if not found:
        return 0
    moved = max(at for at, _, _ in found)
    own = [(at, path) for at, path, mine in found if mine]
    state, at = turn(*max(own)[::-1]) if own else ("unknown", 0)
    print(int(moved), state, at)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
