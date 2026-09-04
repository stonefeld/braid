#!/usr/bin/env bash
# A whole feature, end to end, in a repository created thirty seconds ago.
#
#   test/e2e.sh
#
# **No agent is ever launched.** A worker is simulated by committing in its worktree and
# running .braid/finish.sh, which is exactly what a real worker does — the one thing that
# cannot be tested is the agent, and pretending otherwise would only test a mock.
#
# The claim being defended is that braid works in a repository with no tests, no build,
# no .env and no tracker. Every default exists to make that true, and the only way to
# keep it true is to start from nothing each time.

set -uo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
PASS=0
FAIL=0

ok() {
    printf '  \033[32mok\033[0m    %s\n' "$*"
    PASS=$((PASS + 1))
}
bad() {
    printf '  \033[31mFAIL\033[0m  %s\n' "$*"
    FAIL=$((FAIL + 1))
}
phase() { printf '\n\033[1m%s\033[0m\n' "$*"; }

is() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label — wanted '$want', got '$got'"; fi
}
has() {
    local label="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then ok "$label"; else bad "$label — no '$needle' in: $hay"; fi
}
hasnt() {
    local label="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then bad "$label — found '$needle'"; else ok "$label"; fi
}

# `cmd && ok … || bad …` is not if-then-else, and shellcheck is right to say so every
# time. These are, and they read better anyway.
check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
refute() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/share" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export BRAID_WORKTREE_ROOT="$TMP/worktrees"
export BRAID_AGENTS=generic BRAID_AGENT_CMD=true BRAID_LAUNCHER=detached
mkdir -p "$HOME"

echo
echo "braid end-to-end  ($TMP)"

# --- install ------------------------------------------------------------------

phase "install"
sh "$SOURCE/install.sh" --prefix "$TMP/bin" >/dev/null 2>&1
BRAID="$TMP/bin/braid"
check "installs onto PATH" test -x "$BRAID"
is "reports its version" "$(cat "$SOURCE/VERSION")" "$("$BRAID" version)"
# Which VERSION alone cannot answer: 0.1.0 says nothing about whether this engine came
# from the v0.1.0 tag or from main a week after it. Installed from a working copy here,
# so it is whatever git calls this checkout — the point is that something is recorded.
check "records what it was installed from" test -s "$XDG_DATA_HOME/braid/REF"
has "and doctor says so" "$(cat "$XDG_DATA_HOME/braid/REF")" "$("$BRAID" doctor 2>&1)"
has "flagging an engine that is not a release" "not a release" "$("$BRAID" doctor 2>&1)"

# --- a repository with nothing in it ------------------------------------------

phase "a repository created thirty seconds ago"
REPO="$TMP/project"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main
git config user.email braid@example.com
git config user.name braid
printf 'one\ntwo\nthree\n' >app.txt
git add -A
git commit -qm "initial"

"$BRAID" setup --scaffold >/dev/null 2>&1
check "setup wrote braid.sh" test -f braid.sh
check "gitignored .braid/" grep -qx '.braid/' .gitignore
# The glob, not just the directory: an agent that writes beside the checkout — which is
# what they did before the seats had a .braid/ — leaves .braid-verify-<slug>.log, and
# `.braid/` does not match it. One real feature left forty of them, 1.1 MB, one `git add
# -A` away from the branch.
check "and the stray logs an agent writes beside it" grep -qx '.braid-\*.log' .gitignore
has "registered hooks by name, not by path" "braid hook guard-remote" "$(cat .claude/settings.json)"

# The one command somebody runs before they know anything about braid. It used to open
# whatever tier the adapter names for `design` — for Claude that is the most expensive
# model there is — with no flag to change it and nothing on screen saying you could.
OUT=$(BRAID_AGENT_CMD='echo model={model}' "$BRAID" setup --model haiku </dev/null 2>&1)
has "setup takes a model, like the seats that always could" "model=haiku" "$OUT"
has "and names the escape hatch before opening anything" "braid setup --model" "$OUT"
has "and points at where the whole table is" "braid doctor" "$OUT"
# With nobody there to answer, it proceeds. Blocking on a prompt that cannot be seen is
# worse than the thing the prompt guards against — it would hang every CI run.
hasnt "and does not stop to ask when no one is there" "open it?" "$OUT"
git add -A
git commit -qm "chore: braid"

git checkout -q -b feat/auth

# --- slices -------------------------------------------------------------------

phase "slices and a schedule"
D="braid/features/auth"
mkdir -p "$D"
slice() {
    # shellcheck disable=SC2016  # the braid fence is literal text, not an expansion
    printf '# %s\n\n```braid\ncomplexity: %s\nsetup: %s\nblocked-by: %s\n```\n\n## What to build\n\n%s\n' \
        "$1" "$2" "$3" "$4" "$5" >"$D/$1.md"
}
slice 01-login standard no "" "Add a login route. This slice needs setup: yes is a sentence, not a field."
slice 02-session standard no "" "Add the session store."
slice 03-audit low no "" "Add an audit line."
slice 04-e2e standard yes "01-login" "Drive it through a browser."

