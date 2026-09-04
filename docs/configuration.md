# Configuration

Everything braid reads, and where each thing belongs. The README covers what most people
set; this is the whole surface.

Four layers, highest priority first:

| | Lives in | Committed | Scope |
|---|---|---|---|
| **One command** | the environment, or a flag | — | this invocation |
| **Machine** | `~/.config/braid/config` | no | this computer, **every** repository |
| **Repository** | `braid.sh` at the root of the repo | yes | this repository, everyone |
| **Defaults** | braid itself | — | — |

`braid.sh` assigns with `: "${VAR:=value}"` and never `VAR=value`, which is what puts it
below the two above it: a repository states what it needs, and a person overrides it
without editing a committed file.

**What belongs where is not a matter of taste.** A repository's settings are decisions a
team made and reviewed — the branch prefix, which agents are supported, what `verify`
runs. A machine's settings are facts about one computer — how many agents it survives,
which agent that person prefers. Conflating them is how one laptop configures a team.

> [!WARNING]
> **The machine layer currently outranks the repository for *every* variable**, including
> the ones that exist precisely so that one laptop cannot configure a team. A
> `BRAID_AGENTS=codex` written once in `~/.config/braid/config` silently un-supports
> Claude in every repository on that machine, and nothing reports it.
>
> That is the behaviour, not the intent, and it is stated here because a reference that
> omits it is worse than none. Narrowing which keys a machine may override — and having
> `braid doctor` name every value that came from outside the committed file — is designed
> and not built. There is also **no per-repository, per-person layer**, which is what a
> coworker running a different agent actually needs.

`braid.sh` is read from **the branch you are standing on**, not from the primary
checkout, so a hook a feature adds mid-flight governs that feature's own run.
`braid doctor` prints which file it used.

---

## Agents and models

### Which agent

| | |
|---|---|
| `BRAID_AGENTS` | which agents this repository supports, best first (`claude codex generic`). A committed decision, narrowed by `braid setup --add-agent` |
| `BRAID_AGENT` | one machine's or one session's preference |
| `BRAID_AGENT_DESIGN`<br>`BRAID_AGENT_ORCHESTRATE`<br>`BRAID_AGENT_WORK` | override one seat |
| `BRAID_AGENT_CMD` | for `BRAID_AGENT=generic`: the command line, with `{model}` and `{prompt}` |

Resolution, highest priority first:

```
1.  braid spawn --agent codex        this once
2.  BRAID_AGENT=codex braid …        this session
3.  ~/.config/braid/config           this machine
4.  BRAID_AGENTS, filtered by PATH   this repository, in order
5.  error
```

A preference outside the repository's list is an error, never a silent fallback.
`braid doctor` prints the whole resolution — supported, installed, preferred, resolved.

### Which model

**Two families, and they answer different questions.** Seats are named by role; a
worker's model comes from the complexity its slice declares.

| | Answers | Default for Claude Code |
|---|---|---|
| `BRAID_MODEL_DESIGN` | which model the design seat runs | `fable` |
| `BRAID_MODEL_ORCHESTRATE` | which model the orchestrator runs | `opus` |
| `BRAID_MODEL_WORK` | a worker's model when nothing else says | `sonnet` |
| `BRAID_MODEL_LOW` | what a `complexity: low` slice means here | `haiku` |
| `BRAID_MODEL_STANDARD` | what a `complexity: standard` slice means | `sonnet` |
| `BRAID_MODEL_HIGH` | what a `complexity: high` slice means | `opus` |

Those defaults come from the agent adapter — `lib/agents/claude.sh` — which is the one
file a vendor's model names are allowed to appear in. They are a guess about somebody
else's budget, and they are the largest lever on what a wave costs, so:

```bash
: "${BRAID_MODEL_DESIGN:=sonnet}"      # in braid.sh — committed, for everyone
braid setup --model sonnet             # this session
braid spawn 04-migration --model opus  # this one slice
```

An adapter that maps nothing — Codex — lets its own CLI choose unless you set these.
`braid doctor` prints the resolved table for every seat and every level.

---

## The project seam — `braid.sh`

All optional, all no-ops by default, because braid has to work in a repository created
twenty minutes ago with no tests, no build and no `.env`.

Four on a worker's lifecycle:

