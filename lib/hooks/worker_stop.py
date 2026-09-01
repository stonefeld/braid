#!/usr/bin/env python3
"""Stop hook — records a worker's finishing state for the orchestrator.

The orchestrator polls .braid/status on the filesystem rather than asking the agent
development environment, so the same wave runs identically inside orca, inside herdr,
inside plain tmux, or detached. The ADE is the view; this file is the control plane.

A worker that stops with uncommitted work gets pushed back exactly once: leaving changes
on disk means the orchestrator's rebase silently drops them.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

PREFIX = os.environ.get("BRAID_BRANCH_PREFIX", "agent")


def git(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def write_status(root: Path, state: str, branch: str, head: str) -> None:
    braid_dir = root / ".braid"
    braid_dir.mkdir(exist_ok=True)
    (braid_dir / "status").write_text(
        f"state={state}\nbranch={branch}\nhead={head}\nat={int(time.time())}\n",
        encoding="utf-8",
    )


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        payload = {}

    root = Path(payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    if not branch.startswith(f"{PREFIX}/"):
        sys.exit(0)

    head = git(root, "rev-parse", "--short", "HEAD")
    # .braid/ excluded explicitly, not left to .gitignore: it holds the report, the
    # session log and this status file, so a worker that did exactly what it was asked
    # would otherwise be blocked for having a dirty tree it created by reporting.
    dirty = bool(git(root, "status", "--porcelain", "--", ":!.braid"))
    report = (root / ".braid" / "report.md").exists()

    # stop_hook_active means we already pushed back once this turn. Blocking again would
    # be a loop, so record the state and let the orchestrator see `dirty`.
    if dirty and not payload.get("stop_hook_active"):
        write_status(root, "dirty", branch, head)
        print(
            json.dumps(
                {
                    "decision": "block",
                    "reason": (
                        "You have uncommitted changes. The orchestrator rebases your branch and "
                        "never sees your working tree, so anything left uncommitted is lost. "
                        "Commit everything, then write .braid/report.md with what you did, what "
                        "you verified, and anything the orchestrator needs to know."
                    ),
                }
            )
        )
        sys.exit(0)

    if dirty:
        write_status(root, "dirty", branch, head)
    elif not report:
        write_status(root, "done-no-report", branch, head)
    else:
        write_status(root, "done", branch, head)
    sys.exit(0)


if __name__ == "__main__":
    main()