has "prose above the block does not become a field" "wave 1" "$("$BRAID" plan --dry-run 2>&1)"
"$BRAID" plan >/dev/null 2>&1
PLAN=$(cat "$D/plan.md")
has "wave 1 holds the independent slices" "wave 1: 01-login, 02-session, 03-audit" "$PLAN"
has "a blocked slice waits" "wave 2: 04-e2e" "$PLAN"
has "the plan keeps room for what only it holds" "## Contracts" "$PLAN"

# --- a wave -------------------------------------------------------------------

phase "a wave"
"$BRAID" wave 1 >/dev/null 2>&1
COUNT=$(git worktree list | grep -c 'agent-')
is "one worktree per slice" "3" "$COUNT"

W() { printf '%s/agent-%s' "$BRAID_WORKTREE_ROOT" "$1"; }
check "each worker gets its own port" grep -q '^BRAID_PORT=' "$(W 01-login)/.env"
P1=$(grep '^BRAID_PORT=' "$(W 01-login)/.env" | cut -d= -f2)
P2=$(grep '^BRAID_PORT=' "$(W 02-session)/.env" | cut -d= -f2)
check "ports differ between workers" test "$P1" != "$P2"

# The single most expensive thing braid can get wrong here: if a worker can commit
# .braid/, every worker commits a different version of the same paths and every
# integration after the first conflicts on files no slice mentions.
(cd "$(W 01-login)" && git add -A)
STAGED=$(git -C "$(W 01-login)" status --porcelain | grep '\.braid' || true)
is "a worker cannot commit .braid/" "" "$STAGED"

# --- when the tracker does not answer -----------------------------------------

phase "a tracker that cannot be reached"
# `could not read the sub-issues of #1` is true and useless: it is the same sentence for
# gh missing, gh logged out, no network, and an issue that does not exist, and those have
# four different remedies. A fake gh makes both branches deterministic — the real one is
# installed and authenticated on this machine and neither on CI.
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/fakebin/gh"
chmod +x "$TMP/fakebin/gh"
OUT=$(PATH="$TMP/fakebin:$PATH" BRAID_SLICE_SOURCE=github "$BRAID" plan --prd 1 2>&1)
has "a logged-out gh says how to log in" "gh auth login" "$OUT"

# shellcheck disable=SC2016  # $1 belongs to the fake gh, not to this script
printf '#!/bin/sh\ncase "$1" in auth) exit 0 ;; *) exit 1 ;; esac\n' >"$TMP/fakebin/gh"
OUT=$(PATH="$TMP/fakebin:$PATH" BRAID_SLICE_SOURCE=github "$BRAID" plan --prd 1 2>&1)
has "a working gh points at the issue instead" "about the issue itself" "$OUT"
hasnt "and does not send you to log in again" "gh auth login" "$OUT"
# The failure to list is not the same event as there being nothing to list, and saying
# both is saying one of them wrongly.
hasnt "nor contradicts itself with 'no slices found'" "no slices found" "$OUT"

DOC=$(PATH="$TMP/fakebin:$PATH" BRAID_SLICE_SOURCE=github "$BRAID" doctor 2>&1)
has "doctor treats the tracker as a precondition" "slices: github" "$DOC"
has "and files mode says so too" "slices: files" "$("$BRAID" doctor 2>&1)"
rm -rf "$TMP/fakebin"

# --- what a worker's own run leaves behind ------------------------------------

phase "junk a fresh worktree makes and the project never ignores"
# The contract tells every worker to commit everything. A worktree is a fresh checkout
# where a full install and test run happen, and that produces things a repository may
# genuinely not ignore, because in the human's checkout they never appear. One `git add
# -A` and every integration afterwards carries them.
cat >>braid.sh <<'TXT'
BRAID_WORKER_IGNORE='.pytest_cache/
*.coverage'
TXT
printf '.DS_Store
' >"$HOME/.gitignore-global"
git config --global core.excludesFile "$HOME/.gitignore-global"
slice 96-junk low no "" "Do nothing."
"$BRAID" spawn "$D/96-junk.md" --no-launch >/dev/null 2>&1
mkdir -p "$(W 96-junk)/.pytest_cache"
touch "$(W 96-junk)/.pytest_cache/x" "$(W 96-junk)/run.coverage" \
    "$(W 96-junk)/.DS_Store" "$(W 96-junk)/real.txt"
