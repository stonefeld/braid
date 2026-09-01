#!/usr/bin/env bash
# Run one of braid's agent hooks.
#
#   braid hook session-start     inject the contract and the slice into a worker session
#   braid hook stop              record a worker's finishing state, push back on a dirty tree
#   braid hook guard-remote      deny the remote before the permission system runs
#
# Hooks are registered in a repository's .claude/settings.json by this name, with no
# path in it:
#
#   "command": "braid hook guard-remote"
#
# That is what lets the engine live outside the repository. A settings.json pointing at
# an absolute path would break the moment braid moved, and one pointing inside the repo
# would need the engine vendored there — which is the thing the whole install model
# exists to avoid.
#
# Every hook reads its payload on stdin and is silent unless it has something to say.

set -uo pipefail

# shellcheck source=core.sh
source "$BRAID_HOME/lib/core.sh"

case "${1:-}" in
    session-start) exec python3 "$BRAID_HOME/lib/hooks/worker_session.py" ;;
    stop) exec python3 "$BRAID_HOME/lib/hooks/worker_stop.py" ;;
    guard-remote) exec python3 "$BRAID_HOME/lib/hooks/guard_remote.py" ;;
    "" | -h | --help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 0
        ;;
    *) die "unknown hook '$1' (expected: session-start, stop, guard-remote)" ;;
esac
