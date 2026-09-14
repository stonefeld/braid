# Writing an adapter

An adapter is the whole of what braid knows about one agent CLI. braid assumes only this
much: it starts, it works in the directory it was started in, and it exits. Everything
past that is here, which is why these files are thirty lines and why an agent released
next year works without a change to the engine.

One file per agent, `lib/agents/<name>.sh`, defining shell functions. No state, no
subcommands — the engine sources exactly one of them per command and calls what it needs.

**The name is not free.** `agent_usable` asks the adapter whether this machine can run it,
and every adapter braid ships answers "is my binary on PATH" — so the file name is the
name a person writes in `BRAID_AGENTS`, and for anything that ships with braid it is also
the binary's own name. Cursor's CLI is `cursor-agent`, so the adapter is
`cursor-agent.sh`, and it is spelled that way in every document and every command output.

## Three kinds of member, and the difference is the part that bites

| | Absent means |
|---|---|
| **required** | the engine calls it without checking. Omitting it is a broken adapter |
| **optional — skipped** | the feature does not happen. No error, and nothing is lost that this agent could have provided |
| **optional — refused** | the engine **rejects a configuration** that names the feature. Not silence: a `die`, at launch |

The third kind is the one to read twice. `agent_effort_mode` is optional, and omitting it
means any repository that configures a reasoning effort gets a hard failure for the seat
that resolves to this adapter. That is deliberate — a value accepted, recorded, and then
dropped by an adapter that cannot use it is worse than a refusal — but it means "I did not
implement this" and "I refuse this" are the same gesture, and the adapter author is the
only one who knows which they meant.

## The functions

### Required

| | Takes | Gives back |
|---|---|---|
| `agent_available` | — | exit status: can this machine run it |
| `agent_version` | — | one line, for `braid doctor`. Empty is fine |
| `agent_seat_model <seat>` | `design`, `orchestrate`, `work` | a model name, or nothing |
| `agent_complexity_model <level>` | `low`, `standard`, `high` | a model name, or nothing |
| `agent_models` | — | every model name this adapter accepts, space separated, or nothing |
| `agent_injects_contract` | — | exit status: does this CLI deliver braid's contract through a hook |
| `agent_auto_mode` | — | the flags that make it run unattended, as text, for `braid doctor` |
| `agent_command <worktree> <model> <prompt> <effort>` | four, always | a shell command line, printed |

**Nothing is required to be non-empty.** An adapter that maps no models is a working
adapter: the repository says what a tier means, or the CLI's own default runs. Returning
nothing from `agent_models` means "I validate nothing", which is different from "I accept
nothing" — `braid config` and `braid doctor` say which adapters check a model name so that
a name accepted here and refused by the API is an expected asymmetry.

`agent_command` takes **four** arguments whether or not it uses the fourth. The signature
belongs to the contract, not to each adapter's reading of it; an adapter that declares
three still runs, and silently drops whatever the engine passes in the position it did not
declare.

### Naming a model

**An adapter may name a model only where the name is an alias that outlives the model
behind it.** Claude Code's `opus` and `sonnet` stay put while what runs under them
changes, so naming them is safe for as long as this file exists. A name that carries its
version — `gpt-5.6-sol`, `composer-2.5`, `cursor-grok-4.6-high` — is a snapshot, and a
snapshot written into an adapter is wrong before the release carrying it is a week old.

The asymmetry is what decides it. An adapter that names nothing runs whatever the CLI is
configured for, which always works; the repository says what a tier means, and `braid
config` asks for that at the moment somebody with the CLI installed can answer it. An
adapter that names a model which has since moved fails **hard**: the CLI refuses the name,
and for at least one of them it refuses by writing nothing and exiting 0, so a wave reads
as a run of empty successes.

The same rule decides `agent_models`. Declare a closed set only where the set is aliases,
or where the CLI validates names itself. Returning nothing is not a gap — `braid doctor`
says which adapters check a name, so that one accepted here and refused by the API is an
expected asymmetry rather than a surprise.

### Optional — skipped

| | Absent means |
|---|---|
| `agent_command_headless <worktree> <model> <prompt> <effort>` | the interactive command is used for detached workers too. Right only if it does not need a tty |
| `agent_loads_skills` | a skill is handed over as markdown rather than by name |
| `agent_skill_prefix` | required **only** when `agent_loads_skills` succeeds — `/` or `$`, whatever the CLI uses to invoke one |
| `agent_transcript_dir` | this agent contributes no liveness signal, so `BRAID_STALE_SECONDS` has nothing to measure here |
| `agent_seat_effort <seat>` | the seat's effort comes from `BRAID_EFFORT_<SEAT>` or from nothing |
| `agent_level_effort <level>` | the level's effort comes from `BRAID_EFFORT_<LEVEL>`, then `BRAID_EFFORT_WORK`, or from nothing |
| `agent_auto_mode_probe` | `braid doctor` says nothing about unattended mode for this agent |
| `agent_effort_probe` | `braid doctor` reports that effort support cannot be probed |

A probe's job is to ask the **installed CLI** — usually its own `--help` — whether the
flags this adapter sets still exist. Flags move between versions, and a probe is what
turns that into a line in `braid doctor` rather than into eight workers that died at
launch. A probe that returns success without asking anything is worse than no probe: it
reports a green check for a thing nobody verified.

No adapter braid ships names an effort, and the reason is not that they have nothing to
say. Effort costs money, and an engine upgrade that silently raised what a repository
spends would be a worse failure than the gap it closed. The hooks are here for an adapter
whose CLI has a default worth stating; `braid config` is where a repository says what it
wants.

`<level>` is a complexity level — `low`, `standard`, `high` — spelled that way because
`agent_complexity_effort` is the engine's own resolver and the names would collide.

### Optional — refused

| | Absent means |
|---|---|
| `agent_effort_mode` | a configured reasoning effort is a hard error for any seat that resolves to this adapter |

Define it when the CLI has a reasoning-effort control of its own, and give it the text of
how it is set — `braid doctor` prints it. Leave it out when the CLI has none, and a
repository that configures effort is told so rather than having the value dropped.

The portable vocabulary is `low`, `medium`, `high`, `xhigh` — the intersection of the CLIs
braid ships adapters for. Provider-only levels stay reachable through that provider's own
configuration, and through a project's `braid_agent_command`, which receives effort as its
fourth argument.

## Variables an adapter owns

An adapter may take its own settings from the environment, always with
`: "${VAR:=default}"` so that a repository and a person can still override them. Namespace
them by adapter — `BRAID_<ADAPTER>_ARGS` — because the bare `BRAID_AGENT_*` prefix belongs
to the engine, where `BRAID_AGENT`, `BRAID_AGENT_WORK` and `BRAID_AGENT_CMD` already mean
three unrelated things.

Every such variable belongs in `docs/configuration.md`. A setting nobody can find is a
setting nobody has.

## Checking one

`./test.sh agents` runs every adapter against this contract: the required functions, the
conditional `agent_skill_prefix`, and the two mistakes that cost a wave — a headless
command that needs a tty, and an unattended mode that the installed CLI has renamed.

Add an adapter and it is checked automatically; the suite globs this directory.