```bash
braid_provision <worktree> <slug> <base> <needs-setup>
    # everything a worker needs before its first turn: .env, a database, an install.
    # non-zero aborts the spawn and the half-made worktree is removed.

braid_verify <worktree>
    # the mechanical gate. non-zero means the branch does not integrate.
    # a green result is not permission to integrate; a red one is a refusal.

braid_teardown <worktree> <slug>
    # undo what provision made outside the worktree, for one worker. never fails a reap.

braid_teardown_feature <feature-worktree> <feature-slug> <trunk>
    # undo what is shared by every worker of a feature and outlives all of them —
    # a database seeded once, a container. `braid reap --feature` runs it, after the
    # feature has landed in the trunk.
```

Two on where slices come from:

```bash
braid_fetch_slice <id>        # given an id, print the slice's markdown
braid_slice_launchable <id>   # is this open issue work a worker could start?
                              # non-zero withdraws it. github mode only.
```

Two helpers braid provides for use inside them: `provision_env <worktree> <slug>` copies
the primary checkout's `.env` and gives the worker its own `BRAID_PORT`, and
`worker_suffix <slug>` gives a short unique string for naming anything else.

`braid doctor` says which of these the repository actually defines.

---

## The worker contract

Every worker is told the same four things — never touch the remote, commit everything,
stay inside the slice, write a report — from
[`worker-contract.md`](worker-contract.md), which ships with the engine. A repository is
in exactly one of three states:

| State | The repository has | Upgrades |
|---|---|---|
| **bundled** | nothing | reach it |
| **bundled + rules** | `docs/worker-rules.md`, appended under a `## House rules` heading braid supplies | reach the part braid owns. **Start here** |
| **replaced** | `docs/worker-contract.md`, replacing it whole | never reach it |

If both exist the replacement wins and `braid doctor` says the rules file is being
ignored. The composed text is written once, at spawn, to the worktree's
`.braid/contract.md`, and every delivery path reads that file.

---

## Everything else

| | | Default |
|---|---|---|
| `BRAID_MAX_WORKERS` | how many run at once — a fact about your machine | `4` |
| `BRAID_LAUNCHER` | pin one: `orca` \| `herdr` \| `tmux` \| `detached` | auto |
| `BRAID_BRANCH_PREFIX` | worker branches | `agent` |
| `BRAID_PROTECTED_BRANCHES` | never pushed, never a worker's base | `main master` |
| `BRAID_WORKTREE_ROOT` | where worker worktrees are made | `~/.braid/worktrees/<repo>` |
| `BRAID_SLICE_SOURCE` | `files` \| `github` | `files` |
| `BRAID_FEATURES_DIR` | where slices live in files mode | `braid/features` |
| `BRAID_WORKER_IGNORE` | what a worker's own build output leaves behind, ignored per worktree | empty |
| `BRAID_DESIGN_STEPS` | what this house runs before there are slices — printed, never run | empty |
| `BRAID_PORT_BASE` | first port handed to a worker | `8100` |
| `BRAID_PORT_RANGE` | how many ports it may use | `400` |
| `BRAID_STALE_SECONDS` | silence before a worker is called `stale` | `1200` |
| `BRAID_PUSH_GUARD` | install a `pre-push` hook in every worker worktree | `1` |
| `BRAID_NAME` | this repository's name, for anything that displays one | the directory |

### `BRAID_WORKER_IGNORE`

A worker's worktree is a fresh checkout where a full install and a full test run happen,
and the contract tells every worker to **commit everything**. Between those two facts,
whatever the run leaves lying about is one `git add -A` from the feature branch — and it
may be something this repository genuinely does not ignore, because in your checkout it
never appears.

```bash
: "${BRAID_WORKER_IGNORE:=.pytest_cache/
.ruff_cache/
coverage.xml}"
```

Applied per worktree through `core.excludesFile`, so neither the repository's
`.gitignore` nor your own checkout is touched, and your global ignores are kept.

### `BRAID_DESIGN_STEPS`

braid owns nothing upstream of "these slices are launchable" — grilling, writing a spec,
cutting it into tickets are somebody else's skills and braid never runs them. It will
name them, so that `braid design` opens onto something rather than a blank session:

```bash
: "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"
```

`braid next` and `braid design` print it, to you and never into the agent's prompt.
Leave it empty if there is no named process; an invented one is worse than none.

---

## Replacing what braid ships

Two things resolve through your own config directory before braid's own, and
`braid upgrade` never touches them:

```
~/.config/braid/launchers/<name>.sh    shadows a built-in launcher
~/.config/braid/config                 this machine's settings
```

A launcher is four functions, only one of them required — see
[`DESIGN.md`](../DESIGN.md) § 10. When one of these CLIs changes its contract and braid
has not caught up, twenty lines there have you running the same afternoon.