DIRTY=$(git -C "$(W 96-junk)" status --porcelain)
has "the real file still shows" "real.txt" "$DIRTY"
hasnt "the project's declared junk does not" "pytest_cache" "$DIRTY"
hasnt "nor the glob" "run.coverage" "$DIRTY"
# Setting core.excludesFile per worktree replaces the person's global one, so braid seeds
# it with theirs — otherwise it would silently un-ignore their .DS_Store in every worker.
hasnt "and their own global ignores survive it" ".DS_Store" "$DIRTY"
# Nothing about the repository or the human's checkout changed to make that true.
touch "$REPO/run.coverage"
has "the human's checkout is untouched" "run.coverage" "$(git status --porcelain)"
rm -f "$REPO/run.coverage"
hasnt "and the project's .gitignore was not edited" "coverage" "$(cat .gitignore)"
"$BRAID" reap 96-junk --force >/dev/null 2>&1
git config --global --unset core.excludesFile

# --- the contract reaches an agent that has no hooks --------------------------

phase "the contract, for an agent with no hooks"
# This shipped broken. spawn defined agent_injects_contract in the adapters and never
# called it, so an agent without a session hook — Codex, generic, anything future —
# received a prompt with the slice in it and no contract at all. Nothing here caught it
# because the simulated agent does not read its prompt; a real wave did, immediately,
# by finishing without committing.
slice 99-contract low no "" "Do nothing."
BRAID_AGENT_CMD='echo {prompt}' "$BRAID" spawn "$D/99-contract.md" >/dev/null 2>&1
sleep 1
PROMPTED=$(cat "$(W 99-contract)/.braid/session.log" 2>/dev/null)
has "the whole contract is in the prompt" "# Worker contract" "$PROMPTED"
has "including the rule that costs the most" "You commit everything" "$PROMPTED"
has "and the slice after it" "Do nothing." "$PROMPTED"
check "and it is on disk too" test -s "$(W 99-contract)/.braid/contract.md"
"$BRAID" reap 99-contract --force >/dev/null 2>&1

# --- house rules, appended rather than copied ---------------------------------

phase "a project's own rules, appended to the contract"
# The alternative braid shipped with was replace-or-nothing: six house rules cost a copy
# of the whole contract, and every later fix to the bundled one missed the copy silently.
mkdir -p docs
printf '# House rules\n\nNever migrate the shared schema.\n' >docs/worker-rules.md
slice 98-rules low no "" "Do nothing."
BRAID_AGENT_CMD='echo {prompt}' "$BRAID" spawn "$D/98-rules.md" >/dev/null 2>&1
sleep 1
PROMPTED=$(cat "$(W 98-rules)/.braid/session.log" 2>/dev/null)
COMPOSED=$(cat "$(W 98-rules)/.braid/contract.md" 2>/dev/null)
has "the bundled contract still arrives" "# Worker contract" "$COMPOSED"
has "under a heading braid supplies" "## House rules" "$COMPOSED"
has "with the project's own text after it" "Never migrate the shared schema." "$COMPOSED"
is "and the bundled contract appears once" "1" \
    "$(printf '%s\n' "$COMPOSED" | grep -c '^# Worker contract$')"
has "the prompt carries exactly what is on disk" "$COMPOSED" "$PROMPTED"
CTX=$(printf '{"cwd":"%s"}' "$(W 98-rules)" | "$BRAID" hook session-start)
has "and so does the session hook" "Never migrate the shared schema." "$CTX"
has "doctor names the state" "bundled + docs/worker-rules.md" "$("$BRAID" doctor 2>&1)"
"$BRAID" reap 98-rules --force >/dev/null 2>&1

# A full replacement still wins, and doctor says what that costs.
printf '# Worker contract\n\nOurs, entirely.\n' >docs/worker-contract.md
DOC=$("$BRAID" doctor 2>&1)
has "a replacement is reported as one" "replaced by docs/worker-contract.md" "$DOC"
has "and the rules file as ignored" "docs/worker-rules.md is ignored" "$DOC"
slice 97-replaced low no "" "Do nothing."
"$BRAID" spawn "$D/97-replaced.md" --no-launch >/dev/null 2>&1
COMPOSED=$(cat "$(W 97-replaced)/.braid/contract.md")
has "the replacement is what is delivered" "Ours, entirely." "$COMPOSED"
hasnt "and the rules file is not" "Never migrate" "$COMPOSED"
"$BRAID" reap 97-replaced --force >/dev/null 2>&1

rm -f docs/worker-contract.md docs/worker-rules.md
DOC=$("$BRAID" doctor 2>&1)
has "with neither, doctor says bundled" "contract: bundled" "$DOC"
hasnt "and mentions no file of the project's" "worker-rules.md" "$DOC"

# --- the remote, for an agent that cannot be hooked ---------------------------

