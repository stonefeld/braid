#!/usr/bin/env bash
# Check this machine can actually run a wave, before it is halfway through one.
#
#   braid doctor
#
# Nothing here is fatal on its own — it prints what is true and what that costs. The
# exit status is non-zero only for something that would stop a spawn outright.
#
# It resolves things rather than reporting conclusions. "agent: claude" is not an
# answer to "why did it launch Claude"; the supported list, what is installed, what you
# preferred, and which of those won, is.

set -uo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"
# shellcheck source=launcher.sh
source "$BRAID_HOME/lib/launcher.sh"
# shellcheck source=worker.sh
source "$BRAID_HOME/lib/worker.sh"
# shellcheck source=contract.sh
source "$BRAID_HOME/lib/contract.sh"
# shellcheck source=source.sh
source "$BRAID_HOME/lib/source.sh"

FATAL=0
fail() {
    bad "$*"
    FATAL=1
}

echo
echo "braid $(braid_version)"
echo

git rev-parse --git-dir >/dev/null 2>&1 || {
    fail "not inside a git repository — braid is worktrees"
    exit 1
}

# --- the machine --------------------------------------------------------------

echo "machine"
case "$(uname -s)" in
    Darwin | Linux) ok "$(uname -s) $(uname -m)" ;;
    MINGW* | MSYS* | CYGWIN*) fail "$(uname -s) — braid needs WSL2 on Windows" ;;
    *) meh "$(uname -s) — untested" ;;
esac
info "bash $(bash --version | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/'), /bin/bash $(/bin/bash --version | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')"

# The two versions that are requirements rather than trivia. Stating a minimum in the
# README that nothing checks is the same decorative protection a `files:` field would
# have been — so it is checked here, and it is the only place braid version-gates
# anything: git's and python's own CLIs are stable in a way a third party's JSON is not.
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    info "python3 $PYTHON_VERSION"
else
    fail "python3 $PYTHON_VERSION — the hooks need 3.9 or newer (builtin generic annotations)"
fi

GIT_VERSION=$(git --version | awk '{print $3}')
if [[ "$(printf '%s\n2.20\n' "${GIT_VERSION%%[!0-9.]*}" | sort -t. -k1,1n -k2,2n | head -1)" == 2.20 ]]; then
    info "git $GIT_VERSION"
else
    meh "git $GIT_VERSION — 2.20+ is needed for the per-worktree push guard; workers would have none"
fi
# What it was installed from, not just what it calls itself. A VERSION of 0.1.0 says
# nothing about whether this came from the v0.1.0 tag or from main a week later.
ENGINE_REF=$(cat "$BRAID_HOME/REF" 2>/dev/null || echo unknown)
# A release tag exactly, not merely something starting with v: `git describe` answers
# v0.1.0-6-gabc1234-dirty for a working copy six commits past the tag, and calling that
# a release is the confusion this line exists to remove.
if [[ "$ENGINE_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "engine: $BRAID_HOME (from $ENGINE_REF)"
elif [[ "$ENGINE_REF" == unknown ]]; then
    info "engine: $BRAID_HOME (installed before braid recorded where from)"
else
    meh "engine: $BRAID_HOME (from $ENGINE_REF — not a release)"
fi
echo

# --- integrity ----------------------------------------------------------------

# Files that differ from what the installer delivered. Not an error — editing the engine
# in place is a legitimate thing to do while something is broken — but upgrade will
# replace them, so it has to be visible before then.
echo "integrity"
if [[ -f "$BRAID_HOME/manifest" ]]; then
    changed=$(
        cd "$BRAID_HOME" || exit 0
        while read -r want file; do
            [[ -n "$file" ]] || continue
            [[ "$want" == unhashed ]] && continue
            got=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1 ||
                sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
            [[ "$got" == "$want" ]] || printf '%s\n' "$file"
        done <manifest
    )
    if [[ -z "$changed" ]]; then
        ok "engine matches what was installed"
    else
        meh "edited since install — braid upgrade will ask before replacing:"
        printf '%s\n' "$changed" | sed 's/^/          /'
    fi
else
    meh "no manifest — upgrade cannot tell your edits from a delivery"
fi
echo

# --- the repository -----------------------------------------------------------

braid_config
CHECKOUT=$(primary_checkout)
BRANCH=$(current_branch)

echo "repository"
ok "checkout: $CHECKOUT"
if is_protected_branch "$BRANCH"; then
    meh "on '$BRANCH' — spawn refuses to cut workers from the trunk; make a feature branch"
elif is_worker_branch "$BRANCH"; then
    meh "on '$BRANCH' — this is a worker's seat, not an orchestrator's"
else
    ok "on '$BRANCH' — workers would be cut from here"
fi
git -C "$CHECKOUT" rev-parse HEAD >/dev/null 2>&1 || fail "no commits yet"
echo

echo "configuration"
if [[ -f "$BRAID_PROJECT_FILE" ]]; then
    ok "braid.sh: $BRAID_PROJECT_FILE"
else
    meh "no braid.sh — no provisioning and no gate. Fine for a first spawn."
fi
for hook in provision verify teardown teardown_feature slice_launchable; do
    if braid_overridden "braid_$hook"; then
        ok "braid_$hook defined"
    else
        info "braid_$hook is a no-op"
    fi
done

# Which of the three states this repository's worker contract is in. A replacement is
# not wrong, but it is the one state where nothing braid ships afterwards reaches the
# workers here, and that is worth saying out loud once a release.
case "$(contract_state "$CHECKOUT")" in
    replaced)
        line="contract: replaced by docs/worker-contract.md — upgrades will not reach it"
        [[ -n "$(contract_rules "$CHECKOUT")" ]] && line="$line; docs/worker-rules.md is ignored"
        meh "$line"
        ;;
    bundled+rules)
        ok "contract: bundled + docs/worker-rules.md ($(wc -l <"$(contract_rules "$CHECKOUT")" | tr -d " ") lines)"
        ;;
    *) ok "contract: bundled" ;;
