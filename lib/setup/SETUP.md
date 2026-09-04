# Teach braid about this repository

braid is installed on this machine and the mechanical scaffolding is done. What is left
needs someone who can read this repository, and that is you. Work through the sections
below **one at a time**, showing what you found and getting an answer before moving on.

Assume the person you are talking to has not read braid's documentation. Each section
opens with two or three sentences on what the thing is and what changes depending on
their answer. Be brief. Do not paste this file at them.

Everything you write here is committed and reviewed like any other configuration. When
you are done, show the diff and let them commit it.

---

## 1. How this project is built, tested and set up

This fills in `braid.sh`, the one file braid asks a project to write. Four functions,
all optional:

- **`braid_verify`** — the mechanical gate. Build, typecheck, lint, tests: whatever a
  human should not have to read a diff to check. It runs against a worker's worktree
  before its branch is integrated, and again on the feature branch after every
  fast-forward. **A green result is not permission to integrate; a red one is a refusal.**
- **`braid_provision`** — everything a worker needs before its first turn. A worker's
  worktree is a fresh checkout: no `node_modules`, no virtualenv, no `.env`. Whatever
  makes those appear goes here.
- **`braid_teardown`** — undoes only what provision made *outside* the worktree, for
  one worker. A container, a schema, a queue. Leave it empty if provision made nothing.
- **`braid_teardown_feature`** — undoes what is shared by all of a feature's workers and
  therefore outlives every one of them: a database seeded once by the first `setup: yes`
  worker and reused by the rest. `braid reap --feature` runs it after the feature lands.
  Ask about this only if provision creates something on first need and reuses it after.

Read the repository before asking anything: the `Makefile`, `package.json` scripts,
`pyproject.toml`, the CI workflow, any `CONTRIBUTING.md`. Then propose concrete commands
and let them correct you. Two things to check explicitly, because they are the ones that
go wrong:

- **How long does the gate take?** It runs on every integration. If the honest test
  command takes forty minutes, ask what the fast subset is.
- **Does anything need isolating per worker?** A database, a port, a container name. If
  so, `provision_env` gives each worker its own `.env` with its own `BRAID_PORT`, and
  `worker_suffix` gives a short unique string for naming anything else.
- **What does a full test run leave lying about?** A worker's worktree is a fresh
  checkout where the install and the suite both run, so it produces things this
  repository may not ignore — a `.pytest_cache/` in a project whose tests only run in
  CI, a coverage file, a build cache. The contract tells every worker to commit
  everything, so those are one `git add -A` from the feature branch. Read the
  `.gitignore`, name what you think is missing, and **propose it** for
  `BRAID_WORKER_IGNORE` — do not add it silently, and do not edit the `.gitignore`:
  braid applies these per worktree, so the human's checkout keeps whatever it had.

## 2. Where the work is tracked, and in what language

braid reads slices from files or from a tracker, and this decides which.

- **Files** — slices live as markdown under `braid/features/<feature>/`. The folder is
  the parent, the files are its children. Nothing external is needed.
- **GitHub issues** — slices are issues, and a feature's PRD is their parent issue.

Look at `git remote -v` and at whether `gh` is installed before proposing one.

Then ask what language the artifacts are written in — issues, PRDs, commit messages.
This is a real question with no default: many teams write English code and Spanish
issues. Record the answer in `docs/agents/braid.md`.

**The keys inside a `braid` block are always English**, whatever the answer, because
braid parses them. Say that explicitly; it is the thing people translate.

If they use the tracker option, and they already have a label vocabulary, record the
mapping in the same file. Do not invent labels.

## 3. Which agents this repository supports

`braid.sh` lists them, best first. `braid doctor` shows what is installed here.

Adding one is a decision rather than a detection, and it costs something: an agent
without hooks takes its contract from the prompt instead of from a session hook, and its
status from `.braid/finish.sh` instead of a stop hook. Both work. But if a coworker will
run Codex while they run Claude, the list has to say so, and somebody has to be willing
to say it works here.

### What each seat and each complexity costs

Run `braid doctor` and **show them the resolved table** — which model each seat gets and
which model a `low`, `standard` and `high` slice gets. Do not skip this because the
adapter already has an answer: that answer is a default somebody else chose, it is the
single biggest lever on what a wave costs, and this is the only moment anyone is looking.

Ask one question: *is that the right shape for this repository?* Then record only what
they want changed, in `braid.sh`:

    : "${BRAID_MODEL_DESIGN:=…}"  : "${BRAID_MODEL_ORCHESTRATE:=…}"
    : "${BRAID_MODEL_LOW:=…}"  : "${BRAID_MODEL_STANDARD:=…}"  : "${BRAID_MODEL_HIGH:=…}"

For an agent whose adapter maps nothing — Codex is one — there is no default to show and
the same question has to be answered from scratch.

## 4. How this house decides what to build

braid owns none of this and never will. Grilling an idea, writing a spec, cutting it into
tickets — those are skills this repository already has or does not, and braid's job starts
at *"these slices are launchable"*.

But it can **say what they are**, and not saying them leaves somebody opening `braid
design` to a blank session having just been told braid has no opinion. So ask: from "we
should build something" to a set of slices, what do they actually run here? Slash
commands, a skill, a document they fill in, a conversation with no name at all.

Record whatever has a name, in order, in `braid.sh`:

    : "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"

`braid next` and `braid design` print it and nothing else — braid never runs these. If
there is no named process, leave it empty and say so; an invented one is worse than none.

## 5. House rules for workers

Every worker is launched with braid's own contract: never touch the remote, commit
everything, stay inside the slice, write a report. This section is about what *this*
project has to add to it — a layering rule, a directory that is off limits, the one way
its test suite must be run. If there is nothing, skip the section.

Two ways to say it, and they are not equivalent:

- **`docs/worker-rules.md`** — appended to braid's contract under a `## House rules`
  heading braid supplies. Offer this one. It holds only the delta, and every future
  change to the part braid owns still reaches this project.
- **`docs/worker-contract.md`** — replaces braid's contract entirely. Only for a
  project that wants control of every word, and it costs exactly that: nothing braid
  ships afterwards ever reaches these workers again. `braid doctor` says so on every run.

If both exist the replacement wins and the rules file is ignored, which is a state to
get out of rather than into.

## 6. Finish

Show `git status` and the diff. Tell them to commit it, and then:

    braid doctor          check the machine can run a wave
    braid plan            once there are slices to schedule

Do not commit for them. Do not create a branch. Do not run a wave.