phase "the push guard"
# This shipped as documentation only: BRAID_PUSH_GUARD was a config default nothing read,
# while the README, the worker contract and two adapters all said the hook existed. For
# Codex and generic it is the only remote protection there is, so its absence meant they
# had none at all.
git init -q --bare "$TMP/remote"
git remote add origin "$TMP/remote"
is "a worker's hooks come from .braid/" ".braid/githooks" \
    "$(git -C "$(W 02-session)" config --get core.hooksPath)"
refute "and a worker cannot push" git -C "$(W 02-session)" push origin HEAD
has "it says why" "Workers do not push" "$(git -C "$(W 02-session)" push origin HEAD 2>&1)"
is "the human's own checkout is untouched" "" "$(git config --get core.hooksPath || true)"

# --- the hooks ----------------------------------------------------------------

phase "hooks"
CTX=$(printf '{"cwd":"%s"}' "$(W 01-login)" | "$BRAID" hook session-start)
has "the contract reaches a worker" "never touch the remote" "$CTX"
has "so does its slice" "Your assigned slice" "$CTX"
is "and nothing reaches an ordinary session" "" "$(printf '{"cwd":"%s"}' "$REPO" | "$BRAID" hook session-start)"

# The payload is built by json.dumps, not by printf: a command containing quotes —
# `bash -lc "gh issue list"`, which is exactly the nesting the guard has to see through —
# produces invalid JSON, the hook cannot parse it, and it exits silently allowing
# everything. The test would then pass for the wrong reason.
decision() {
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$1" "$2" |
        "$BRAID" hook guard-remote |
        python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])
except Exception: print("allow")'
}
is "a worker may not push" "deny" "$(decision "$(W 01-login)" 'git push origin HEAD')"
is "nor reach the remote through a nested shell" "deny" "$(decision "$(W 01-login)" 'bash -lc "gh issue list"')"
is "but may commit a message that mentions pushing" "allow" \
    "$(decision "$(W 01-login)" 'git commit -m "do not git push this"')"
is "the orchestrator may push its own branch" "allow" "$(decision "$REPO" 'git push origin feat/auth')"
is "and may not push the trunk under another name" "deny" "$(decision "$REPO" 'git push origin HEAD:main')"

# --- workers finish -----------------------------------------------------------

phase "workers finish"
work() {
    local slug="$1" file="$2" content="$3" report="${4:-}"
    printf '%s\n' "$content" >"$(W "$slug")/$file"
    git -C "$(W "$slug")" add -A
    git -C "$(W "$slug")" commit -qm "$slug"
    [[ -n "$report" ]] && printf '%s\n' "$report" >"$(W "$slug")/.braid/report.md"
    bash "$(W "$slug")/.braid/finish.sh" "$(W "$slug")"
}
work 01-login login.txt "login" "Added the login route."
work 02-session app.txt "one
SESSION
three" "Rewrote line two."
work 03-audit audit.txt "audit" # no report

# A dirty tree outranks a report: a rebase would lose the uncommitted work while the
# branch's history moved out from under it.
printf 'scratch\n' >"$(W 03-audit)/scratch.txt"
bash "$(W 03-audit)/.braid/finish.sh" "$(W 03-audit)"

STATUS=$("$BRAID" status 2>&1)
has "a worker that committed and reported is done" "done            agent/01-login" "$STATUS"
has "a dirty tree is reported as dirty" "dirty           agent/03-audit" "$STATUS"
rm "$(W 03-audit)/scratch.txt"
bash "$(W 03-audit)/.braid/finish.sh" "$(W 03-audit)"
has "silence is not success" "done-no-report  agent/03-audit" "$("$BRAID" status 2>&1)"

# Nobody declared these files. The overlap is computed from the diffs, during the wave.
work 03-audit app.txt "one
AUDIT
three"
has "overlap is computed from real diffs" "app.txt" "$("$BRAID" status 2>&1)"

# --- the gate -----------------------------------------------------------------

phase "the gate"
cat >>braid.sh <<'TXT'
braid_verify() { ! grep -q BROKEN "$1/app.txt"; }
TXT
git add -A
git commit -qm "chore: a gate"
check "a clean worker passes the gate" "$BRAID" verify 01-login

# --- integrating --------------------------------------------------------------

phase "integrating"
check "the first integrates cleanly" "$BRAID" integrate 01-login
check "so does the second" "$BRAID" integrate 02-session

# 03-audit rewrote the same line 02-session did. It has to stop, in place.
"$BRAID" integrate 03-audit >/dev/null 2>&1
is "a conflict exits 2" "2" "$?"
check "and leaves the rebase in the worker's worktree" \
    test -d "$(git -C "$(W 03-audit)" rev-parse --git-path rebase-merge)"
