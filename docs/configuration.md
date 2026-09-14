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

## Agents, models and reasoning effort

### Which agent

| | |
|---|---|
| `BRAID_AGENTS` | which agents this repository supports, best first (`claude codex cursor-agent generic`). A committed decision: `braid setup` asks for it when it first writes `braid.sh`, `braid setup --agents "codex claude"` restates it, `braid setup --add-agent NAME` appends to it |
| `BRAID_AGENT` | one machine's or one session's preference |
| `BRAID_AGENT_DESIGN`<br>`BRAID_AGENT_ORCHESTRATE`<br>`BRAID_AGENT_WORK` | pin one seat. In `braid.sh` it is a repository decision — the orchestrator on the agent with hooks, workers on another — and `braid setup` offers to write them |
| `BRAID_AGENT_CMD` | for `BRAID_AGENT=generic`: the command line, with `{worktree}`, `{model}`, `{effort}` and `{prompt}` |

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

| | Answers | `claude` | `codex` | `cursor-agent` | `generic` |
|---|---|---|---|---|---|
| `BRAID_MODEL_DESIGN` | which model the design seat runs | `fable` | — | — | — |
| `BRAID_MODEL_ORCHESTRATE` | which model the orchestrator runs | `opus` | — | — | — |
| `BRAID_MODEL_WORK` | a worker's model when nothing else says | `sonnet` | — | — | — |
| `BRAID_MODEL_LOW` | what a `complexity: low` slice means here | `haiku` | — | — | — |
| `BRAID_MODEL_STANDARD` | what a `complexity: standard` slice means | `sonnet` | — | — | — |
| `BRAID_MODEL_HIGH` | what a `complexity: high` slice means | `opus` | — | — | — |

A dash means the adapter names nothing and the CLI's own default runs until this
repository says otherwise. Only Claude Code has model names that are aliases rather than
versions — `opus` stays `opus` while what runs under it changes — and an adapter may only
name one of those. Everywhere else a name written into braid would be a snapshot that goes
stale, and a stale name does not degrade: the CLI refuses it.

Those defaults come from the agent adapters, which are the one place a vendor's model
names are allowed to appear in code. They are a guess about somebody else's budget, and
they are the largest lever on what a wave costs, so `braid setup` puts the resolved table
in front of you on a first run and writes down whatever you change:

```bash
: "${BRAID_MODEL_DESIGN:=sonnet}"      # in braid.sh — committed, for everyone
braid setup --model sonnet             # this session
braid spawn 04-migration --model opus  # this one slice
```

An adapter that maps nothing lets its own CLI choose unless you set these, so every seat
and every complexity level runs whatever that CLI is configured for — `~/.codex/config.toml`
for Codex, Cursor's own default. That is a real answer, not a gap: it follows you when you
change it there. It does mean a `complexity:` level buys nothing until you say what it
means here — and `BRAID_MODEL_WORK` is the shortest way to say it, because a level that
maps nothing falls through to it, so one name covers all three until the levels are worth
separating.

Take those names from the CLI's own picker rather than from memory. Neither of those two
has a tier alias to lean on, which is the whole reason braid does not write their names
down for you: every name they offer carries its version, and a version is what moves.

`braid doctor` prints the resolved table for every seat and every level.

### Which reasoning effort

Effort is separate from model selection. The portable values are `low`, `medium`, `high`
and `xhigh`: the intersection supported by the bundled Codex and Claude Code adapters.
Braid translates them at launch (`model_reasoning_effort` for Codex, `--effort` for
Claude Code).

Adapters opt into effort explicitly. If the resolved adapter has no independent effort
control, a configured value is an error rather than a promise braid cannot keep. A
project `braid_agent_command` may still implement the fourth argument itself.

| | Answers |
|---|---|
| `BRAID_EFFORT_DESIGN` | how hard the design seat reasons |
| `BRAID_EFFORT_ORCHESTRATE` | how hard the orchestrator reasons |
| `BRAID_EFFORT_LOW` | effort for a `complexity: low` worker |
| `BRAID_EFFORT_STANDARD` | effort for a `complexity: standard` worker |
| `BRAID_EFFORT_HIGH` | effort for a `complexity: high` worker |

```bash
: "${BRAID_EFFORT_DESIGN:=high}"       # in braid.sh — committed, for everyone
: "${BRAID_EFFORT_STANDARD:=medium}"   # the normal worker tier
braid design --effort xhigh             # this session
braid spawn 04-migration --effort high  # this one slice
```

There is deliberately no effort field in a slice. Its `complexity` selects the model
and effort together, while the repository decides what that tier costs. An unset effort
is also deliberate: braid passes no effort flag and the agent CLI keeps its configured
default. That makes every existing `braid.sh` backwards compatible. Run
`braid setup --costs` to opt an existing repository into explicit values without
scaffolding again or opening a setup session.

Provider-only levels remain provider configuration, not portable braid values. For
example, Codex's `minimal` and Claude Code's `max` are available when the CLI chooses its
own default or through a custom launch command; committing either as a braid effort
would make the same repository mean different things when a seat changes agents.

### How the agent is launched

Every agent CLI has at least two of them: the one a person sits in front of, and the one
that runs with nobody watching. braid uses both — the first for `setup`, `design`,
`orchestrate` and a worker in a visible pane, the second for a detached worker — and they
do not take the same flags.

| | |
|---|---|
| `BRAID_AGENT_ARGS` | Codex: the flags both halves take (`--sandbox workspace-write`) |
| `BRAID_APPROVAL_POLICY` | Codex: what the interactive half does about approvals (`never`). `codex exec` has nobody to ask and rejects the flag outright |
| `BRAID_PERMISSION_MODE` | Claude Code: `--permission-mode` (`bypassPermissions`) |
| `BRAID_CURSOR_AGENT_ARGS` | Cursor: the flags both halves take (`--force`) |
| `BRAID_CURSOR_AGENT_HEADLESS_ARGS` | Cursor: flags only its print-mode half takes (`--trust`) |

`braid doctor` probes these against the installed CLI's own `--help` and says so when a
flag has been renamed — before a wave, rather than as eight workers that died at launch.

If your CLI has moved further than a flag, replace the launch command outright from
`braid.sh` rather than editing an adapter that `braid upgrade` will overwrite:

```bash
braid_agent_command() {           # $1 worktree  $2 model  $3 prompt  $4 effort
    local effort=""
    [[ -z "${4:-}" ]] || effort="--effort $(printf '%q' "$4")"
    printf 'my-agent %s --prompt %q' "$effort" "$3"
}
```

The first three arguments are unchanged. Existing overrides keep working; `$4` is empty
when no effort is configured.

It replaces **both** launches: the seat you open in a terminal and the detached worker,
which is the path most launches take. braid cannot tell one command line from another, so
if your replacement opens a TUI it will hang a worker started without a tty — give it a
headless form, which wins wherever it is defined:

```bash
braid_agent_command_headless() { # same four arguments
    printf 'my-agent --print %q' "$3"
}
```

`braid doctor` says which of the two forms it found.

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
