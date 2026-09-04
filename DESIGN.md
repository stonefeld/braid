# Design

Every decision behind braid, and the reason under it. This is the reference the
implementation is built against; when the code and this file disagree, one of them is
a bug.

---

## 1. What braid is

braid runs several coding agents in parallel, each isolated in its own git worktree,
and integrates their branches into one linear feature branch.

The name is the mechanism: parallel strands woven into one rope. `rebase` onto the
feature branch, then `merge --ff-only`, in an order that matters — so the finished
branch reads as though every commit had been written on it directly, in sequence.

**It is a tool with an opt-in method layer, not a method.** braid has no opinion about
how you arrive at a design. It recommends a workflow at setup time and works fine
without it.

### The glue test

braid sits downstream of skills it does not own (grilling, PRDs, issue writing). The
temptation is to keep adding layers that reshape their output. Every candidate
addition gets one question:

> **Would this exist if those skills did not?**
> If no, it is glue. Drop it, or push it into configuration those skills already read.

Applied: the wave plan passes (no issue tracker models scheduling). Cross-slice
contracts pass (an invariant shared by four slices has no home in a per-slice issue).
A restatement of the PRD's "why" and scope fails — that is glue, and it is what makes
a handoff document feel like a layer instead of a decision.

---

## 2. The four seats

| Seat | Who | Runs |
|---|---|---|
| **Human** | you | `braid setup`, `braid doctor`, `braid upgrade`, `braid next` |
| **Design** | agent, top tier | grilling → PRD → slices → `braid plan` |
| **Orchestrator** | agent, mid tier | `braid wave`, `status`, `wait`, `verify`, `integrate`, `reap` |
| **Worker** | agent, low tier | **nothing** |

The design seat and the orchestrator share the feature worktree, one after the other.
Workers get their own.

**A worker never invokes braid.** It starts, works in the directory it was started in,
and exits. That is the whole assumption braid makes about an agent, and it is why
adapters are thirty lines and why an agent released next year works unchanged.

### Model tiers

Tiers are named by seat, not by brand. The mapping lives in the agent adapter, so a
vendor's model names appear in exactly one file.

```bash
BRAID_MODEL_DESIGN=fable        # the grilling seat
BRAID_MODEL_ORCHESTRATE=opus    # judgement about other agents' work
```

The work seat is not one model. A worker's model comes from **the complexity its slice
declares**, mapped by the adapter — see §6.

---

## 3. Installation

### The split

The single most important structural decision. Three kinds of artifact, three homes:

| | What | Where | Updated by |
|---|---|---|---|
| **Engine** | `lib/`, adapters, hooks, skills, docs | `~/.local/share/braid`, dispatcher on `PATH` | `braid upgrade` |
| **Repo config** | `braid.sh`, `docs/agents/`, `docs/worker-rules.md`, supported agents, pinned version | committed, small | a pull request |
| **Wiring** | `.claude/settings.json`, `AGENTS.md` | committed, tiny, path-free | `braid setup` |

The engine is **not vendored into the user's repository**. Vendoring puts thousands of
lines of tool into someone else's git history, gives five repositories five different
versions with no way to tell which is which, and makes every upgrade a large diff in a
project that did not change.

Wiring commands carry no paths — `braid hook session-start`, not
`$CLAUDE_PROJECT_DIR/.harness/hooks/worker_session.py` — which is what allows the
engine to live outside the repository at all.

**What this costs, stated plainly:** exact historical reproducibility. Checking out an
old commit no longer gives you the engine that ran that feature. Mitigated by pinning
the version in repo config and recording the resolved version in `.braid/` at spawn
time, but not eliminated.

### The two halves of setup

```bash
curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
```

The URL is the raw file on GitHub rather than a vanity domain: what you are about to
pipe into a shell is exactly what you can read in the repository, and it needs no
infrastructure to exist. If a short domain is ever added it must **not** be `braid.sh` —
that is the name of the file every project using braid writes, and "edit braid.sh"
beside "curl braid.sh" is an ambiguity in every sentence of the documentation.