"$BRAID" integrate --continue 03-audit >/dev/null 2>&1
is "--continue refuses while files are unmerged" "1" "$?"

printf 'one\nSESSION+AUDIT\nthree\n' >"$(W 03-audit)/app.txt"
git -C "$(W 03-audit)" add app.txt
check "resolving lets it continue" "$BRAID" integrate --continue 03-audit

is "the feature branch has no merge commits" "0" "$(git log --merges --oneline | wc -l | tr -d ' ')"
has "and reads as one line of work" "03-audit" "$(git log --oneline -1)"

# --- a gate that goes red -----------------------------------------------------

phase "a merge that breaks the gate"
slice 05-bad standard no "" "Break it."
"$BRAID" spawn "$D/05-bad.md" --no-launch >/dev/null 2>&1
work 05-bad app.txt "BROKEN" "Broke it."
"$BRAID" integrate 05-bad >/dev/null 2>&1
is "a red gate after the fast-forward exits 5" "5" "$?"
check "and nothing is reaped" git show-ref --verify --quiet refs/heads/agent/05-bad
git reset --hard HEAD^ >/dev/null 2>&1

# --- reaping ------------------------------------------------------------------

phase "reaping"
# The trap this exists for: `git branch -d` asks about HEAD, so reaping from the trunk
# refuses to delete a branch that is perfectly well integrated into the feature branch.
git checkout -q main
check "reaps from the trunk, against the recorded base" "$BRAID" reap 01-login
refute "the branch is gone" git show-ref --verify --quiet refs/heads/agent/01-login
check "and is recorded as landed" git show-ref --verify --quiet refs/braid/landed/01-login

git checkout -q feat/auth
"$BRAID" reap 05-bad >/dev/null 2>&1
is "refuses to reap unintegrated work" "1" "$?"
check "--force says so and does it" "$BRAID" reap 05-bad --force
"$BRAID" reap --merged >/dev/null 2>&1
is "reap --merged clears the wave" "0" "$(git worktree list | grep -c 'agent-')"

# --- the branch you stand on is where the instructions live -------------------

phase "a feature worktree, with the primary checkout on the trunk"
# The shape of a real run and the one nothing here exercised: the orchestrator sits on
# the feature branch in a worktree of its own while the primary checkout stays on the
# trunk. `primary_checkout` answers the same from every worktree, so braid read its
# instructions from one branch and did the work on another — a plan committed on the
# feature branch had no effect, because braid was reading an untracked copy in the
# trunk's tree, and a hook a feature added to its own braid.sh was invisible to the run
# it was written for. That run only worked by accident.
SEAT="$TMP/feat-beta"
git checkout -q main
git worktree add -q "$SEAT" -b feat/beta
cd "$SEAT" || exit 1

# A braid.sh that exists only on this branch.
cat >braid.sh <<'TXT'
: "${BRAID_AGENTS:=generic}"
braid_verify() { test -f "$1/beta-marker"; }
TXT
mkdir -p braid/features/beta
# shellcheck disable=SC2016  # the braid fence is literal text, not an expansion
printf '# %s\n\n```braid\ncomplexity: low\nsetup: no\nblocked-by: \n```\n\n## What to build\n\nb\n' \
    01-beta >braid/features/beta/01-beta.md
git add -A
git commit -qm "chore: beta brings its own braid.sh"

DOC=$("$BRAID" doctor 2>&1)
has "braid.sh comes from the branch that defines it" "$SEAT/braid.sh" "$DOC"
has "and so does the feature's directory" "$SEAT/braid/features/beta" "$DOC"

"$BRAID" plan >/dev/null 2>&1
check "the plan is written where the work is" test -f "$SEAT/braid/features/beta/plan.md"
refute "and not into the trunk's tree" test -f "$REPO/braid/features/beta/plan.md"

# The gate defined on this branch is the one that runs, which is what a mid-feature hook
# is for. It fails until its marker exists, and the marker is this branch's business.
"$BRAID" verify >/dev/null 2>&1
is "the branch's own gate is the one that runs" "1" "$?"
touch "$SEAT/beta-marker"
check "and it passes once this branch says so" "$BRAID" verify

cd "$REPO" || exit 1
git worktree remove --force "$SEAT"
git branch -qD feat/beta
git checkout -q feat/auth

# --- the orchestrator's own seat ----------------------------------------------

phase "the seat an orchestrator works from"
# Workers get a .braid/ at spawn; the design and orchestrator seats got nothing, while
# the contract they run under says "anything that might take minutes goes to a file under
# .braid/". An agent told that, in a worktree with no such directory, writes
# .braid-verify-<slug>.log beside the checkout instead.
rm -rf "$REPO/.braid"
BRAID_AGENT_CMD=true "$BRAID" orchestrate --here >/dev/null 2>&1
check "orchestrate makes one before the agent starts" test -d "$REPO/.braid"
printf 'a long test run\n' >"$REPO/.braid/verify.log"
is "and nothing in it can be committed" "" "$(git status --porcelain -- .braid 2>/dev/null)"

