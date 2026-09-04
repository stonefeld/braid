<div align="center">

# braid

**Parallel agents, one clean history.**

Run several coding agents at once, each in its own git worktree, then weave their
branches back into one feature branch that reads as though it had all been written
there in order.

</div>

> [!WARNING]
> **braid is a work in progress. Expect it to break.** [Support](#support) says what has
> been run for real and what has only been reasoned about.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
```

That installs **the latest release**. To pin a version, name it — the URL you fetch the
script from never decides which engine you get:

```bash
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh -s -- --ref v0.1.0
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh -s -- --ref main
```

The installer is mechanical — it detects the platform, copies the engine to
`~/.local/share/braid`, and symlinks `braid` onto your `PATH`. It calls no model and
needs no agent installed. Piped from curl it first resolves the version, downloads it,
and hands over to the installer inside that tarball, so the installer that runs is always
the one that shipped with the engine it installs. `braid doctor` says which release you
are on, or warns when you are not on one. Then, once per repository:

```bash
braid setup      # scaffolds braid.sh and the hooks, then opens a session to fill them in
braid doctor     # confirms this machine can run a wave
```

`braid setup` is re-runnable: run it again when the test suite changes or a coworker
arrives with a different agent.

## Requirements

| | Minimum | Why |
|---|---|---|
| `git` | 2.20 | worktrees, and `git config --worktree` for the per-worker push guard |
| `bash` | 3.2 | macOS still ships 3.2 as `/bin/bash` |
| `python3` | 3.9 | JSON parsing and the hooks. **Standard library only — no `pip`, ever** |
| an agent CLI | — | see below |

Nothing else: no database, no docker, no task tracker, no packages. `braid doctor` reports
each of these and fails on the ones that would stop a spawn. Two are optional, and only
for what depends on them: `tmux` for the tmux launcher, and `gh` for
`BRAID_SLICE_SOURCE=github`.

## Support

### Operating systems

| | |
|---|---|
| **macOS**, **Linux** | supported. Every test runs on both in CI |
| **WSL2** | supported, not in CI |
| Windows, natively | **no.** `doctor` refuses MSYS/Cygwin/Git Bash rather than half-working there |

### Agents

braid assumes only that an agent starts, works in the directory it was started in, and
exits — which is why each adapter is about thirty lines, and why `generic`, a
command-line template, is a first-class option rather than a fallback.

| | Contract arrives | Status written by | Remote blocked by | Run for real |
|---|---|---|---|---|
| **Claude Code** | `SessionStart` hook | `Stop` hook, which can push back on a dirty tree | `PreToolUse` guard **and** `pre-push` | a whole feature |
| **Codex** | top of the prompt, and on disk | `.braid/finish.sh` at exit | `pre-push` | a whole feature |
| **`generic`** | top of the prompt, and on disk | `.braid/finish.sh` at exit | `pre-push` | the test suite, every CI run. No real agent |

Status is written **for** the agent, never by it, so it happens whether the agent
cooperated, crashed, or was never installed.

```bash
: "${BRAID_AGENTS:=claude codex}"    # in braid.sh — supported here, best first
BRAID_AGENT_ORCHESTRATE=claude       # the seat that can push and open PRs
BRAID_AGENT_WORK=codex               # the workers

BRAID_AGENT=generic                  # anything else
BRAID_AGENT_CMD='my-agent run --model {model} --prompt {prompt}'
```

### Which model runs what

Seats and slices are named by **tier**, never by a vendor's model name — a slice says how
much judgement its work needs, and the adapter says what that means here. The defaults
for Claude Code:

| | | |
|---|---|---|
| `design` | `fable` | grilling, PRDs, cutting slices |
| `orchestrate` | `opus` | judging other agents' work against their diffs, and resolving conflicts |
| a `low` slice | `haiku` | mechanical and fully specified |
| a `standard` slice | `sonnet` | the default — an ordinary vertical slice |
| a `high` slice | `opus` | cross-module, ambiguous, a migration over real rows |

**These are the adapter's defaults, not a decision anybody made about your repository.**
They are the largest lever on what a wave costs, so override whatever does not fit:

```bash
: "${BRAID_MODEL_DESIGN:=sonnet}"     # in braid.sh — committed, for everyone
: "${BRAID_MODEL_HIGH:=sonnet}"
braid setup --model sonnet            # or just this session
braid spawn 04-migration --model opus # or just this slice
```

`braid doctor` prints the whole resolved table — every seat, its model, and where that
came from — and `braid setup` asks you to confirm it rather than assuming you agree.

### The repository decides which agents

Which agents are installed is a fact about a machine; which agents a repository supports
is a committed decision. A preference outside the repository's list is an error rather
than a silent fallback — adding one means confirming the table above holds *here*, so it
goes through `braid setup --add-agent <name>`.

### Where workers run

| | Used when | |
|---|---|---|
| **orca** | `ORCA_TERMINAL_HANDLE` is set | declared by the environment, not guessed |
| **herdr** | `HERDR_ENV=1` | same |
| **tmux** | `tmux` is on `PATH` | one session per worker, named after its branch |
| **detached** | always | a background process and `.braid/session.log`. What CI runs |

**None of it is load-bearing.** `braid status` reads the filesystem, so the same wave runs
identically in all four and status works over ssh from a phone. A file in
`~/.config/braid/launchers/<name>.sh` shadows any built-in and survives `braid upgrade`,
so a CLI that changes its contract costs you twenty lines, not a release.

### Where slices come from

| | | Needs |
|---|---|---|
| **files** *(default)* | markdown under `braid/features/<feature>/` — the folder is the parent, the files are its slices | nothing |
| **github** | slices are issues, a feature's PRD is their parent issue | `gh`, authenticated |

The braid block is parsed identically from either, which is what lets a slice move
between them unrewritten. **The plan follows the slices**: a `plan.md` beside them in
files mode, the PRD issue's own body with a tracker — so a repository whose work lives in
issues does not accumulate one dead plan file per shipped feature. Say
`braid plan --prd <n>` once; braid keeps the pointer.

---

## The flow

```
braid design  →  braid plan  →  braid orchestrate  →  a linear branch
   one seat, one session         a fresh one, running the waves

                                   braid wave      launch, capped
                                   braid wait      settle
                                   braid integrate rebase, ff-only
                                   braid reap
```

The first two are one sitting. The orchestrator is deliberately a **new** session: its
job is judging other agents' work against their diffs, and a session that just spent an
hour designing the feature is the worst possible reader of it.

braid has no opinion about how you decide what to build. What it owns starts at *"these
slices are launchable"* and ends at *"the feature branch is green"*. `braid next` derives
where you are from git and the worktrees every time it is asked — never from a file braid
wrote down — and says what to run.

**A slice** is one worker's work: one session, one branch, one worktree. It carries a
**braid block**, which is configuration of the slice rather than description of it:

````markdown
# Add the OAuth callback endpoint

```braid
complexity: standard
setup: no
blocked-by: 01-schema
```

## What to build
## Acceptance
## Out of scope
````

`complexity` is how much judgement the work needs — `low`, `standard`, `high` — and the
adapter decides which model that means locally, so a slice never names one. `setup: yes`
takes the expensive provisioning path and serialises: two of them never share a wave.

**A wave is a schedule, not a level of the dependency graph.** `braid plan` derives it
from the blockers, then applies the two constraints the graph does not model —
`setup: yes` serialises, and the machine has a capacity. You argue with the result rather
than computing it. Re-running rewrites only the fence; `## Contracts` and `## Traps` are
yours, and hold the one thing nothing else can: what spans slices.

```bash
braid wave 1     # launches up to the machine's capacity, queues the rest
braid wait       # settles, or exits 3 meaning call it again
braid status
```

```
done            agent/01-schema      3 commits
working         agent/02-endpoint    1 commits, quiet 40s
done-no-report  agent/03-audit       0 commits
  no commits — it probably died at launch

overlap — these workers have touched the same file:
  src/router.ts       01-schema, 02-endpoint
  integrate them in one order and expect the second to conflict.
```

That overlap is computed from the workers' real diffs, during the wave — hours before the
same collision would surface as a rebase conflict. Nobody declares anything.

**Integration** is `braid integrate <slug>`: rebase, `merge --ff-only`, then the gate. No
merge commits, so the branch reads as one line of work. On a conflict it stops in place —
the rebase left in the worker's worktree, where its context is, with the files named —
and `braid integrate --continue` picks it up. The gate runs after every fast-forward
rather than once at the end, because two changes that each pass alone can fail together.

**After the PR merges**, `braid reap --feature` runs the repository's
`braid_teardown_feature`: the shared database, container or fixture store that every
`setup: yes` worker of this feature used, and which no single worker's reap may drop. It
refuses until the feature branch is contained in a protected branch, checked against your
**local** trunk — `git fetch` is yours, and braid never goes to the network to decide
whether it may delete something.

## Commands

```
braid next                 what to run now, and why
braid setup                teach braid about this repository
braid design               open the design seat, at the right tier
braid orchestrate          open the orchestrator seat on this feature
braid plan [feature]       derive the wave schedule from the slices
braid wave <n|slices…>     launch a wave, at most BRAID_MAX_WORKERS at a time
braid spawn <slice>        launch one worker
braid status               what every worker is doing   (--reports, --all)
braid wait                 block until the wave settles (exit 3 = call again)
braid verify [slug]        run the project's mechanical gate
braid integrate <slug>     rebase, fast-forward, gate    (--continue, --abort)
braid reap <slug>          tear a worker down            (--merged, --force)
braid reap --feature       tear down what the whole feature provisioned, once it lands
braid doctor               check this machine can run a wave
braid upgrade              update the engine, keeping what you changed
```

## What you write

**`braid.sh`** — four functions, all optional, all no-ops by default. braid has to work in
a repository created twenty minutes ago that has no tests, no build and no `.env`, and
this file is where that stops being true. If a project cannot be expressed in these four,
the seam is in the wrong place.

```bash
braid_provision() {                  # $1 worktree  $2 slug  $3 base  $4 needs-setup
    provision_env "$1" "$2"          # .env copied, with this worker's own BRAID_PORT
    (cd "$1" && npm ci) >"$1/.braid/install.log" 2>&1
}

braid_verify()           { (cd "$1" && npm run typecheck && npm test); }
braid_teardown()         { docker rm -f "app-$2"; }   # one worker, at reap
braid_teardown_feature() { dropdb "app_$2"; }         # the feature, at reap --feature
```

**`docs/worker-rules.md`**, optionally. Every worker is told the same four things — never
touch the remote, commit everything, stay inside the slice, write a report — from
[`docs/worker-contract.md`](docs/worker-contract.md), which ships with the engine. A
repository is in one of three states:

| | | |
|---|---|---|
| **bundled** | nothing in the repository | upgrades reach it |
| **bundled + rules** | `docs/worker-rules.md`, appended under a `## House rules` heading braid supplies | upgrades still reach the part braid owns. **Start here** |
| **replaced** | your own `docs/worker-contract.md`, whole | nothing braid ships afterwards ever reaches these workers. `doctor` says so on every run |

Composed once, at spawn, into `.braid/contract.md` — so the prompt an agent without hooks
reads and the text a session hook injects are the same bytes, not two lookups that drift.

## Configuration

The environment wins over `braid.sh`, which wins over the defaults.

| | |
|---|---|
| `BRAID_AGENTS` | supported here, best first (`claude codex generic`) |
| `BRAID_AGENT_<SEAT>` | override for one seat: `DESIGN`, `ORCHESTRATE`, `WORK` |
| `BRAID_MODEL_<LEVEL>` | what `low`, `standard`, `high` mean for this agent |
| `BRAID_MAX_WORKERS` | how many run at once — a fact about your machine (`4`) |
| `BRAID_LAUNCHER` | `orca` \| `herdr` \| `tmux` \| `detached`; pins one |
| `BRAID_BRANCH_PREFIX` | worker branches (`agent`) |
| `BRAID_PROTECTED_BRANCHES` | never pushed, never a worker's base (`main master`) |
| `BRAID_WORKER_IGNORE` | what a worker's own build output leaves behind, ignored per worktree |
| `BRAID_SLICE_SOURCE` | `files` \| `github` |
| `BRAID_FEATURES_DIR` | where slices live in files mode (`braid/features`) |
| `BRAID_WORKTREE_ROOT` | `~/.braid/worktrees/<repo>` |
| `BRAID_PORT_BASE` | first port handed to a worker (`8100`) |

## Skills

Two, installed into the shared `~/.agents/skills/` and linked from `~/.claude/skills` and
`~/.codex/skills`. They are markdown, so an agent that loads skills gets the name and one
that does not gets the text.

| | |
|---|---|
| `/braid-plan` | make a set of slices launchable, and derive the schedule |
| `/braid-orchestrate` | run the waves, gate the work, integrate it |

## More

- [`DESIGN.md`](DESIGN.md) — every decision behind this, and why
- [`AGENTS.md`](AGENTS.md) — house rules for working on braid itself
- [`docs/worker-contract.md`](docs/worker-contract.md) — what every worker is told

MIT.