**Half one — mechanical, deterministic, no LLM.** Detect the platform and the agents on
`PATH`, install the engine, symlink the dispatcher, print what it did. A `curl | sh`
that calls a model in the middle of the pipe is a `curl | sh` nobody should run: the
genre is trusted because it is auditable and offline. It must also work on a machine
with no agent installed at all.

**Half two — `braid setup`, in an agent session.** Learning about *this* repository is a
conversation, not a questionnaire: what the tracker is, what the label vocabulary is,
what `braid verify` should run, what language artifacts are written in. The right
answer to "what is your verify command" comes from reading the Makefile and CI, and
you need to be able to say "not that one, it takes forty minutes."

Being a separate command also makes it **re-runnable** — when the test suite changes,
or a coworker arrives with a different agent.

### Auditability

The engine stays shell rather than a compiled binary: for a tool distributed by
`curl | sh`, **what you run is what you read**. A binary would need published checksums
and reproducible builds nobody verifies, and dropping Windows removed the only real
argument for one.

### Which version, and installed by whom

**The default is the latest release, never `main`.** An installer that defaults to a
branch makes every new user a tester and every `braid upgrade` an unannounced jump. The
tag is resolved with `git ls-remote --sort=-v:refname`: git is already a hard dependency,
it needs no token and has no rate limit, and it does the version ordering — `sort -V` is
not on a stock macOS.

**The URL the script is fetched from does not decide which engine you get.** `--ref` does.
Worth saying because the opposite is the natural guess: fetching
`raw/.../v0.1.0/install.sh` looks like pinning and is not, since that file downloads
whatever its own `REF` says.

**Piped from curl, `install.sh` is a bootstrapper.** It checks the machine, resolves the
ref, downloads it, and hands over to the `install.sh` *inside that tarball*. Run from a
directory that already holds the engine, it is the installer itself.

The split exists because the installer changes between versions. Without it, the file on
`main` installs an older engine using a newer installer — a combination nobody tested and
nothing declares. `braid upgrade` already had this property, because it runs the new
version's `install.sh`; a fresh install did not, and two entry points with different
guarantees is worse than either. The constraint that follows: the bootstrapper may pass
the inner run **only flags that have always existed**, because that run may be any
released version. Anything newer travels as an environment variable, which an older
script ignores harmlessly.

`REF` beside the engine records what it was installed from, and `doctor` reports it.
`VERSION` cannot answer that: `0.1.0` says nothing about whether this came from the tag
or from `main` a week later, which is exactly the question you have when something
behaves unlike the changelog. It is deliberately outside the manifest — hashing it would
make every install of the same version report as edited by whoever installed it.

### Updates

`braid upgrade` updates one place; every repository gets it. Spawn records the resolved
version in the worktree's `.braid/`, alongside the agent and the model, so a worker can
always say which engine ran it. Comparing what is on disk against the shipped manifest
is what lets an edit made while something was broken survive an upgrade, and a genuine
conflict be reported rather than resolved behind braid's back.

Pinning a version *range* per repository, and `doctor --fix` for drifted wiring, are the
half of this that is designed and not built — see §12.

---

## 4. Platform and dependencies

**macOS, Linux and WSL2.** Not Git Bash. `doctor` detects MSYS/Cygwin and refuses
clearly rather than half-working, because the failure modes there are silent: MSYS
path translation against a native Windows `git`, no tmux so every launcher collapses to
detached, and `printf '%q'` quoting crossing into npm `.cmd` shims. A Windows user
watching workers fail to commit blames braid, not MSYS.

**`git`, `bash`, `python3`, and an agent CLI.** Nothing else — no database, no docker,
no task tracker, no packages.

Each carries a minimum, and each minimum is a decision:

- **git 2.20.** Worktrees are older than that; `git config --worktree` is not, and it is
  what installs a `pre-push` hook in one worker's worktree without touching the human's
  own checkout. Below it the guard degrades to a warning and workers have no remote
  protection at all — which is a thing to be told, not to discover.