# --- a launcher that owns the worktree ----------------------------------------

phase "reaping under a launcher that deletes the worktree"
# This is what orca does: `launcher_forget` is `orca worktree rm --force`, which removes
# the directory. reap then ran `git worktree remove` on a path that was already gone,
# died, and never reached the `update-ref` below it — so every reap under orca lost the
# landed ref, and `braid next` reported integrated waves as never started. The comment
# above that update-ref described exactly the harm the die above it was causing.
mkdir -p "$XDG_CONFIG_HOME/braid/launchers"
# Not `rm -rf`: orca removes the worktree with git, which also deregisters it, and that
# is what makes braid's own `git worktree remove` fail with "is not a working tree". A
# plain rm leaves the admin entry behind and modern git removes it happily — simulating
# it that way passes against the broken code and proves nothing.
cat >"$XDG_CONFIG_HOME/braid/launchers/greedy.sh" <<'LAUNCHER'
launcher_available() { return 0; }
launcher_launch() { return 0; }
launcher_owns_worktree() { return 0; }
launcher_forget() {
    local wt="${1:?}" common
    common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 0
    git -C "$(dirname "$common")" worktree remove --force "$wt" >/dev/null 2>&1 || true
}
LAUNCHER
slice 07-greedy low no "" "Its launcher owns the worktree."
BRAID_LAUNCHER=greedy "$BRAID" spawn "$D/07-greedy.md" >/dev/null 2>&1
check "a launcher from ~/.config shadows nothing and still loads" test -d "$(W 07-greedy)"
work 07-greedy greedy.txt "greedy" "Did it."
"$BRAID" integrate 07-greedy >/dev/null 2>&1
check "reap succeeds even though the tree is already gone" "$BRAID" reap 07-greedy
check "and the landed ref survived" git show-ref --verify --quiet refs/braid/landed/07-greedy
refute "the branch is gone" git show-ref --verify --quiet refs/heads/agent/07-greedy
is "and git is not left advertising a worktree that vanished" "0" \
    "$(git worktree list | grep -c 'agent-07-greedy')"

# --- an id that is not its own slug -------------------------------------------

phase "a slice whose id and branch name differ"
# With files the two are the same string, so nothing here ever exercised them being
# different. With a tracker they are not: the plan says `2`, the branch is
# `agent/2-add-a-licence`. Two bugs lived in that gap — spawn recorded the branch slug as
# the id, and reap read the id after deleting the worktree it lived in — and between them
# a wave that had been built, integrated and reaped read as never started.
slice 42 low no "" "An id that is not a filename."
mv "$D/42.md" "$D/42-with-a-long-title.md"
"$BRAID" spawn "$D/42-with-a-long-title.md" --no-launch >/dev/null 2>&1
is "the branch takes the readable name" "agent/42-with-a-long-title" \
    "$(git -C "$(W 42-with-a-long-title)" rev-parse --abbrev-ref HEAD)"
work 42-with-a-long-title done.txt "done" "Did it."
"$BRAID" integrate 42-with-a-long-title >/dev/null 2>&1
"$BRAID" reap 42-with-a-long-title >/dev/null 2>&1
check "and the landed marker uses the id the plan knows" \
    git show-ref --verify --quiet "refs/braid/landed/42-with-a-long-title"

# --- where the guidance used to stop ------------------------------------------

phase "what this house does before there are slices"
# braid owns none of grilling, specs or ticket cutting, and never will. It was also not
# naming them, so `braid next` with no slices said "braid has no opinion about how" and
# then opened a blank session — guidance that stops exactly where somebody needs it.
BEFORE=$("$BRAID" next 2>&1)
git checkout -q -b feat/unplanned
NEXT=$("$BRAID" next 2>&1)
has "with nothing named, it still opens the seat" "braid design" "$NEXT"
hasnt "and invents no process" "→ /braid-plan" "$NEXT"

cat >>braid.sh <<'TXT'
: "${BRAID_DESIGN_STEPS:=/grilling /to-spec /to-tickets}"
TXT
NEXT=$("$BRAID" next 2>&1)
has "named, it says what this repository actually runs" "/grilling /to-spec /to-tickets" "$NEXT"
has "and where that ends" "/braid-plan" "$NEXT"
has "doctor lists it with the rest of the configuration" "design steps: /grilling" \
    "$("$BRAID" doctor 2>&1)"
