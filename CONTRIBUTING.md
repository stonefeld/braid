# Contributing

How to get a change into braid. The rules a change has to *keep* are in
[`AGENTS.md`](AGENTS.md); the reasons behind them are in [`DESIGN.md`](DESIGN.md). This
file is the process around both.

## Before you write anything

**Is what you want to do a decision braid has already made?** [`DESIGN.md`](DESIGN.md)
§ 12 lists what is deliberately not built and why — Windows outside WSL2, per-slice agent
selection, a `files:` field, Codex's hooks. Those are not gaps waiting for a pull request.
They are positions, and some of them are wrong, but the way to change one is to argue with
the reason rather than to send code that contradicts it.

> Say you want braid to work on native Windows. § 4 explains why it is refused: MSYS path
> translation against a native Windows `git`, no tmux so every launcher collapses to
> detached, `printf '%q'` quoting crossing into npm `.cmd` shims. A pull request that
> deletes the refusal in `install.sh` will not be merged. **Open an issue that answers
> those three**, get agreement that the position has changed, and then the code is the
> easy part.

Everything else — a bug, a launcher for a CLI braid has never heard of, an agent adapter,
anything in § 12 you can argue out of it — just go.

## Running it

```bash
git clone https://github.com/stonefeld/braid && cd braid
./test.sh
```

You need what braid needs: **git 2.20, bash 3.2, python3 3.9**. `shellcheck` if you have
it — CI pins 0.11.0, and the local run says so rather than reporting findings you cannot
reproduce.

No agent is launched and no network is used. Workers are simulated by committing in a
worktree; a tracker is simulated by a `gh` on `PATH` that answers from files. Everything
runs against a temporary `HOME` and `XDG_DATA_HOME`, so **an installed braid on your
machine is never touched** — worth knowing before you run it on the laptop that is
halfway through a feature.

To run a working copy without installing it:

```bash
BRAID_HOME=$(pwd) ./bin/braid doctor
```

## Branches

```
feat/<what>      a capability that did not exist
fix/<what>       something that was wrong
docs/<what>      documentation only
chore/<what>     tooling, CI, housekeeping
```

Named after the change, never after a version or a date: a branch called
`feat/v0.2-project-hooks` claims that merging it makes v0.2 exist, and it does not — a
release is a tag somebody cuts. Never a person's name, and never a ticket number alone.

`main` is always releasable. Work happens on a branch and arrives by pull request.

## Commits

**Conventional commits, English, imperative.** `type(scope): what changed`, and the type
is one of `feat` `fix` `docs` `refactor` `test` `chore`.

**The body explains *why*, not what** — the diff already says what. Specifically: what was
wrong before, what it cost, and why this is the fix rather than another one. The best
commits in this repository read like a small incident report, because most of them are:

```
fix: reap lost the landed ref under a launcher that owns the worktree

orca's launcher_forget is `orca worktree rm --force`, which removes the worktree
with git and deregisters it. braid's own `git worktree remove` then failed with
"is not a working tree", died, and never reached the update-ref two statements
below — whose comment describes precisely the harm the die above it was causing.
Every reap under orca lost the only evidence the slice was built.

The landed ref is written first now: it is a cheap idempotent update-ref, the
ancestry check has already proved what it records, and writing it there makes
the rest of reap_one safe to fail anywhere.
```

One change per commit. A fix and the refactor that made it possible are two.

## Pull requests

The title is the commit title. The body says, in this order:

1. **What was wrong**, concretely enough that somebody can reproduce it or recognise it.
2. **What you changed**, and the alternatives you rejected. If you touched a decision in
   `DESIGN.md`, say which and update it in the same pull request — that file is the
   reference the implementation is built against, and when the code and it disagree, one
   of them is a bug.
3. **How you know it works.** Which suite covers it. If nothing does, say why.
4. `Closes #N`, one per line, before any prose. `Closes #1, #2` closes only #1.

**A change in behaviour comes with a test that fails without it.** Not "a test passes" —
a test that *fails on the old code*. Two of the fixes in this repository shipped with
tests that passed against the bug they were supposed to catch, and both were found by
checking rather than by assuming:

```bash
git stash && ./test.sh e2e ; git stash pop     # it should go red
```

Green CI is necessary and not sufficient. It runs on macOS and Linux, because the
invariants differ: macOS is where bash 3.2 is real, Linux is where `/bin/sh` is dash.

## Issues

**A bug** wants: what you ran, what happened, what you expected, and `braid doctor`'s
output. That last one answers half the questions anybody would ask — which engine, from
which release, which agents, which launcher, which branch.

**A feature** wants the problem before the solution. braid has a test it applies to
itself, in `DESIGN.md` § 1: *would this exist if the skills upstream of braid did not?*
If the answer is no, it is glue, and the answer is usually configuration those skills
already read rather than a new layer.

**A field report** — "I ran a real feature and here is what went wrong" — is the most
useful issue there is, and the bar is lower than for a bug report. Symptom, what you
worked around, and where you think it lives. Several of the fixes here came from one.

## The invariants

These are checked mechanically by `test/compat.sh`, and working around the check is not
a fix:

- **bash 3.2.** No `declare -A`, no `mapfile`, no `${var,,}`, no `&>>`.
- **Python 3.9, standard library only.** No `pip`, no third-party imports, anywhere.
- **No new runtime dependencies.** `git`, `bash`, `python3`, an agent CLI. Not `jq`.
- **`install.sh` is POSIX sh**, because `curl | sh` runs under dash on Debian.
- **Progress goes to stderr, and only to a TTY.** These commands are read by an agent as
  often as by a person.
- **English** in code, comments, docs and commits. What language a project *using* braid
  writes its issues in is that project's choice; the keys braid parses are always English.

[`AGENTS.md`](AGENTS.md) has the rest, with the reason under each.

## Releases

`VERSION` is bumped and a `vX.Y.Z` tag is cut on `main`. Installs and `braid upgrade`
resolve to the **latest release tag**, never to `main`, so nothing reaches anybody until
that tag exists. `--ref main` is how you ask for the unreleased tip on purpose.
