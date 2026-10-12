#!/usr/bin/env python3
"""The Codex session reader, against sessions shaped like the real ones.

Each case writes the lines Codex writes — a session_meta first, then event_msg records —
into a sessions tree filed by date, exactly as ~/.codex/sessions is, and asks the reader
what the worker is doing. No Codex is run. What this cannot say is whether the real CLI
still writes this shape; what it does say is that braid reads the shape it was shown.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

READER = pathlib.Path(__file__).resolve().parent.parent / "lib" / "agents" / "codex_session.py"


def meta(cwd: str, source: str = "user") -> dict:
    return {
        "timestamp": "2026-09-29T18:29:51.300Z",
        "type": "session_meta",
        "payload": {"id": "x", "cwd": cwd, "originator": "codex-tui", "thread_source": source},
    }


def event(kind: str, stamp: str) -> dict:
    return {"timestamp": stamp, "type": "event_msg", "payload": {"type": kind, "turn_id": "t"}}


class Reader(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name, "sessions")
        self.worktree = pathlib.Path(self.tmp.name, "worktrees", "agent-01-login")
        self.worktree.mkdir(parents=True)
        self.count = 0

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def session(self, records: list, day: str = "2026/09/29", moved: float = 0) -> pathlib.Path:
        self.count += 1
        folder = self.root / day
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"rollout-{self.count}.jsonl"
        path.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")
        if moved:
            os.utime(path, (moved, moved))
        return path

    def read(self, since: str = "0") -> list[str]:
        out = subprocess.run(
            [sys.executable, str(READER), str(self.root), str(self.worktree), since],
            capture_output=True, text=True, check=True,
        ).stdout.split()
        return out

    def test_nothing_without_a_session(self) -> None:
        self.assertEqual(self.read(), [])

    def test_a_started_turn_is_running(self) -> None:
        self.session([meta(str(self.worktree)), event("task_started", "2026-09-29T18:29:51.336Z")])
        moved, turn, at = self.read()
        self.assertEqual(turn, "running")
        self.assertEqual(at, "1790706591")

    def test_a_completed_turn_has_ended(self) -> None:
        self.session([
            meta(str(self.worktree)),
            event("task_started", "2026-09-29T18:29:51.336Z"),
            event("task_complete", "2026-09-29T18:47:59.779Z"),
        ])
        self.assertEqual(self.read()[1:], ["ended", "1790707679"])

    def test_an_interrupted_turn_has_ended_too(self) -> None:
        self.session([
            meta(str(self.worktree)),
            event("task_started", "2026-09-29T18:29:51.336Z"),
            event("turn_aborted", "2026-09-29T18:47:59.779Z"),
        ])
        self.assertEqual(self.read()[1], "ended")

    def test_a_correction_is_a_new_turn(self) -> None:
        self.session([
            meta(str(self.worktree)),
            event("task_started", "2026-09-29T18:29:51.336Z"),
            event("task_complete", "2026-09-29T18:47:59.779Z"),
            event("task_started", "2026-09-29T23:43:40.393Z"),
        ])
        self.assertEqual(self.read()[1:], ["running", "1790725420"])

    def test_another_worktree_is_not_this_one(self) -> None:
        self.session([meta(str(self.worktree) + "-other"), event("task_started", "2026-09-29T18:29:51.336Z")])
        self.assertEqual(self.read(), [])

    def test_a_subagent_moves_the_worker_but_is_not_its_turn(self) -> None:
        self.session([
            meta(str(self.worktree)),
            event("task_started", "2026-09-29T18:29:51.336Z"),
        ], moved=1_790_706_600)
        self.session([
            meta(str(self.worktree), source="subagent"),
            event("task_started", "2026-09-29T18:30:00.000Z"),
            event("task_complete", "2026-09-29T18:31:00.000Z"),
        ], moved=1_790_706_700)
        moved, turn, _ = self.read()
        self.assertEqual(moved, "1790706700")
        self.assertEqual(turn, "running")

    def test_only_a_subagent_is_still_not_a_turn(self) -> None:
        self.session([meta(str(self.worktree), source="subagent"), event("task_complete", "2026-09-29T18:31:00.000Z")])
        self.assertEqual(self.read()[1:], ["unknown", "0"])

    def test_a_session_older_than_the_worker_is_a_previous_worker(self) -> None:
        self.session([meta(str(self.worktree)), event("task_complete", "2026-09-29T18:47:59.779Z")], moved=1_000)
        self.assertEqual(self.read(since="2000"), [])

    def test_the_newest_of_several_sessions_answers(self) -> None:
        self.session([meta(str(self.worktree)), event("task_complete", "2026-09-29T18:47:59.779Z")], moved=1_790_706_600)
        self.session([meta(str(self.worktree)), event("task_started", "2026-09-29T20:00:00.000Z")], day="2026/09/30", moved=1_790_706_900)
        self.assertEqual(self.read()[1], "running")

    def test_an_event_it_does_not_know_is_a_turn_it_does_not_know(self) -> None:
        self.session([meta(str(self.worktree)), event("something_new", "2026-09-29T18:29:51.336Z")])
        self.assertEqual(self.read()[1], "unknown")

    def test_a_malformed_line_does_not_stop_the_read(self) -> None:
        path = self.session([meta(str(self.worktree)), event("task_started", "2026-09-29T18:29:51.336Z")])
        with path.open("a", encoding="utf-8") as handle:
            handle.write('{"type": "event_msg", not json\n')
            handle.write(json.dumps(event("task_complete", "2026-09-29T18:47:59.779Z")) + "\n")
        self.assertEqual(self.read()[1], "ended")

    def test_a_timestamp_it_cannot_read_falls_back_to_the_file(self) -> None:
        self.session([meta(str(self.worktree)), event("task_complete", "yesterday")], moved=1_790_000_000)
        self.assertEqual(self.read()[2], "1790000000")


if __name__ == "__main__":
    unittest.main()
