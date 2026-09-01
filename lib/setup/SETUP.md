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

This fills in `braid.sh`, the one file braid asks a project to write. Three functions:

- **`braid_verify`** — the mechanical gate. Build, typecheck, lint, tests: whatever a
  human should not have to read a diff to check. It runs against a worker's worktree
  before its branch is integrated, and again on the feature branch after every
  fast-forward. **A green result is not permission to integrate; a red one is a refusal.**
- **`braid_provision`** — everything a worker needs before its first turn. A worker's
  worktree is a fresh checkout: no `node_modules`, no virtualenv, no `.env`. Whatever
  makes those appear goes here.
- **`braid_teardown`** — undoes only what provision made *outside* the worktree. A
  container, a database schema, a queue. Leave it empty if provision made nothing.

Read the repository before asking anything: the `Makefile`, `package.json` scripts,
`pyproject.toml`, the CI workflow, any `CONTRIBUTING.md`. Then propose concrete commands
and let them correct you. Two things to check explicitly, because they are the ones that
go wrong:

- **How long does the gate take?** It runs on every integration. If the honest test
  command takes forty minutes, ask what the fast subset is.
- **Does anything need isolating per worker?** A database, a port, a container name. If
  so, `provision_env` gives each worker its own `.env` with its own `BRAID_PORT`, and
  `worker_suffix` gives a short unique string for naming anything else.

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

For any agent whose adapter maps no models — Codex is one — ask which model each
complexity level means, and record it in `braid.sh`:

    : "${BRAID_MODEL_LOW:=…}"  : "${BRAID_MODEL_STANDARD:=…}"  : "${BRAID_MODEL_HIGH:=…}"

## 4. House rules for workers

`docs/worker-contract.md` in this repository, if it exists, replaces the one braid
ships. Offer it only if this project has rules a worker would otherwise break — a
layering rule, a directory that is off limits, a commit convention. If it does not,
skip this; an unnecessary copy is one more file that drifts from upstream.

## 5. Finish

Show `git status` and the diff. Tell them to commit it, and then:

    braid doctor          check the machine can run a wave
    braid plan            once there are slices to schedule

Do not commit for them. Do not create a branch. Do not run a wave.
