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

`~/.config/braid/config` is read as **data**, never executed: `KEY=value`, one per line,
`#` for a comment. A line that is not an assignment is reported rather than run, and only
what a machine may say is applied — a machine fact is how many workers this laptop
survives, which launcher it has, where it keeps worktrees, which agent this person
prefers, and what that person is willing to spend. Everything else in that file is a
decision somebody reviewed, and a file nobody else can see must not overrule one.

Three are refused for a different reason than scope: `BRAID_PROTECTED_BRANCHES`,
`BRAID_PUSH_GUARD` and `BRAID_AGENT_ROLE` decide what a worker may push to, and an
uncommitted file that widens any of them is a hole rather than a preference.

`braid config` and `braid doctor` report every key that file named and braid did not
take, saying which of the three reasons applied.

> [!NOTE]
> There is still **no per-repository, per-person layer**, which is what a coworker running
> a different agent actually needs — a model named in `braid.sh` is a claim about
> everyone, and naming their own means a file global to their machine. Until that layer
> exists, the model and effort values are allowed from the machine file for want of
> anywhere better.

`braid.sh` is read from **the branch you are standing on**, not from the primary
checkout, so a hook a feature adds mid-flight governs that feature's own run.
`braid doctor` prints which file it used.

---

## Agents, models and reasoning effort

### Which agent

| | |
|---|---|
| `BRAID_AGENTS` | which agents this repository supports, best first (`claude codex cursor-agent generic`). A committed decision: `braid init` asks for it when it first writes `braid.sh`, `braid init --agents "codex claude"` restates it, `braid config set BRAID_AGENTS` restates it |
| `BRAID_AGENT` | one machine's or one session's preference |
| `BRAID_AGENT_DESIGN`<br>`BRAID_AGENT_ORCHESTRATE`<br>`BRAID_AGENT_WORK` | pin one seat. In `braid.sh` it is a repository decision — the orchestrator on the agent with hooks, workers on another — and `braid config` offers to write them |
| `BRAID_GENERIC_CMD` | for `BRAID_AGENT=generic`: the command line, with `{worktree}`, `{model}`, `{effort}` and `{prompt}` |

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
they are the largest lever on what a wave costs, so `braid init` puts the resolved table
in front of you on a first run and writes down whatever you change:

