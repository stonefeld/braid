#!/usr/bin/env bash
# The agent adapters.
#
# Every file in lib/agents/ is the same contract: braid launches whatever it is
# with the worktree as its working directory, and everything past that lives in
# the adapter. A missing function fails not at launch but pages later, as an
# orchestrator reading a worker that never started — so the interface is checked
# here, along with the two mistakes that cost a wave:
#
#   a headless command without `-p` hangs without a tty, and one without
#   `--force` (for Cursor) proposes changes without applying them — a worker
#   that finishes with an empty diff and a glowing report.
#
# No agent is ever launched and no network is used. A stub `cursor-agent` on
# PATH stands in for the CLI wherever one is needed.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export BRAID_HOME="${BRAID_HOME:-$(pwd)}"

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
    if [[ "$hay" == *"$needle"* ]]; then bad "$label — found '$needle' in: $hay"; else ok "$label"; fi
}
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

# Source an adapter and run a command with its functions. Adapters all define
# the same agent_* names, so they are sourced in a subshell, never here.
with_adapter() {
    # shellcheck disable=SC1090,SC1091  # resolved at runtime, one file per case
    source "$ADAPTER"
    "$@"
}

echo
echo "agents"
echo

# A stub Cursor CLI: --help lists whatever flags the case needs, --version
# answers like one. Everything else succeeds without doing anything.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/cursor-agent" <<'SH'
#!/bin/sh
case "${1:-}" in
    --help) printf '%s\n' "${CURSOR_STUB_HELP:---force --trust --model -p, --print}" ;;
    --version) echo "cursor-agent 0.9-test" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/cursor-agent"

# --- every adapter honours the same interface ---------------------------------

REQUIRED="agent_available agent_version agent_seat_model agent_complexity_model
    agent_models agent_injects_contract agent_loads_skills agent_auto_mode
    agent_auto_mode_probe agent_command agent_transcript_dir"