esac
info "worktrees: $BRAID_WORKTREE_ROOT"
# Resolved, not the setting. braid.sh and a feature's files are read from the branch you
# are standing on; refs and the worktree registry come from the primary checkout. When
# those two are different directories, saying which is which is the whole point.
info "features:  $(slice_dir "$(branch_slug "$BRANCH")")"
info "capacity:  $BRAID_MAX_WORKERS workers at once"
info "protected: $BRAID_PROTECTED_BRANCHES"
if [[ -n "${BRAID_WORKER_IGNORE:-}" ]]; then
    ok "worker ignores: $(printf '%s' "$BRAID_WORKER_IGNORE" | grep -c . | tr -d ' ') patterns, per worktree"
else
    info "worker ignores: none — a worker's own build output is the project's .gitignore to handle"
fi
echo

# --- agents -------------------------------------------------------------------

echo "agents"
info "supported here: $BRAID_AGENTS   ($BRAID_PROJECT_FILE)"
info "installed:      $(agents_installed || echo none)"
for seat in design orchestrate work; do
    if resolved=$( (agent_resolve "$seat") 2>/dev/null ) && [[ -n "$resolved" ]]; then
        name="${resolved%% *}"
        why="${resolved#* }"
        (
            agent_load "$seat"
            # The work seat has no single model: it comes from each slice's complexity,
            # so what is shown is what a standard one would get.
            if [[ "$seat" == work ]]; then
                model=$(agent_complexity standard)
            else
                model=$(agent_model "$seat")
            fi
            printf '  %sok%s    %-12s %-8s via %-22s %s\n' \
                "$_C_GREEN" "$_C_OFF" "$seat" "$name" "$why" "${model:-(the CLI chooses)}"
        ) >&2
    else
        fail "$seat: no usable agent"
    fi
done

# The flag that lets a worker run unattended. If it is renamed upstream, every worker in
# a wave dies at launch, and the cause is one line inside a log nobody is reading yet.
for name in $BRAID_AGENTS; do
    agent_usable "$name" || continue
    (
        # shellcheck disable=SC1090
        source "$BRAID_HOME/lib/agents/$name.sh"
        declare -F agent_auto_mode_probe >/dev/null || exit 0
        if agent_auto_mode_probe; then
            ok "$name unattended mode: $(agent_auto_mode)"
        else
            meh "$name does not seem to accept '$(agent_auto_mode)' — workers would die at launch"
        fi
    ) >&2
done
echo

# --- launchers ----------------------------------------------------------------

echo "launchers"
ade=$(current_ade)
if [[ -n "$ade" ]]; then
    ok "you are inside $ade — workers go there, and a failure there is fatal"
else
    info "no ADE marked this terminal — braid will pick from what is running"
fi
[[ "${BRAID_LAUNCHER:-auto}" != auto ]] && info "pinned: BRAID_LAUNCHER=$BRAID_LAUNCHER"
for name in orca herdr tmux detached; do
    file=$(launcher_file "$name") || continue
    mine=""
    [[ "$file" == "$BRAID_HOME"/* ]] || mine=" (yours: $file)"
    if ( launcher_load "$name" && launcher_available ) 2>/dev/null; then
        ok "$name$mine"
    else
        info "$name unavailable$mine"
    fi
done
echo

# --- workers ------------------------------------------------------------------

echo "workers"
count=0
while read -r worktree; do
    [[ -n "$worktree" ]] || continue
    count=$((count + 1))
done < <(worker_worktrees mine 2>/dev/null)
if [[ "$count" -eq 0 ]]; then
    ok "none off $BRANCH"
else
    meh "$count already off $BRANCH — braid status, and reap them before a new wave"
fi
echo

[[ "$FATAL" -eq 0 ]] || {
    warn "something above would stop a spawn"
    exit 1
}
