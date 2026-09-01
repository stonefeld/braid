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


def contract_for(root: Path) -> str:
    """The project's own contract if it wrote one, else the bundled default.

    The repository's own copy wins. A project adding house rules writes
    docs/worker-contract.md and edits that; the bundled one lives with the engine,
    outside the repository, and is replaced by every upgrade.
    """
    candidates = [root / "docs" / "worker-contract.md"]
    home = os.environ.get("BRAID_HOME")
    if home:
        candidates.append(Path(home) / "docs" / "worker-contract.md")
    for candidate in candidates:
        if candidate.exists():
            return candidate.read_text(encoding="utf-8")
    return ""


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