# Said to the person, never put into the agent's prompt. Naming a process is not carrying
# one, and the prompt is exactly where that line would be crossed — so the assertion has
# to separate the two streams, or it passes for the wrong reason.
PROMPT=$(BRAID_AGENT_CMD='echo {prompt}' "$BRAID" design "the payments flow" 2>/dev/null)
NOTES=$(BRAID_AGENT_CMD='echo {prompt}' "$BRAID" design "the payments flow" 2>&1 >/dev/null)
has "the prompt is what you asked for" "the payments flow" "$PROMPT"
has "design names the steps to the person" "/grilling" "$NOTES"
hasnt "and never into the agent's prompt" "/grilling" "$PROMPT"
git checkout -q -- braid.sh
git checkout -q feat/auth
has "and none of this disturbed a feature that has slices" "wave 1" "$BEFORE"

# --- slices in a tracker -------------------------------------------------------

phase "a feature whose slices are issues"
# A stub tracker, not a network. It answers the four calls braid makes and records what
# it was told, which tests the side braid owns; whether the real gh's JSON still has this
# shape is the one thing it cannot say, exactly as the simulated worker cannot test an
# agent. Saying "this needs gh, so it cannot be tested" was wrong: it needs *a* gh.
GH="$TMP/tracker"
mkdir -p "$GH/bin"
cat >"$GH/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# issues live as $GH_STATE/<n>.{title,body,children}
set -uo pipefail
[[ "${1:-}" == auth ]] && exit 0
[[ "${1:-}" == issue ]] || exit 1
shift
verb="$1"
shift
number="$1"
shift
json=""
jq=""
bodyfile=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            json="$2"
            shift 2
            ;;
        --jq | -q)
            jq="$2"
            shift 2
            ;;
        --body-file)
            bodyfile="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
case "$verb" in
    edit)
        [[ -n "$bodyfile" ]] || exit 1
        cp "$bodyfile" "$GH_STATE/$number.body"
        ;;
    view)
        [[ -f "$GH_STATE/$number.body" ]] || exit 1
        case "$json" in
            *subIssues*) cat "$GH_STATE/$number.children" 2>/dev/null ;;
            *body*)
                if [[ -n "$jq" ]]; then
                    cat "$GH_STATE/$number.body"
                else
                    python3 -c 'import json,sys
n,t,b=sys.argv[1:4]
print(json.dumps({"number":int(n),"title":t,"body":open(b).read(),"url":"https://x/"+n}))' \
                        "$number" "$(cat "$GH_STATE/$number.title")" "$GH_STATE/$number.body"
                fi
                ;;
            *title*) cat "$GH_STATE/$number.title" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
FAKEGH
chmod +x "$GH/bin/gh"
export GH_STATE="$GH/state"
mkdir -p "$GH_STATE"

issue() { # number title body children
    printf '%s' "$2" >"$GH_STATE/$1.title"
    printf '%s' "$3" >"$GH_STATE/$1.body"
    printf '%s' "${4:-}" >"$GH_STATE/$1.children"
}
# shellcheck disable=SC2016  # the braid fence is literal text, not an expansion
SLICEBODY='```braid
complexity: standard
setup: no
```

## What to build

A thing.'
issue 100 "Payments" "The PRD, written by a person. This paragraph is the point of the issue." "101
102"
issue 101 "Take a payment" "$SLICEBODY"
issue 102 "Refund a payment" "$SLICEBODY"

git checkout -q -b feat/payments
export PATH="$GH/bin:$PATH" BRAID_SLICE_SOURCE=github

# A flag accepted and quietly ignored is how a flag becomes folklore.
OUT=$(BRAID_SLICE_SOURCE=files "$BRAID" plan --prd 100 2>&1)
has "--prd is refused where there is no PRD issue to name" "BRAID_SLICE_SOURCE=github" "$OUT"

"$BRAID" plan --prd 100 >/dev/null 2>&1
BODY=$(cat "$GH_STATE/100.body")
has "the schedule is written into the PRD issue" "wave 1: 101, 102" "$BODY"
# The fence used to carry `prd: #100`, which inside issue #100 says nothing, and which
# nothing read once the pointer moved to disk.
hasnt "and carries no pointer back to itself" "prd: #100" "$BODY"
has "and the PRD it was written under survives it" "written by a person" "$BODY"
has "the sections only the plan can hold are added once" "## Contracts" "$BODY"
refute "and no plan.md is left in the repository" test -f braid/features/payments/plan.md

# Said once. The pointer is what makes every later command able to find the plan at all.
has "the PRD number is remembered" "100" "$(cat .braid/prd-payments)"
has "so next finds the schedule without being told again" "wave 1" "$("$BRAID" next 2>&1)"

# Re-running rewrites the fence and nothing else — the same guarantee as with files.
printf '%s\n' "$BODY" | sed 's/^<Only what spans.*/The token shape is shared./' \
    >"$GH_STATE/100.body"
