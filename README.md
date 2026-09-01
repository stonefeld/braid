<div align="center">

# braid

**Parallel agents, one clean history.**

Run several coding agents at once, each in its own git worktree, then weave their
branches back into one feature branch that reads as though it had all been written
there in order.

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
```

Then, from inside a repository you want to use it in:

```bash
braid setup
```

Works with any agent CLI — Claude Code, Codex, or anything you can put on a command line
— and in any terminal setup, from a full agent development environment down to plain
tmux. It needs `git`, `bash`, `python3` and an agent. Nothing else: no database, no
docker, no task tracker, no packages.

> [!WARNING]
> **braid is a work in progress. Expect it to break.**
>
> It grew inside a Claude Code setup, and that shows in the mechanism rather than in
> whether it works. A worker there gets its contract from a `SessionStart` hook, its
> status from a `Stop` hook, and a `PreToolUse` guard that denies the remote *before* the
> permission system runs — which is what makes it safe to launch workers with approvals
> off.
>
> Every other agent gets the same guarantees by blunter means: the contract at the top of
> the prompt, the status written by `.braid/finish.sh` when the process exits, the remote
> refused by a per-worktree `pre-push` hook. Claude Code and Codex have each built a
> feature here end to end. The rest is reasoned from the same three mechanisms and has not
> been run by anyone.
>
> Each will get a proper integration as the agents grow the hooks to support one.

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

The first two are one sitting: you decide what to build, write the slices, and the same
session runs `braid plan` to schedule them. The orchestrator is deliberately a **new**
session — its job is judging other agents' work against their diffs, and a session that
just spent an hour designing the feature is the worst possible reader of it. It knows
what the code was meant to be, which is the thing it is supposed to be checking.

**braid has no opinion about how you decide what to build.** Grilling a design, writing a
PRD, cutting it into slices — those are house decisions and it ships none of them. What it
owns starts at *"these slices are launchable"* and ends at *"the feature branch is green"*.

It will still open the seat for you — `braid design` starts your agent on the tier this
repository calls `design`, in the worktree you are standing in, and gets out of the way.
It carries no workflow; what it saves is choosing a model by hand at the moment you least
want to think about one. When the slices exist, `/braid-plan` in that same session
annotates them and schedules them.

If you are ever unsure where you are:

```bash
$ braid next
feat/oauth-flow

  wave 1   3 done
  wave 2   1 todo
         1 slices not started.

next → braid wave 2
```

That is derived from git and the worktrees every time it is asked, never from a file
braid wrote down about where you were. In this workflow people create issues in a
browser, edit plans and kill workers by hand; a remembered phase is wrong the first time
they do.

### 1. Slices

A slice is one worker's work: one session, one branch, one worktree. It carries a
**braid block**, which is *configuration of the slice* rather than description of it:

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
agent adapter decides which model that means locally, so a slice never names one and works
unchanged in a repository whose workers run something else. `setup: yes` takes the
expensive provisioning path and serialises: two of them never share a wave.

They live in a tracker, or as files. With files, the folder is the parent and the files
in it are its slices, which is the parent/sub-issue relation without needing a tracker to
have the primitive:

```
braid/features/oauth-flow/
  prd.md  01-schema.md  02-endpoint.md  plan.md
```

### 2. The schedule

```bash
braid plan
```

You do not write waves by hand. braid derives them from the blockers, then applies two
constraints the dependency graph does not model — `setup: yes` slices serialise, and the
machine has a capacity — so a wave is a **schedule**, not a level of the graph. You argue
with the result rather than computing it.

Only the fence is rewritten on a re-run. `## Contracts` and `## Traps` are yours, and hold
the one thing nothing else can: what spans slices.

### 3. The wave

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

The overlap is computed from the workers' real diffs, during the wave — hours before the
same collision would surface as a rebase conflict. Nobody declares anything.

Each worker gets its own worktree, branch, port and environment, and a contract it cannot
miss: never touch the remote, commit everything, stay inside the slice, write a report.

### 4. Integration

```bash
braid integrate 01-schema      # rebase, fast-forward, run the gate
braid reap --merged
```

Rebase then `merge --ff-only`, so the finished branch has no merge commits and reads as
one line of work. On a conflict it **stops in place** — the rebase left in the worker's
worktree, where its context is, with the files named — and `braid integrate --continue`
picks it up. That is the orchestrator's to resolve; it is why that seat runs on a capable
model.

