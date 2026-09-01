#!/usr/bin/env python3
"""Turn a set of slices into a schedule.

A wave is not a level of the dependency graph. It is a schedule, and three constraints
separate the two:

  - `setup: yes` serialises. Two slices with no dependency between them still cannot
    share a wave if both take the expensive provision path, because they share migration
    history and generated state. That is a resource constraint, not a logical one.
  - Machine capacity. Nine parallel agents kill some laptops and not others. The moment
    a cap exists, a wave stops being a graph level.
  - Collisions without dependency. Two slices that do not block each other but will fight
    over the same file. Recording that as a blocker would be a lie — it is an exclusion,
    not a dependency — so it is a human's edit to the plan, not something derived here.

Reads TSV on stdin: id, complexity, setup(0|1), blockers(space separated).
Writes the plan's wave lines on stdout, and anything worth saying on stderr.
"""

import sys


def main() -> int:
    slices = {}
    order = []
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 4:
            parts.append("")
        ident, complexity, setup, blockers = parts[:4]
        slices[ident] = {
            "complexity": complexity or "standard",
            "setup": setup == "1",
            "blockers": [b for b in blockers.split() if b],
        }
        order.append(ident)

    if not slices:
        print("no slices found", file=sys.stderr)
        return 1

    # A blocker outside this set is legitimate — a slice may wait on work that is not
    # part of this feature — but it cannot be scheduled here, so it is reported and
    # treated as already satisfied rather than silently dropped.
    external = set()
    for ident, slice_ in slices.items():
        for blocker in slice_["blockers"]:
            if blocker not in slices:
                external.add(blocker)
    if external:
        print(
            "blockers outside this feature, assumed already done: "
            + ", ".join(sorted(external)),
            file=sys.stderr,
        )

    # Longest-path levelling rather than plain Kahn: a slice belongs after *all* its
    # blockers, so its level is one past the deepest of them.
    level = {}

    def depth(ident, seen):
        if ident in level:
            return level[ident]
        if ident in seen:
            cycle = " -> ".join(list(seen) + [ident])
            print(f"dependency cycle: {cycle}", file=sys.stderr)
            raise SystemExit(2)
        seen = seen + [ident]
        blockers = [b for b in slices[ident]["blockers"] if b in slices]
        level[ident] = 1 + max((depth(b, seen) for b in blockers), default=-1)
        return level[ident]

    for ident in order:
        depth(ident, [])

    try:
        capacity = max(1, int(sys.argv[1]))
    except (IndexError, ValueError):
        capacity = 4

    waves = []
    for tier in sorted(set(level.values())):
        # Declaration order within a tier, so a re-run of plan produces the same
        # schedule and the diff of a regenerated plan is empty when nothing changed.
        pending = [i for i in order if level[i] == tier]
        while pending:
            wave, rest, took_setup = [], [], False
            for ident in pending:
                if len(wave) >= capacity:
                    rest.append(ident)
                    continue
                if slices[ident]["setup"]:
                    if took_setup:
                        rest.append(ident)
                        continue
                    took_setup = True
                wave.append(ident)
            waves.append(wave)
            pending = rest

    for number, wave in enumerate(waves, start=1):
        print(f"wave {number}: " + ", ".join(wave))
    return 0


if __name__ == "__main__":
    sys.exit(main())