- **bash 3.2**, because macOS still ships it as `/bin/bash` and a `curl | sh` tool cannot
  demand a brew install before its first command works. No `declare -A`, no `mapfile`,
  no `${var,,}`. Enforced in CI, on macOS, where 3.2 is real.
- **Python 3.9, standard library only.** No `pip`, ever. The floor is `list[str]` in the
  hooks' own annotations, which is evaluated at import time — so on 3.8 the guard hook
  does not fail a test, it fails to load. Python earns its place for JSON parsing (ADE
  and `gh` output) and for `guard_remote.py`, which parses shell command lines with
  `shlex` and is a real program. Parsing JSON in pure bash produces silently wrong
  answers, and `jq` is *less* widely installed than `python3`, so reaching for it trades
  a common dependency for a rarer one.

**`doctor` checks all three**, and it is the only place braid version-gates anything.
Everywhere else — launchers, agents — capability is probed, because a version number
does not tell you the shape of somebody's JSON response changed. git and python are the
exception because their own CLIs are stable in exactly the way a third party's is not,
and because a minimum stated in a README that nothing enforces is the same decorative
protection a `files:` field would have been (§6).

---

## 5. Choosing an agent

Which agents exist on a machine and which agents a repository supports are different
facts and must not be conflated. Detecting the installer's `PATH` and writing the
winner into a committed file lets one person's laptop decide a team's configuration.

**Repository** declares what it supports, in preference order, committed:

```bash
: "${BRAID_AGENTS:=claude codex}"    # supported here, best first
```

**Machine** declares a preference in `~/.config/braid/config`. **Resolution**, highest
priority first:

```
1.  braid spawn --agent codex     this once
2.  BRAID_AGENT=codex braid …     this session
3.  ~/.config/braid/config        this machine
4.  BRAID_AGENTS, filtered by PATH   this repository, in order
5.  error
```

**A preference outside the repository's list never silently falls back.** Adding an
agent is a decision, not a discovery: Codex has no hooks, so the contract moves into
the prompt and status comes from `finish.sh` — someone has to confirm that is enough
*here*. So it says so, and points at `braid setup --add-agent codex`, which commits.

Agents are also selectable per seat, for the reason that matters: the orchestrator is
the only seat that can push or open pull requests, and it is the only place where a
`PreToolUse` guard runs *before* the permission system. That is a concrete advantage
for Claude Code that workers — sealed in a worktree behind a `pre-push` hook — do not
need.

```bash
BRAID_AGENT_ORCHESTRATE=claude
BRAID_AGENT_WORK=codex
```

Not selectable per slice. Changing agent changes how the contract arrives and who
writes status; that is a capability of the repository, not a property of one task.

`doctor` prints the whole resolution — supported, installed, preferred, resolved — not
just the answer.

---

## 6. The data model

### A slice

The fenced block is **launch configuration, not description**. Three keys and no more:
two that `braid spawn` needs at the moment it launches, and one that `braid plan` needs
to schedule.

    ```braid
    complexity: standard
    setup: no
    blocked-by: 280, 281
    ```

    ## What to build
    ## Acceptance
    ## Out of scope
    ## Blocked by      ← the same blockers in prose, with navigable links

**Complexity, never a model name.** A slice is the most agent-agnostic artifact braid
has: it lives in an issue, written by a skill that does not know which agent will run
it. `model: sonnet` is meaningless in a repository whose workers run Codex, and it
breaks the rule the seats already follow — a vendor's model names belong in one file.
So the slice says how much judgement the work needs, and the adapter says what that is
here.

| | The work | Claude |
|---|---|---|
| `low` | mechanical and fully specified: a rename, a field addition, porting a test | `haiku` |
| `standard` | the default — an ordinary vertical slice | `sonnet` |
| `high` | cross-module, ambiguous, architectural judgement, a migration over real rows | `opus` |

An adapter that is not confident maps nothing and lets its CLI choose; `braid setup`
asks what each level means there, which is the moment somebody with that CLI installed
can answer. `BRAID_MODEL_LOW` / `_STANDARD` / `_HIGH` override either way, and
`braid spawn --model` is the escape hatch for the one slice the mapping gets wrong.