```bash
: "${BRAID_MODEL_DESIGN:=sonnet}"      # in braid.sh — committed, for everyone
braid learn --model sonnet             # this session
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

| | Answers | `claude` | `codex` | `cursor-agent` | `generic` |
|---|---|---|---|---|---|
| `BRAID_EFFORT_DESIGN` | how hard the design seat reasons | `high` | `high` | — | — |
| `BRAID_EFFORT_ORCHESTRATE` | how hard the orchestrator reasons | `high` | `high` | — | — |
| `BRAID_EFFORT_LOW` | effort for a `complexity: low` worker | `low` | `low` | — | — |
| `BRAID_EFFORT_STANDARD` | effort for a `complexity: standard` worker | `medium` | `medium` | — | — |
| `BRAID_EFFORT_HIGH` | effort for a `complexity: high` worker | `high` | `high` | — | — |
| `BRAID_EFFORT_WORK` | a worker's effort when no level says | `medium` | `medium` | — | — |

It resolves exactly as a model does: the level's own variable, then whatever the adapter
names, then `BRAID_EFFORT_WORK`, then nothing — and nothing means the CLI keeps whatever
effort the person configured for it. A dash means the adapter names none: Cursor's CLI has
no effort control at all, and `generic` cannot know whether the command line it was handed
takes one.

Unlike the model defaults, these are **not** free. They mirror the model tiers — the two
seats that decide things reason hard because they run briefly and a bad judgement there
costs a whole wave, and the levels vary because varying is what a level is for — and they
raise what a repository spends compared with letting each CLI keep its own default. Change
them where the shape does not fit; `braid doctor` prints the resolved table.

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
`braid config` to opt an existing repository into explicit values without
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
| `BRAID_CODEX_ARGS` | Codex: the flags both halves take (`--sandbox danger-full-access`) |
| `BRAID_CODEX_APPROVAL_POLICY` | Codex: what the interactive half does about approvals (`never`). `codex exec` has nobody to ask and rejects the flag outright |
| `BRAID_CLAUDE_PERMISSION_MODE` | Claude Code: `--permission-mode` (`bypassPermissions`) |
| `BRAID_CURSOR_AGENT_ARGS` | Cursor: the flags both halves take (`--force`) |
| `BRAID_CURSOR_AGENT_HEADLESS_ARGS` | Cursor: flags only its print-mode half takes (`--trust`) |

Every agent is launched with the same access to the machine, and the defaults above are
the spelling each CLI uses for it. That is deliberate: a worker is confined by its
worktree, which git gives it before any sandbox is consulted, and a second confinement on
top of that only makes a slice finishable or not depending on which agent drew it — which
is the one thing an orchestrator judging the branch cannot see. Codex's `workspace-write`
in particular leaves the worktree exactly as it found it and takes away the network, so a
worker under it cannot reach `gh`, a database over TCP, or a dependency that was not
installed before it started. Narrow it per repository if you want that trade:

```bash
braid config set BRAID_CODEX_ARGS "-s workspace-write"
```

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

One helper braid provides for use inside them. `worker_suffix <slug>` gives a short name
no other worker will take, derived from the slice id — so it is the same every time that
worker is re-provisioned, and recomputable in `braid_teardown` once the worktree is gone.

It is one piece, not a solution. braid knows that workers running in parallel must not
collide on a shared name; what your workers share — a port, a schema, a queue, a
container — is this project's business, and `braid_provision` is where you say so.

`braid doctor` says which of these the repository actually defines.

---

## The worker contract

Every worker is told the same four things — never touch the remote, commit everything,
stay inside the slice, write a report — from
[`worker-contract.md`](../worker-contract.md), which ships with the engine. A repository is
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
| `BRAID_STALE_SECONDS` | silence before a worker is called `stale` | `1200` |
| `BRAID_PUSH_GUARD` | install a `pre-push` hook in every worker worktree | `1` |
| `BRAID_LAUNCHER_STRICT` | stop rather than fall through to `detached` when a launcher fails | `0` |
| `BRAID_AGENT_ROLE` | `worker` \| `orchestrator` \| `off` — what the remote guard treats this session as | from the branch |
| `BRAID_HOME` | where the engine lives, for running a working copy without installing it | resolved from the dispatcher |

`BRAID_AGENT_ROLE` decides what the push guard allows, so it is the one row here that
buys you something by being wrong. `off` disables the guard for a session. The default
reads the branch — a worker branch is a worker — and that is almost always right.

## Reading and writing it

`braid config` is the way to change any of this that needs neither an agent nor a text
editor.

```bash
braid config                          every value, resolved, and the layer it came from
braid config get BRAID_MAX_WORKERS
braid config set BRAID_MAX_WORKERS 6  written to braid.sh — committed, for everyone
braid config set BRAID_LAUNCHER tmux --machine
```

`set` writes `braid.sh` unless told otherwise, because that is the layer somebody can
review. It prints the value before and the value after, with the layer the old one came
from — a value you are overwriting in one file while a higher layer still answers for it
is the case that would otherwise look like nothing happened, and it says so.

The table marks every value that came from outside the committed file. That is the same
warning as the one at the top of this document, made answerable for a particular
repository rather than stated in general.

## The three kinds of name

Everything above is configuration: braid reads it, a person may set it, and each one is
in this document. Two other prefixes are not, and setting either is always a mistake.

| | Exported | Set by a person |
|---|---|---|
| `BRAID_*` | some | yes — this document is the whole list |
| `BRAID_RUN_*` | yes | **never.** A fact braid worked out during one command and passed to a child process: which agent resolved, which feature is running, which file a launcher came from |
| `_BRAID_*` | no | **never.** Internal to one file — a sourcing guard, a value one command computed for itself |

`BRAID_RUN_*` is exported because a launcher, a hook or a `braid.sh` runs in another
process and has to see it. It is not configuration: `BRAID_RUN_FEATURE` decides which
slices resolve, and a person who sets it changes that silently. A test holds the three
apart, so a name in the wrong one fails the suite rather than a wave.

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
[`DESIGN.md`](../../DESIGN.md) § 10. When one of these CLIs changes its contract and braid
has not caught up, twenty lines there have you running the same afternoon.
