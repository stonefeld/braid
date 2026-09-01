# braid

Run several coding agents in parallel, each in its own git worktree, then weave their
branches back into one feature branch that reads as though it had all been written
there in order.

Works with any agent CLI — Claude Code, Codex, or anything you can put on a command
line — and in any terminal setup, from a full agent development environment down to
plain tmux.

```bash
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
```

> **Status: under construction.** The design is settled and written down in
> [`DESIGN.md`](DESIGN.md); the implementation is being built against it. Nothing here
> is stable yet.

## What it does

You settle a design, cut it into slices, and hand the list to an orchestrator agent.
It launches one worker per slice — each in an isolated worktree with its own branch,
port and environment — waits for them, judges their work against the diff rather than
their own report, and integrates them one at a time with `rebase` then `merge
--ff-only`, so the history stays linear.

That last part is the braid: parallel strands, one rope.

## What it is not

braid has no opinion about how you arrive at a design. Grilling, PRDs, issue writing —
those are house decisions, and it ships none of them. It recommends a set of skills at
setup time and works fine with none of them. What it owns starts at *"these slices are
launchable"* and ends at *"the feature branch is green"*.

## Documentation

- [`DESIGN.md`](DESIGN.md) — every decision behind this, and why
- [`AGENTS.md`](AGENTS.md) — house rules for working on braid itself

## License

MIT
