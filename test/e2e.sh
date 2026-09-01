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
has "registered hooks by name, not by path" "braid hook guard-remote" "$(cat .claude/settings.json)"
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

# --- what next ----------------------------------------------------------------

phase "what next"
NEXT=$("$BRAID" next 2>&1)
has "wave 1 reads as done" "3 done" "$NEXT"
has "wave 2 does not read as done" "1 todo" "$NEXT"
has "and it says to run it" "braid wave 2" "$NEXT"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
