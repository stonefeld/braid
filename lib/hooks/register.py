#!/usr/bin/env python3
"""Register braid's hooks in a repository's .claude/settings.json.

Merged into whatever is there, and refused outright when the file will not parse:
somebody hand-edited it, and losing their configuration to a setup command is not
forgiven. Commands are registered by name — "braid hook guard-remote" — never by
path, which is what lets the engine live outside the repository.
"""

import json
import pathlib
import sys

path = pathlib.Path(".claude/settings.json")
want = {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "braid hook guard-remote", "timeout": 10}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "braid hook session-start", "timeout": 60}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "braid hook stop", "timeout": 30}]}],
}

settings = {}
if path.exists():
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # Never clobber a file we cannot parse. Somebody hand-edited it, and losing
        # their configuration to a setup command is not forgiven.
        print("  .claude/settings.json is not valid JSON — fix it and run braid init again", file=sys.stderr)
        raise SystemExit(1)

hooks = settings.setdefault("hooks", {})
added = []
for event, entries in want.items():
    existing = hooks.setdefault(event, [])
    for entry in entries:
        command = entry["hooks"][0]["command"]
        if not any(h.get("command") == command for group in existing for h in group.get("hooks", [])):
            existing.append(entry)
            added.append(f"{event}: {command}")

# Only when something changed. Writing regardless reformatted whoever's file to
# indent=2 on every run and reported that nothing had been added — a diff in a committed
# file for a command that did nothing.
if added:
    path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    for line in added:
        print(f"  hook {line}")
else:
    print("  hooks already registered")