for file in lib/agents/*.sh; do
    name=$(basename "$file" .sh)
    ADAPTER="$BRAID_HOME/$file"
    for fn in $REQUIRED; do
        if ( with_adapter declare -F "$fn" >/dev/null ); then
            ok "$name defines $fn"
        else
            bad "$name defines $fn"
        fi
    done
    # An adapter that loads skills is told the name; one that does not is handed
    # the markdown — so only the former needs a prefix.
    if ( with_adapter agent_loads_skills ); then
        if ( with_adapter declare -F agent_skill_prefix >/dev/null ); then
            ok "$name loads skills and defines agent_skill_prefix"
        else
            bad "$name loads skills and defines agent_skill_prefix"
        fi
    else
        ok "$name hands skills over as text"
    fi
    for seat in design orchestrate work; do
        if ( with_adapter agent_seat_model "$seat" >/dev/null ); then
            ok "$name answers the $seat seat"
        else
            bad "$name answers the $seat seat"
        fi
    done
    for level in low standard high; do
        if ( with_adapter agent_complexity_model "$level" >/dev/null ); then
            ok "$name answers complexity $level"
        else
            bad "$name answers complexity $level"
        fi
    done
done

# --- cursor-agent ---------------------------------------------------------------

ADAPTER="$BRAID_HOME/lib/agents/cursor-agent.sh"
check "cursor-agent adapter exists" test -f "$ADAPTER"

# Pinned first-party models: Grok for judgement, Composer for the everyday.
is "design seat" "grok-4.6" "$( ( with_adapter agent_seat_model design ) )"
is "orchestrate seat" "grok-4.6" "$( ( with_adapter agent_seat_model orchestrate ) )"
is "work seat" "composer-2.5" "$( ( with_adapter agent_seat_model work ) )"
is "low complexity" "composer-2.5-fast" "$( ( with_adapter agent_complexity_model low ) )"
is "standard complexity" "composer-2.5" "$( ( with_adapter agent_complexity_model standard ) )"
is "high complexity" "grok-4.6" "$( ( with_adapter agent_complexity_model high ) )"
MODELS="$( ( with_adapter agent_models ) )"
for model in grok-4.6 composer-2.5 composer-2.5-fast; do
    has "accepts its own $model" "$model" "$MODELS"
done

# The contract arrives in the prompt, never through a hook: CLI hook support is
# partial and version-dependent, so SessionStart delivery cannot be relied on.
refute "contract is not injected" bash -c 'source "$0" && agent_injects_contract' "$ADAPTER"
check "skills load natively" bash -c 'source "$0" && agent_loads_skills' "$ADAPTER"
is "skill prefix" "/" "$( ( with_adapter agent_skill_prefix ) )"

# Unattended means --force (print mode writes nothing without it) and --trust
# (nobody answers the trust prompt in a detached run).
has "auto mode forces" "--force" "$( ( with_adapter agent_auto_mode ) )"
has "auto mode trusts" "--trust" "$( ( with_adapter agent_auto_mode ) )"

CMD="$( ( with_adapter agent_command "/tmp/wt" "grok-4.6" "do the thing" ) )"
has "interactive runs cursor-agent" "cursor-agent" "$CMD"
has "interactive passes the model" "grok-4.6" "$CMD"
has "interactive carries the prompt" 'do\ the\ thing' "$CMD"
hasnt "interactive is not print mode" " -p " " $CMD "
hasnt "interactive makes no worktree of its own" "worktree" "$CMD"

HEADLESS="$( ( with_adapter agent_command_headless "/tmp/wt" "grok-4.6" "do the thing" ) )"
has "headless runs cursor-agent in print mode" "cursor-agent -p" "$HEADLESS"
has "headless forces writes" "--force" "$HEADLESS"
has "headless trusts the workspace" "--trust" "$HEADLESS"
has "headless passes the model" "grok-4.6" "$HEADLESS"
has "headless carries the prompt" 'do\ the\ thing' "$HEADLESS"
hasnt "headless makes no worktree of its own" "worktree" "$HEADLESS"

NOMODEL="$( ( with_adapter agent_command "/tmp/wt" "" "do the thing" ) )"
hasnt "empty model omits the flag" "--model" "$NOMODEL"
NOMODEL_HEADLESS="$( ( with_adapter agent_command_headless "/tmp/wt" "" "do the thing" ) )"
hasnt "empty model omits the flag headless" "--model" "$NOMODEL_HEADLESS"
has "and still prints" "cursor-agent -p" "$NOMODEL_HEADLESS"

if [[ -n "$( ( with_adapter agent_transcript_dir ) )" ]]; then
    ok "transcript dir named"
else
    bad "transcript dir named"
fi

# The probe is what `braid doctor` reports, so it has to be honest in both
# directions: flags present means usable, a renamed flag means warned.
check "probe passes when the CLI has the flags" \
    env "PATH=$TMP/bin:$PATH" bash -c 'source "$0" && agent_auto_mode_probe' "$ADAPTER"
refute "probe fails when a flag is renamed upstream" \
    env "PATH=$TMP/bin:$PATH" "CURSOR_STUB_HELP=--model" \
        bash -c 'source "$0" && agent_auto_mode_probe' "$ADAPTER"

# Wired in, not just written: the adapter's name is what resolution looks up.
check "usable with the CLI on PATH" \
    env "PATH=$TMP/bin:$PATH" "BRAID_AGENTS=cursor-agent generic" "BRAID_HOME=$BRAID_HOME" \
        bash -c 'source "$BRAID_HOME/lib/agent.sh" >/dev/null 2>&1 && agent_usable cursor-agent'
refute "unusable without the CLI" \
    env "PATH=/usr/bin:/bin" "BRAID_AGENT_CMD=" "BRAID_HOME=$BRAID_HOME" \
        bash -c 'source "$BRAID_HOME/lib/agent.sh" >/dev/null 2>&1 && agent_usable cursor-agent'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
