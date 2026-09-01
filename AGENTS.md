# Working on braid

House rules for anyone — human or agent — changing this repository. These are not
style preferences; each one is load-bearing and there is a reason under it.

## The shape

| Directory | What it is |
|---|---|
| `bin/braid` | the dispatcher, symlinked onto `PATH` at install |
| `lib/` | the engine — one file per command, plus `core.sh` |
| `lib/agents/` | one adapter per agent CLI, ~30 lines each |
| `lib/hooks/` | Claude Code hooks |
| `lib/skills/` | the skills braid owns, installed to the user's agent |
| `lib/templates/` | `braid.sh` presets and slice templates |
| `docs/` | the protocol, and the worker contract |
| `test/` | the end-to-end |

## Rules

**Bash 3.2.** macOS still ships bash 3.2 as `/bin/bash`, and a tool installed with
`curl | sh` cannot ask people to `brew install bash` first. No `declare -A`, no
`mapfile`/`readarray`, no `${var,,}` or `${var^^}`, no `&>>`. CI checks this; do not
work around the check.

**Python 3 standard library only.** No `pip`, no virtualenv, no third-party imports —
not in the hooks, not anywhere. "Needs python3" is a dependency people already have.
"Needs a python environment" is a support burden. Python earns its place for JSON
parsing and for `guard_remote.py`, which is a real program; everything else is shell.

**No new runtime dependencies.** `git`, `bash`, `python3`, and the agent CLI. Not
`jq` — it is less widely installed than `python3`, so reaching for it trades a common
dependency for a rarer one.

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
not a default. The old code defaulted a missing `Needs setup` to "no", which is the
cheap path — so a typo silently ran a task without the setup it needed and failed
strangely half an hour later.

**English.** Code, comments, docs, commit messages. What language a *project using*
braid writes its issues in is that project's choice, configured at setup — but the
keys braid parses are always English, because a translated key breaks the parse
silently at the moment a wave starts.

## Tests

`test/run.sh` installs into a repository created thirty seconds ago and runs a wave
through every state. **No agent is ever launched.** A worker is simulated by
committing in its worktree and running the stop hook by hand, which is exactly what a
real worker does — the one thing that cannot be tested is the agent, and the test does
not pretend otherwise.

Add to it when behaviour changes. Do not add unit tests for `slugify`.

## Commits

Conventional commits, English, imperative. The body explains *why*, not what — the
diff already says what.
