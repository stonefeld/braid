---
name: braid-plan
description: Make a set of slices launchable — annotate each with the fields braid reads, grill any that cannot be annotated, and derive the wave schedule. Use after a design is settled and the slices exist, before handing the feature to an orchestrator.
---

# braid-plan

The slices exist. Whether they came from a PRD, an issue tracker, or somebody typing
them, this is the pass that turns them into work an orchestrator can launch without you.

You are **not** deciding what the slices are. That decision is upstream and braid has no
opinion about how it was made. You are deciding whether each one is launchable, and in
what order.

## The standard

One question, and it is mechanical rather than aesthetic:

> Can a worker, in a fresh context window, finish this in one session without touching
> the files another slice in the same wave will touch?

That is not "is this well written". It is the condition under which a wave does not
explode. A slice that fails it is not badly documented — it is not launchable, and
saying so is this skill's job.

## 1. Read them all first

Every slice, before annotating any. The waves depend on relationships you cannot see one
file at a time — two slices that quietly both rewrite the same entry point are the
failure this pass exists to catch, and neither of them mentions the other.

## 2. Annotate

Each slice gets a braid block. Configuration of the slice, not description of it:

    ```braid
    complexity: standard
    setup: no
    ```

**`complexity`** — how much judgement the work needs. Never a model name: the slice does
not know which agent will run it, and the adapter maps this locally.

| | |
|---|---|
| `low` | mechanical and fully specified: a rename, a field addition, porting a test |
| `standard` | the default — an ordinary vertical slice |
| `high` | cross-module, ambiguous, architectural judgement, a migration over real rows |

**`setup`** — `yes` only when the slice needs the expensive provision path: a database, a
seeded fixture, something a browser drives. It serialises the slice, so it is not free.
Read `braid.sh` to find out what provisioning actually does here before deciding.

**`blocked-by`** — the slices that must land first. Put it in the block *and* in a
`## Blocked by` section with real `#` links, because GitHub does not linkify inside a
fence. braid fails loudly if the two disagree, so keep them the same.

Only that. Acceptance criteria, scope and everything a worker reads stay in prose,
outside the fence.

## 3. Grill what you cannot annotate

If you cannot decide a slice's complexity, or cannot tell whether it needs setup, or
cannot tell what it will touch — **stop and ask about that slice**. Concretely, not "can
you clarify this": name what is ambiguous and what the two readings would each produce.

The common shapes, and what to do:

- **Two slices that will both edit the same file.** Merge them, or give one the file and
  have the other build behind it. Do not record it as a blocker — neither needs the
  other, it is an exclusion, and `blocked-by` would be a lie the schedule acts on.
- **A slice with no checkable acceptance.** "Works well" and "is tested" are not
  acceptance criteria. Ask what specifically has to be true.
- **A slice that is a whole feature.** If one agent cannot finish it in a session, it is
  two slices, and cutting it is a conversation, not a decision you make quietly.
- **A slice too small to be worth a worktree.** Fold it into a neighbour.

## 4. Derive the schedule

```bash
braid plan --dry-run     # see it
braid plan               # write it
```

You do not write waves by hand. braid derives them from the blockers, then serialises
`setup: yes` slices and respects the machine's capacity — three constraints the
dependency graph does not model.

Show the result and get it confirmed. This is the part they will want to argue with, and
it is cheap to change now and expensive later.

## 5. Write what only the plan can hold

`plan.md` keeps two sections that braid never touches:

- **`## Contracts`** — only what spans slices. An interface two of them implement, an
  invariant they must both hold, the shape of data passed between them. Anything that
  belongs to one slice belongs in that slice.
- **`## Traps`** — what will bite. Coexistence with a legacy path, a chokepoint that has
  to keep working, a module that looks unrelated and is not.

If both are empty, say so rather than inventing content. A feature whose slices share
nothing is a feature that will integrate easily, and that is worth knowing.

## 6. Hand it over

End by telling them, concretely:

> You are on `feat/<slug>`. Start a session in this worktree and run `/braid-orchestrate`.

Do not start it. Do not create a branch. Do not push.