The gate runs after every fast-forward rather than once at the end, because two changes
that each pass alone can fail together, and one run at the end tells you something broke
without telling you which merge did it.

---

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
braid doctor               check this machine can run a wave
braid upgrade              update the engine, keeping what you changed
```

## braid.sh — the only file you write

Four functions, all optional, all no-ops by default. braid has to work in a repository
created twenty minutes ago that has no tests, no build and no `.env`, and this file is
where that stops being true.

```bash
braid_provision() {                  # $1 worktree  $2 slug  $3 base  $4 needs-setup
    provision_env "$1" "$2"          # .env copied, with this worker's own BRAID_PORT
    (cd "$1" && npm ci) >"$1/.braid/install.log" 2>&1
}

braid_verify()   { (cd "$1" && npm run typecheck && npm test); }
braid_teardown() { docker rm -f "app-$2"; }
```

`braid setup` writes it from a preset and then opens a short agent session to fill it in —
the right answer to "what is your verify command" comes from reading your Makefile and
your CI, and you have to be able to say *"not that one, it takes forty minutes"*.

If a project cannot be expressed in those four functions, the seam is in the wrong place.

## Any agent

```bash
: "${BRAID_AGENTS:=claude codex}"    # in braid.sh — supported here, best first
BRAID_AGENT_ORCHESTRATE=claude       # the seat that can push and open PRs
BRAID_AGENT_WORK=codex               # the workers
```

**Which agents are installed is a fact about a machine; which agents a repository supports
is a decision somebody made and committed.** braid reports the first and obeys the second,
and a preference outside the repository's list is an error rather than a silent fallback —
adding an agent costs something real, and somebody has to say it works here.

The assumption braid makes of an agent is only that it starts, works in the directory it
was started in, and exits. That is why each adapter is thirty lines and why `generic` — a
command-line template — is a first-class option rather than a fallback:

```bash
BRAID_AGENT=generic
BRAID_AGENT_CMD='my-agent run --model {model} --prompt {prompt}'
```

What a worker needs is delivered either way:

| | Claude Code | everything else |
|---|---|---|
| the contract | injected at `SessionStart` | at the top of the prompt, and on disk |
| status | the `Stop` hook, which can push back on a dirty tree | `.braid/finish.sh` on exit |
| the remote | `PreToolUse` denies `gh` and `git push` | a per-worktree `pre-push` hook |

Status is written *for* the agent, not by it, so it happens whether the agent cooperated,
crashed, or was never installed.

## Where workers run

A worker lives somewhere you can look at it. braid uses the environment you spawned it
from — orca and herdr both mark their own terminals, so this is settled by the environment
rather than guessed — then tmux, then a detached process with a log.

Launchers are replaceable: a file in `~/.config/braid/launchers/` shadows the built-in. So
when one of these CLIs changes its contract and braid has not caught up, twenty lines
there have you running the same afternoon, in a file `braid upgrade` will not touch.

**None of it is load-bearing.** `braid status` reads the filesystem, so the same wave runs
identically in all four and status works over ssh from a phone. The agent development
environment is the view; the filesystem is the control plane.

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
| `BRAID_FEATURES_DIR` | where slices live in files mode (`braid/features`) |
| `BRAID_WORKTREE_ROOT` | `~/.braid/worktrees/<repo>` |
| `BRAID_PORT_BASE` | first port handed to a worker (`8100`) |

## How it is built

The engine installs to `~/.local/share/braid` and is **not** vendored into your
repository. Your repository carries only what a team argued about: `braid.sh`, and three
hooks registered by name rather than by path. `braid upgrade` compares what is on disk,
what braid shipped, and what is new — so a fix you wrote while something was broken
survives an upgrade, and a conflict is reported rather than resolved behind your back.

It stays shell rather than a compiled binary, and that is a choice about trust: for
something distributed by `curl | sh`, **what you run is what you read**. It targets bash
3.2 because macOS still ships it, and Python's standard library only — no `pip`, ever.
CI checks all of that on macOS and Linux, alongside 88 assertions including a whole
feature run end to end.

macOS, Linux and WSL2. `doctor` refuses Git Bash rather than half-working there.

## More

- [`DESIGN.md`](DESIGN.md) — every decision behind this, and why
- [`AGENTS.md`](AGENTS.md) — house rules for working on braid itself
- [`docs/worker-contract.md`](docs/worker-contract.md) — what every worker is told

## License

MIT