**Why a fence and not `**Key:** value` prose lines.** The old parser was
`grep -i -m1 "$key"` — unanchored, over the whole body — so any prose mention above the
field won. It then took only the first word, which made a multi-value field
unparseable. A fence is unambiguous, renders as a distinct block in a GitHub issue, and
*looks* like machine configuration, so nobody translates it into Spanish.

**`blocked-by` appears twice**, in the fence and in prose, because GitHub does not
linkify `#123` inside a code block and losing navigation in a tracker is losing half
its value. Both are written by `braid plan`, so they are generated, not maintained —
and braid **fails loudly** if they disagree rather than picking one.

**There is no `files` field.** It was aspirational and never used. A refactor touching
four hundred files will never list them, so in practice the field fills with `**` and
the check it justified becomes decorative — which is worse than absent, because it
gives false confidence.

The rule it was meant to protect is protected better by **computing overlap from real
diffs** (`git diff --name-only base...branch`) during the wave:

```
$ braid status
done      agent/01-oauth-callback     @a1b2c3d (4 commits)
working   agent/03-rate-limit
  ⚠  01 and 03 both touching src/router.ts
```

Derived from what happened rather than what was intended, free, and it warns while
there is still time.

### A feature

The plan holds only what nothing else can hold. Waves and cross-slice contracts pass
the glue test; a restatement of the PRD does not.

    ```braid
    prd: #279
    wave 1: 280, 281, 282
    wave 2: 283
    ```

    ## Contracts    ← only what spans slices: interfaces, invariants, data shapes
    ## Traps        ← what will bite: legacy coexistence, a chokepoint

Forty lines, not two hundred. At that size it is not a document, it is the
orchestration plan — which is why the command is `braid plan` and not `braid handoff`.

### Where it lives

**Wherever the work lives.** `BRAID_SLICE_SOURCE` picks between `files` and `github`, and
nothing in the data model above depends on which — that is the whole point of the fenced
block being markdown in both. A third source is a project overriding `braid_fetch_slice`
in `braid.sh`: given an id, print the slice's markdown. There is no second code path.

With `github`, the PRD is the parent issue and slices are its sub-issues; the plan is a
fenced block in the PRD body, safe to overwrite because it is computed rather than
curated. The id a slice is known by is then the issue number, and the branch takes the
title as well — `agent/2-add-a-licence`, because `agent/2` names nothing a person can
read. Those two being different strings is a distinction the file mode never exercises,
and it is where two bugs lived.

With `files`, a folder per feature reproduces the same parent/child relation without
needing a tracker to have the primitive:

```
braid/features/oauth-flow/
  prd.md
  01-callback-endpoint.md
  02-session-store.md
  plan.md
```

The folder is the parent; the files are the children.

---

## 7. Waves

A wave is not a level of the dependency graph. It is a **schedule**, and three
constraints separate the two:

- **`setup: yes` serializes.** Two slices with no dependency between them still cannot
  share a wave if both need the expensive provision path — they share migration
  history. That is a resource constraint, not a logical one.
- **Machine capacity.** Nine parallel agents kill some laptops and not others. The
  moment a concurrency cap exists, a wave stops being a graph level.
- **Collision without dependency.** Two slices that do not block each other but will
  fight over the same file. Recording that as `blocked-by` would be a lie: it is an
  exclusion, not a blocker.

So `braid plan` **derives** the schedule — topological levels from `blocked-by`, then
serialization, then capacity — and shows it for you to argue with. You approve or edit
it; you do not write it by hand.

`BRAID_MAX_WORKERS` is a machine fact, in user config. A repository may declare a
ceiling when its provisioning is heavy. Because a cap requires queueing, and "remember
to only launch four" is exactly what a model forgets on the seventh iteration, the
queue belongs to the tool — which makes the wave, not the individual spawn, the natural
unit:

