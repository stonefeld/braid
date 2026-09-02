#!/usr/bin/env python3
"""SessionStart hook — loads a worker's contract and its slice.

Fires in every session, but does nothing unless the branch is <prefix>/*. That keeps
ordinary sessions — yours, the orchestrator's — free of the context tax.

The contract is injected here rather than passed in the spawn prompt so it survives a
context compaction, a `claude --continue`, and a worker the human started by hand.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

PREFIX = os.environ.get("BRAID_BRANCH_PREFIX", "agent")


def emit(context: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "SessionStart",
                    "additionalContext": context,
                }
            }
        )
    )
    sys.exit(0)


def branch_of(cwd: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


COMPOSE = 'cd "$1" && . "$BRAID_HOME/lib/contract.sh" && contract_compose "$(primary_checkout)"'


def contract_for(root: Path) -> str:
    """What spawn composed for this worktree.

    `.braid/contract.md` is the answer whenever braid made the worktree: the bundled
    contract, plus the repository's `docs/worker-rules.md` under `## House rules`, or
    its `docs/worker-contract.md` replacing both. Reading the file rather than
    repeating the lookup is what stops this path and the prompt path from drifting.

    The fallback is for a worktree somebody made by hand on an agent/* branch, and it
    runs the same composition through the shell rather than reimplementing it here.
    """
    composed = root / ".braid" / "contract.md"
    if composed.exists():
        return composed.read_text(encoding="utf-8")
    if not os.environ.get("BRAID_HOME"):
        return ""
    try:
        result = subprocess.run(
            ["bash", "-c", COMPOSE, "bash", str(root)],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout if result.returncode == 0 else ""


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        payload = {}

    root = Path(payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    if not branch_of(root).startswith(f"{PREFIX}/"):
        sys.exit(0)

    parts = []

    contract = contract_for(root)
    if contract:
        parts.append(contract)

    assigned = root / ".braid" / "slice.md"
    if assigned.exists():
        parts.append("# Your assigned slice\n\n" + assigned.read_text(encoding="utf-8"))
    else:
        parts.append(
            f"# No assigned slice\n\nThis worktree is on a {PREFIX}/* branch but has no "
            ".braid/slice.md. Ask what you are meant to implement before changing anything."
        )

    emit("\n\n---\n\n".join(parts))


if __name__ == "__main__":
    main()
