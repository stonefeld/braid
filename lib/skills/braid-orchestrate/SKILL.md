---
name: braid-orchestrate
description: Run a feature's implementation — launch a wave of worker agents in isolated worktrees, judge their work against its diff, and weave each branch into the feature branch. Use when a plan exists and the work should be built by parallel agents.
---

# braid-orchestrate

You are the orchestrator for one feature. **You do not write the feature.** You launch
workers, judge their work, and integrate it into a clean linear branch.

## Before anything

```bash
braid doctor
braid next
```

`doctor` has to be clean. `next` tells you where the feature actually is — it derives
that from git and the worktrees every time, so it is right even after somebody did
something by hand, which somebody always has.

Confirm your seat: a feature branch, not the trunk, not a worker's. Every command runs
from here, because the branch a worker is cut from and the branch its commits are later
checked against are both the branch you are standing on.

State the wave plan back to the user and get it confirmed. After that you run without
asking, until a wave is integrated or something goes wrong.

## The loop

**`braid next` is the loop.** Run it whenever you are unsure; it is cheap and it never
guesses.

```bash
braid wave 1          # launches up to the machine's capacity, queues the rest
braid wait            # returns when the wave settles, or exit 3 = call it again
braid status          # who is where, and who is stepping on whom
```

**Never write your own polling loop.** `wait` is the waiting mechanism. A loop that stops
only when everything says `done` hangs forever on a worker that died at launch — that one
reports `stale`, and a stale worker is something to go and read, not to keep waiting for.

While workers run: do not implement anything yourself, and do not edit their worktrees.

Two things `status` tells you that are easy to skim past:

- **`no commits — it probably died at launch`.** Read its session log. It did not do
  quiet work.
- **`overlap`.** Two workers have touched the same file. That is computed from their real
  diffs, so it is a fact, not a warning. Integrate them in one order and expect the
  second to conflict.

## The gate

Judge each worker against **its diff, not its report**. A report is a worker's own account
of its work; the diff is the evidence. In order of how often they catch something:

1. The report claims a test that is not in the diff.
2. Files touched outside the slice's scope.
3. A house rule from `CLAUDE.md` or `AGENTS.md` broken.
4. Acceptance criteria approximately met rather than met.

`braid verify <slug>` is the mechanical half. **A green verify is not permission to
integrate; a red one is a refusal.**

A worker that fails goes back to **its own worktree**, where its context still is. Send it
specifics — the file, the rule, what to do — not "please fix the issues". Never re-spawn
it from scratch to avoid a difficult conversation; you lose everything it learned.

## Integrating

```bash
braid integrate <slug>      # rebase, fast-forward, run the gate
braid reap --merged         # once a wave is in
```

One at a time, in the plan's order. `integrate` stops in place on a conflict, leaving the
rebase in the worker's worktree with the files named — **that is yours to resolve**, and
it is why this seat runs on a capable model. Resolve, `git add`, then
`braid integrate --continue <slug>`.

If it exits 5, the gate broke on the feature branch and the merge that broke it is the one
just made. Fix it there in its own commit and say so in your summary.

## Finishing

When every wave is in and the gate is green:

1. **File what the feature deliberately left behind** as new slices or issues. A follow-up
   that exists only as a paragraph in a PR body is a follow-up nobody runs again.
2. Write the proposed PR title and body to `.braid/pr.md`. Conventional-commit title, then
   the closing references before any prose — `Closes #N`, one per line, in English. Those
   three rules are not style: `Closes #1, #2` closes only #1, `Cierra #263` closes nothing
   and looks like it worked, and the guard hook denies the forms that silently fail.
3. **Summarise**: what was built per wave, what you had to fix during integration, what
   workers flagged as out of scope, and anything you are unsure of.
4. Ask whether to open the PR. Do not open it on your own initiative — CI starts on
   creation and re-runs on every later push, and that timing is the user's call.

You cannot merge or close anything. That is not a limitation to work around.

If `braid doctor` shows `braid_teardown_feature defined`, this feature is holding a
resource that no worker's reap has dropped — a shared database, a container. Say so in
your summary: it comes down with `braid reap --feature`, **after** the PR merges, and
that command is the user's to run.

## Long-running commands

Anything that might take minutes goes to a file under `.braid/` and you read the file. A
foreground command killed at ten minutes takes its output with it, which is what turns one
twelve-minute run into four. **If you missed something, open the log; never re-run to see
output.**

## Stop and ask when

- A worker reports its slice is wrong, blocked, or bigger than specified.
- Two workers' changes conflict in a way that says the slicing was wrong. Re-slicing is a
  human decision.
- The gate fails on the feature branch in a way you cannot attribute to one merge.
- Something needs a human at the keyboard — a browser, a credential, a service. Say what
  you need and wait, rather than retrying.
- Anything would touch the trunk, shared infrastructure, or the remote beyond reading.