```bash
braid wave 12 13 14 15 16    # launch up to N, queue the rest, refill as they finish
```

---

## 8. Integration

`braid integrate` does the mechanical half and **stops in a resolvable state** on
trouble — the contract `git rebase` already established, which the orchestrator
understands.

```
$ braid integrate 01-oauth-callback
==> rebasing agent/01-oauth-callback onto feat/oauth
!!  conflict in src/routes/index.ts
    the rebase is in progress in the worker's worktree:
      ~/.braid/worktrees/agent-01-oauth-callback
    resolve there, then: braid integrate --continue 01-oauth-callback
```

```
$ braid integrate 02-session-store
==> rebase clean, fast-forwarded feat/oauth
==> verify… FAIL
!!  feat/oauth is broken by the merge you just did (02-session-store).
    not reaping. fix it on the feature branch, in its own commit.
```

The split is **judgement versus mechanics**. Deciding whether a diff matches its report
and meets its acceptance criteria is irreducibly judgement, and it is why the
orchestrator is an expensive seat. `rebase` → `merge --ff-only` → `verify` → `reap`, in
that order, after an approved gate, is a fixed sequence a model retypes from memory
four times a wave — and can skip the intermediate `verify` on any of them.

This does not take conflict resolution away from the orchestrator. It hands it over at
the right moment, in the right worktree, with the files named and the rebase already
stopped there.

A migration clash is the case that proves the shape: it is *not* a git conflict — both
files exist, the rebase is clean — and it surfaces only when `verify` runs after the
fast-forward. Stopping there, before reaping, and naming the merge that did it, is more
than the sequence gets today.

---

## 9. The project seam

Everything a project says about itself lives in two files, and both follow one rule:
**braid owns the general case, the project owns its delta.** A seam that offers only
replacement forces a project to own the general case too, and then upgrades stop
reaching it.

### braid.sh — four hooks

```
braid_provision         <worktree> <slug> <base> <needs-setup>    at spawn
braid_verify            <worktree>                                the gate
braid_teardown          <worktree> <slug>                         at reap
braid_teardown_feature  <feature-worktree> <feature-slug> <trunk> at reap --feature
```

All optional, all no-ops, because braid has to work in a repository created twenty
minutes ago that has no tests and no `.env`. Whether one is *defined* is decided by
comparing its body against the no-op body, not by `declare -F` — which is true of the
defaults too, and a tool that reports a gate it does not have is worse than one that
reports no gate at all.

The fourth exists because the other three are scoped to one worker and some resources
are not: a database created by a feature's first `setup: yes` worker and reused
idempotently by every later one. It **must** survive each worker's reap — the next
serialized worker is cut from a tree that already holds the previous one's migrations —
so no hook could drop it, and projects kept a Makefile target beside braid to do by hand
what braid was meant to make unnecessary.

`braid reap --feature` runs it, generalizing the check `reap` already makes: refuse
unless every commit of the feature branch is reachable from a protected branch, or
`--force`, saying what is lost. **Against the local trunk** — `git fetch` is the human's,
and a tool that goes to the network to decide whether it may delete something deletes on
a stale answer. It also removes the feature's `refs/braid/landed/*`, the last
braid-owned state a finished feature leaves behind.

### The contract — three states

| State | The repository has | Upgrades |
|---|---|---|
| **bundled** | nothing | reach it |
| **bundled + rules** | `docs/worker-rules.md` | reach the part braid owns |
| **replaced** | `docs/worker-contract.md` | never reach it |

Replacement shipped first and was for a while the only option, so a project with six
house rules copied 118 lines to append them — and every later fix to the bundled
contract silently missed the copy. The setup prompt had to warn against the only
mechanism it offered.

The heading and lead-in are **braid's**, not the project's: a rules file that has to
introduce itself can forget to, and a worker reading an unannounced block at the end of
its contract cannot tell what weight it carries. If both files exist the replacement
wins and `doctor` says the rules file is ignored — silently honouring one of two
contradictory declarations is what costs a wave to notice.

