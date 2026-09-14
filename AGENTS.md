# Working on braid

House rules for anyone — human or agent — changing this repository. These are not
style preferences; each one is load-bearing and there is a reason under it.

The *process* around a change — branches, commits, pull requests, what a good issue looks
like — is [`CONTRIBUTING.md`](CONTRIBUTING.md). This file is what the code itself has to
keep true.

## The shape

| Directory | What it is |
|---|---|
| `bin/braid` | the dispatcher, symlinked onto `PATH` at install |
| `lib/` | the engine — one file per command, plus `core.sh` |
| `lib/agents/` | one adapter per agent CLI, ~30 lines each — the contract is [its README](lib/agents/README.md) |
| `lib/hooks/` | Claude Code hooks |
| `lib/launchers/` | one per place a worker can run, shadowable from `~/.config/braid/` |
| `lib/skills/` | the skills braid owns, installed to the user's agent |
| `lib/templates/` | the `braid.sh` braid writes into a repository that has none |
| `docs/` | the worker contract, and the configuration reference |
| `test/` | `e2e.sh`, plus the parser, the scheduler and the compat invariants |
| `test.sh` | the runner — `./test.sh [suite…]` |

## Rules

**Bash 3.2.** macOS still ships bash 3.2 as `/bin/bash`, and a tool installed with
`curl | sh` cannot ask people to `brew install bash` first. No `declare -A`, no
`mapfile`/`readarray`, no `${var,,}` or `${var^^}`, no `&>>`. CI checks this; do not
work around the check.

**Python 3.9, standard library only.** No `pip`, no virtualenv, no third-party imports —
not in the hooks, not anywhere. "Needs python3" is a dependency people already have;
"needs a python environment" is a support burden. Python earns its place for JSON
parsing and for `guard_remote.py`, which is a real program; everything else is shell.
3.9 is the floor because the hooks annotate with `list[str]`, which is evaluated at
import time — below it a hook does not fail a test, it fails to load.

**No new runtime dependencies.** `git` 2.20, `bash` 3.2, `python3` 3.9, and the agent
CLI. Not `jq` — it is less widely installed than `python3`, so reaching for it trades a
common dependency for a rarer one. `braid doctor` checks all three minimums; if you
raise one, raise it there too.

**Progress goes to stderr, and only to a TTY.** These commands are run by an agent as
often as by a person. A spinner on stdout fills an orchestrator's context with frames
and corrupts what it parses.

```bash
[[ -t 2 ]] && printf '\r  fetching…' >&2
```

**Workers never invoke braid.** A worker starts, works in the directory it was started
in, and exits. That is the entire assumption braid makes about an agent, and it is why
`lib/agents/*.sh` are thirty lines and why an agent released next year will work
without a change here. Nothing may be added that requires a worker to cooperate.

**The filesystem is the control plane.** State is read from disk and from git, never
from an agent development environment's API and never from a file that a command
wrote down and could now be stale. If a state can be derived, derive it.

**Fail loudly, and toward the safe side.** A missing or malformed field is an error,
not a default. Defaulting `setup:` to "no" is the cheap path and the wrong one: a typo
then runs a task without the setup it needed, and it fails strangely half an hour
later rather than at the moment it was misread.

**One spelling per agent.** Nothing braid prints is a brand: commands print the adapter
id — `claude`, `codex`, `cursor-agent`, `generic` — which is also what a person types into
`BRAID_AGENTS` and what their shell completes, because `agent_usable` asks the adapter and
every adapter braid ships answers "is my binary on PATH". Prose may name the product where
the product is the subject, and each document pairs the two the first time: **Cursor**
(`cursor-agent`). Where a sentence is about a value braid reads or prints, it uses the id
— a reader holding a document beside command output should never have to translate.

**The code tells the present; the commits tell the past.** A comment explains why the
code is the way it is, never what it used to be — that is what `git log` is for, and a
comment repeating it ages into a claim nobody verifies. Where the thing you wanted to
write down is "do not go back to X", write a test: a test refuses, a paragraph hopes to
be read. If the guard cannot be written as a test, the comment was describing a change
rather than a trap, and it belongs in the commit message.

`DESIGN.md` is the exception, because naming decisions is its whole job — and even there
a superseded one reads as "this was decided, then superseded by that" rather than as a
story.

**English.** Code, comments, docs, commit messages. What language a *project using*
braid writes its issues in is that project's choice, configured at setup — but the
keys braid parses are always English, because a translated key breaks the parse
silently at the moment a wave starts.

## Tests

`./test.sh` runs every suite; `./test.sh e2e` runs one. Everything happens against a
temporary `HOME`, so an installed braid is never touched.

`test/e2e.sh` installs into a repository created thirty seconds ago and runs a whole
feature through every state — over a hundred assertions, ending in the feature's own teardown.
**No agent is ever launched.** A worker is simulated by committing in its worktree and
running `.braid/finish.sh`, which is exactly what a real worker does: the one thing that
cannot be tested is the agent, and the test does not pretend otherwise.

Three others guard what rots silently — `compat.sh` (bash 3.2, no third-party python,
the manifest, the runner), `slice.sh` (the block parser), `schedule.sh` (wave
derivation). CI runs all four on macOS and Linux, one step each so a red build names
which.

**Add to them when behaviour changes, and check the new test fails without the change.**
Reading a test and believing it would have caught the bug is not the same as watching it
fail; the cheap way to be sure is to run the suite against the code without the fix.

```bash
git stash && ./test.sh e2e ; git stash pop     # it should go red
```

Do not add unit tests for `slugify`.

## Commits

Conventional commits, English, imperative. The body explains *why*, not what — the
diff already says what.