"$BRAID" plan >/dev/null 2>&1
BODY=$(cat "$GH_STATE/100.body")
has "a re-run keeps what a person wrote in Contracts" "The token shape is shared." "$BODY"
is "and does not append a second pair of headings" "1" \
    "$(printf '%s\n' "$BODY" | grep -c '^## Contracts')"
has "while the fence itself is rewritten" "wave 1: 101, 102" "$BODY"

git checkout -q feat/auth
unset BRAID_SLICE_SOURCE GH_STATE
PATH="${PATH#"$GH/bin:"}"
export PATH

# --- what next ----------------------------------------------------------------

phase "what next"
NEXT=$("$BRAID" next 2>&1)
has "wave 1 reads as done" "3 done" "$NEXT"
has "wave 2 does not read as done" "1 todo" "$NEXT"
has "and it says to run it" "braid wave 2" "$NEXT"

# --- a feature that is finished -----------------------------------------------

phase "what outlives every worker"
# braid_teardown is per worker, and a resource shared by all of a feature's `setup: yes`
# workers must survive every one of their reaps — the next serialized worker is cut from
# a tree that already holds the previous one's migrations. So it comes down here, once.
info_hook() { "$BRAID" doctor 2>&1 | grep 'braid_teardown_feature'; }
has "undefined, doctor says so" "braid_teardown_feature is a no-op" "$(info_hook)"
# The other project hook that arrived with it, and the reason doctor lists them at all:
# a hook braid does not know about is a hook nobody can tell is being ignored.
has "and lists the slice filter beside it" "braid_slice_launchable is a no-op" \
    "$("$BRAID" doctor 2>&1)"

export MARK="$TMP/torn-down"
cat >>braid.sh <<'TXT'
braid_teardown_feature() { printf '%s %s\n' "$2" "$3" >"$MARK"; }
TXT
git add -A
git commit -qm "chore: a feature teardown"
has "defined, doctor says so" "braid_teardown_feature defined" "$(info_hook)"

# Finish the feature: wave 2 is the last slice, and only a landed feature can be torn down.
"$BRAID" spawn "$D/04-e2e.md" --no-launch >/dev/null 2>&1
work 04-e2e e2e.txt "e2e" "Drove it."
"$BRAID" integrate 04-e2e >/dev/null 2>&1
"$BRAID" reap 04-e2e >/dev/null 2>&1
NEXT=$("$BRAID" next 2>&1)
has "next says to open the PR" "open the PR" "$NEXT"
has "and then to tear the feature down" "braid reap --feature" "$NEXT"

# A worker still off the branch is the one case that must refuse before anything else:
# the hook would undo what that worker is still using.
slice 06-late low no "" "Still going."
"$BRAID" spawn "$D/06-late.md" --no-launch >/dev/null 2>&1
OUT=$("$BRAID" reap --feature 2>&1)
is "refuses while a worker is still off the branch" "1" "$?"
has "and says what to run first" "braid reap --merged" "$OUT"
"$BRAID" reap 06-late --force >/dev/null 2>&1

OUT=$("$BRAID" reap --feature 2>&1)
is "refuses while the feature is not in the trunk" "1" "$?"
has "and says how much is not there yet" "not in main" "$OUT"
refute "having torn nothing down" test -f "$MARK"
check "the landed refs are untouched" git show-ref --verify --quiet refs/braid/landed/01-login

git checkout -q main
git merge -q --ff-only feat/auth
git checkout -q feat/auth
check "once it is in the trunk, it just runs" "$BRAID" reap --feature
is "the hook gets the feature and its trunk" "auth main" "$(cat "$MARK")"
refute "and the feature's landed refs are gone" \
    git show-ref --verify --quiet refs/braid/landed/01-login
refute "all of them" git show-ref --verify --quiet refs/braid/landed/42-with-a-long-title

# Ahead of the trunk again — the same refusal, and what --force costs.
rm -f "$MARK"
git commit -q --allow-empty -m "chore: after the merge"
"$BRAID" reap --feature >/dev/null 2>&1
is "ahead of the trunk again, it refuses again" "1" "$?"
check "--force does it anyway" "$BRAID" reap --feature --force
check "and the hook ran" test -f "$MARK"

# A repository that never defined the hook still gets its refs cleaned.
rm -f "$MARK"
grep -v braid_teardown_feature braid.sh >braid.sh.new && mv braid.sh.new braid.sh
git add -A
git commit -qm "chore: drop the feature teardown"
OUT=$("$BRAID" reap --feature --force 2>&1)
is "with no hook it still succeeds" "0" "$?"
has "and says there was nothing of the project's to undo" "no braid_teardown_feature" "$OUT"
refute "and ran nothing" test -f "$MARK"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