Composition happens **once**, at spawn, into `.braid/contract.md`, and both delivery
paths read that file; the session hook composes only for a worktree made by hand, by
calling the same shell function. Two paths independently computing the same contract is
exactly how the prompt for an agent with no hooks once shipped with no contract in it at
all, and nothing caught it because the simulated agent in the tests does not read its
prompt.

Nothing here is per slice, and there is no templating inside the contract: the moment a
rule needs to interpolate something it belongs in the slice or in `braid.sh`.

---

## 10. The control plane

`braid status` reads state off the filesystem and out of git. The agent development
environment is a **view**; the filesystem is the control plane. That is why the same
wave runs identically in orca, herdr, tmux or detached, and why status works over ssh
from a phone.

`.braid/finish.sh` is appended to every worker's launch command, so a terminal state is
written whether the agent cooperated, crashed, or was never installed. Without it, a
worker that died at launch is indistinguishable from one that is thinking, for twenty
minutes.

The three things every worker needs are therefore delivered twice over — once the way
Claude Code's hooks allow, once by a means that needs nothing of the agent at all:

| | Claude Code | everything else |
|---|---|---|
| the contract (§9) | injected at `SessionStart` | at the top of the prompt, and on disk |
| status | `Stop` hook, which can push back on a dirty tree | `finish.sh` on exit |
| the remote | `PreToolUse` denies `gh` and `git push` | a per-worktree `pre-push` hook |

The second column is the one that has to be right. It is what "works with any agent CLI"
means, and it is the only column an agent released next year is guaranteed to land in.

### Deriving state, not storing it

`braid next` derives the phase every time — is there a PRD, are there slices, do they
carry a config block, is there a plan, are there live worktrees, what does each say.
Stored phase lies the moment anyone does something by hand, and in this workflow
everyone does: an issue created in a browser, an edited plan, a killed worker. A stale
phase file sends you to the wrong step with total confidence, which is the worst
failure mode for the command whose job is to guide.

Nothing is cached today: every signal `next` reads is local and free. When deriving over
a tracker starts putting the network on a command people type whenever they are unsure,
the remote half is what may be cached briefly and the local half is what may not — a
cache that can be stale about the slow-moving half never lies about the half that
matters.

---

## 11. Permissions

Workers launch with approvals off. A wave that stops on a permission prompt stops in a
panel nobody is watching, and the human ends up approving edits one at a time for an
agent whose reasoning they cannot see.

What must be forbidden is forbidden separately, so it survives that:

- **A `pre-push` hook in every worker worktree**, installed at spawn. Agent-agnostic,
  because git enforces it. `--no-verify` bypasses it, which is correct — it guards
  against reflex, not intent.
- **`guard_remote.py`, a `PreToolUse` hook**, in any Claude Code session in the
  repository — usually the orchestrator's seat, the one that can actually push. Hooks
  run *before* the permission system, so it denies with approvals off exactly as it
  does with them on.

---

## 12. Deferred

- **Windows outside WSL2.** See §4.
- **Per-slice agent selection.** See §5. Complexity is per slice; the agent is not.
- **Codex's hooks.** It has them, with the same schema as Claude Code's, so the contract
  and status could arrive the same way. They are registered per machine rather than per
  repository, and gated by a trust model — so using them would make "this repository is
  set up for braid" a fact about a laptop instead of something a team reviewed. That
  tension is worth resolving deliberately rather than at a release boundary.
- **A `files` field.** See §6.
- **A `braid_provision_feature` hook.** See §9.
- **A pinned engine version per repository** (`braid = "^0.3"`), checked by every command,
  and `braid doctor --fix` to repair drifted wiring. The manifest half of this exists;
  the pin does not.
- **`braid pr`.** Opening the pull request stays the human's, and the orchestrator writes
  the proposed title and body to `.braid/pr.md` instead. A command for it would be the
  one thing in braid that touches the remote on its own initiative.
- **A tool-driven loop that interrogates the orchestrator.** Inverting who is in charge
  breaks badly when something goes strange: a rebase conflict needs the orchestrator
  with its context, not a callback.
