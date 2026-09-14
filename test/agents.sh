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
#   `--force` (for Cursor) runs with its shell denied — a worker that cannot
#   run the verify command or `git add`, and works around it rather than
#   saying so.
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
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label — wanted '$want', got '$got'"
    fi
}
has() {
    local label="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        ok "$label"
    else
        bad "$label — no '$needle' in: $hay"
    fi
}
hasnt() {
    local label="$1" needle="$2" hay="$3"
    if [[ "$hay" == *"$needle"* ]]; then
        bad "$label — found '$needle' in: $hay"
    else
        ok "$label"
    fi
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
    (
        # shellcheck disable=SC1090,SC1091  # resolved at runtime, one file per case
        source "$ADAPTER"
        "$@"
    )
}

# Same isolation for the engine: agent.sh's names must not land in this shell.
with_agent() {
    (
        # shellcheck disable=SC1090  # BRAID_HOME is this checkout
        source "$BRAID_HOME/lib/agent.sh" >/dev/null 2>&1
        "$@"
    )
}

# The engine with one adapter loaded and $1 defined on top of it, for the cases where
# what is under test is what the engine does when a function exists — or does not.
# cursor-agent because it is the adapter that defines a headless command, which one of
# those cases needs; the others do not care which is loaded.
with_hook() {
    (
        # shellcheck disable=SC1090  # BRAID_HOME is this checkout
        source "$BRAID_HOME/lib/agent.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091  # one adapter, resolved at runtime
        source "$BRAID_HOME/lib/agents/cursor-agent.sh"
        eval "$1"
        "${@:2}"
    )
}

# The engine with an adapter loaded through resolution, which is the path a model
# check actually travels: agent_check_model asks the adapter what it accepts.
with_engine() {
    (
        # shellcheck disable=SC1090  # BRAID_HOME is this checkout
        source "$BRAID_HOME/lib/agent.sh" >/dev/null 2>&1
        agent_load work >/dev/null 2>&1 || exit 1
        "$@"
    )
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

# Every CLI an assertion below needs is stubbed, and $TMP/bin goes first on PATH so the
# stub is what answers even where the real one is installed. A suite that resolves an
# agent off the machine running it passes for a reason that is not the code: the model
# name checks were green on every laptop with Claude Code on it and failed on the first
# push, which is the only place nobody had one.
cat >"$TMP/bin/claude" <<'SH'
#!/bin/sh
case "${1:-}" in
    --help) printf '%s\n' "--permission-mode --effort -p, --print --model" ;;
    --version) echo "0.0-test (Claude Code)" ;;
esac
exit 0
SH
chmod +x "$TMP/bin/claude"

# --- every adapter honours the same interface ---------------------------------

# What the engine calls without checking first, and nothing else: an adapter that omits
# an optional member is a working adapter, and a suite stricter than the contract makes
# the contract the wrong thing to read. lib/agents/README.md is the contract.
REQUIRED="agent_available agent_version agent_seat_model agent_complexity_model
    agent_models agent_injects_contract agent_auto_mode agent_command"
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

# This adapter names no model and validates none, and both are decisions rather than
# gaps. Every name the CLI offers carries its version, and a stale one is refused by
# writing nothing and exiting 0 — a wave on a wrong name reads as a run of empty
# successes. Naming nothing runs whatever the CLI is configured for, and the repository
# says what a tier means here. The rule behind that is checked across every adapter
# further down; this is the one adapter it changed.
NAMED=""
for tier in design orchestrate work; do
    NAMED="$NAMED$( ( with_adapter agent_seat_model "$tier" ) )"
done
for tier in low standard high; do
    NAMED="$NAMED$( ( with_adapter agent_complexity_model "$tier" ) )"
done
is "names no model for any seat or level" "" "$NAMED"
is "and no closed set to validate against" "" "$( ( with_adapter agent_models ) )"
for model in claude-opus-5-high gpt-5.2 auto; do
    PATH="$TMP/bin:$PATH" BRAID_AGENTS="cursor-agent" BRAID_AGENT="cursor-agent" \
        check "a model braid never heard of survives --model $model" \
        with_engine agent_check_model "$model"
done

# The contract arrives in the prompt, never through a hook: CLI hook support is
# partial and version-dependent, so SessionStart delivery cannot be relied on.
refute "contract is not injected" with_adapter agent_injects_contract
check "skills load natively" with_adapter agent_loads_skills
is "skill prefix" "/" "$( ( with_adapter agent_skill_prefix ) )"

# Unattended means --force (the agent's shell is denied without it, so a worker
# cannot run the verify command) and --trust (nobody answers the trust prompt in a
# detached run). Cursor documents --trust as headless-only, so it must not leak into
# the interactive command.
has "auto mode forces" "--force" "$( ( with_adapter agent_auto_mode ) )"
has "auto mode trusts" "--trust" "$( ( with_adapter agent_auto_mode ) )"

GIVEN_MODEL="a-model"
CMD="$( ( with_adapter agent_command "/tmp/wt" "$GIVEN_MODEL" "do the thing" ) )"
has "interactive runs cursor-agent" "cursor-agent" "$CMD"
has "interactive passes the model" "$GIVEN_MODEL" "$CMD"
has "interactive carries the prompt" 'do\ the\ thing' "$CMD"
hasnt "interactive is not print mode" " -p " " $CMD "
hasnt "interactive omits headless-only trust" "--trust" "$CMD"
hasnt "interactive makes no worktree of its own" "worktree" "$CMD"

HEADLESS="$( ( with_adapter agent_command_headless \
    "/tmp/wt" "$GIVEN_MODEL" "do the thing" ) )"
has "headless runs cursor-agent in print mode" "cursor-agent -p" "$HEADLESS"
has "headless allows its shell" "--force" "$HEADLESS"
has "headless trusts the workspace" "--trust" "$HEADLESS"
has "headless passes the model" "$GIVEN_MODEL" "$HEADLESS"
has "headless carries the prompt" 'do\ the\ thing' "$HEADLESS"
hasnt "headless makes no worktree of its own" "worktree" "$HEADLESS"

SPLIT="$( ( BRAID_CURSOR_AGENT_ARGS="--force --common-test" \
    BRAID_CURSOR_AGENT_HEADLESS_ARGS="--trust --headless-test" \
    with_adapter agent_command_headless "/tmp/wt" "$GIVEN_MODEL" "do the thing" ) )"
has "headless carries common custom flags" "--common-test" "$SPLIT"
has "headless carries headless custom flags" "--headless-test" "$SPLIT"
SPLIT_INTERACTIVE="$( ( BRAID_CURSOR_AGENT_ARGS="--force --common-test" \
    BRAID_CURSOR_AGENT_HEADLESS_ARGS="--trust --headless-test" \
    with_adapter agent_command "/tmp/wt" "$GIVEN_MODEL" "do the thing" ) )"
has "interactive carries common custom flags" "--common-test" "$SPLIT_INTERACTIVE"
hasnt "interactive omits custom headless flags" "--headless-test" "$SPLIT_INTERACTIVE"

NOMODEL="$( ( with_adapter agent_command "/tmp/wt" "" "do the thing" ) )"
hasnt "empty model omits the flag" "--model" "$NOMODEL"
NOMODEL_HEADLESS="$( ( with_adapter agent_command_headless \
    "/tmp/wt" "" "do the thing" ) )"
hasnt "empty model omits the flag headless" "--model" "$NOMODEL_HEADLESS"
has "and still prints" "cursor-agent -p" "$NOMODEL_HEADLESS"

if [[ -n "$( ( with_adapter agent_transcript_dir ) )" ]]; then
    ok "transcript dir named"
else
    bad "transcript dir named"
fi

# The probe is what `braid doctor` reports, so it has to be honest in both
# directions: flags present means usable, a renamed flag means warned.
PATH="$TMP/bin:$PATH" \
    check "probe passes when the CLI has the flags" with_adapter agent_auto_mode_probe
PATH="$TMP/bin:$PATH" CURSOR_STUB_HELP="--model" \
    refute "probe fails when a flag is renamed upstream" \
    with_adapter agent_auto_mode_probe
PATH="$TMP/bin:$PATH" BRAID_CURSOR_AGENT_HEADLESS_ARGS="--headless-test" \
    refute "probe checks headless-only flags too" with_adapter agent_auto_mode_probe
# --print is not in BRAID_CURSOR_AGENT_ARGS — it is hardcoded into the headless
# command — so it needs covering by name or a rename lands as a hung wave.
PATH="$TMP/bin:$PATH" CURSOR_STUB_HELP="--force --trust --model" \
    refute "probe fails when --print is gone" with_adapter agent_auto_mode_probe

# Wired in, not just written: the adapter's name is what resolution looks up.
PATH="$TMP/bin:$PATH" BRAID_AGENTS="cursor-agent generic" \
    check "usable with the CLI on PATH" with_agent agent_usable cursor-agent
PATH="/usr/bin:/bin" BRAID_GENERIC_CMD='' \
    refute "unusable without the CLI" with_agent agent_usable cursor-agent

# Cursor's model IDs already carry tiers, but its CLI exposes no independent effort
# control. The engine must refuse a non-empty value instead of recording one and letting
# this adapter silently discard the fourth command argument.
OUT=$(PATH="$TMP/bin:$PATH" BRAID_AGENTS="cursor-agent" BRAID_AGENT="cursor-agent" \
    with_engine agent_check_effort high 2>&1)
has "cursor-agent refuses unsupported reasoning effort" \
    "cursor-agent does not support reasoning effort" "$OUT"
PATH="$TMP/bin:$PATH" BRAID_AGENTS="cursor-agent" BRAID_AGENT="cursor-agent" \
    check "cursor-agent accepts an unset effort" with_engine agent_check_effort ""

# --- what an adapter says a tier costs ----------------------------------------

# Effort mirrors the model tiers this repository already ships: the seats that decide
# things think hard because they run briefly and a bad judgement there costs a wave, and
# the levels vary because that is what a level is for. An adapter names them only where
# its CLI has an effort control of its own.
for name in claude codex; do
    ADAPTER="$BRAID_HOME/lib/agents/$name.sh"
    is "$name names a design effort" "high" "$( ( with_adapter agent_seat_effort design ) )"
    is "$name names an orchestrate effort" "high" \
        "$( ( with_adapter agent_seat_effort orchestrate ) )"
    is "$name names a low-complexity effort" "low" \
        "$( ( with_adapter agent_level_effort low ) )"
    is "$name names a standard-complexity effort" "medium" \
        "$( ( with_adapter agent_level_effort standard ) )"
    is "$name names a high-complexity effort" "high" \
        "$( ( with_adapter agent_level_effort high ) )"
done

# Cursor has no effort control, and generic cannot know whether the command it was given
# takes one. Naming a value for either would be braid spending money on a guess.
for name in cursor-agent generic; do
    ADAPTER="$BRAID_HOME/lib/agents/$name.sh"
    refute "$name names no effort for a seat" with_adapter declare -F agent_seat_effort
    refute "$name names no effort for a level" with_adapter declare -F agent_level_effort
done

# --- the list a repository chooses from ---------------------------------------

# BRAID_AGENTS is read best-first, so its default is an order and an order is a decision:
# it stays typed rather than derived. What a typed list does is drift, and this one is
# the only statement of which adapters a repository may pick from before it has picked.
SHIPPED=$( ( with_agent agents_shipped ) )
# shellcheck disable=SC2016  # a sed script, not an expansion
DEFAULT=$(sed -n 's/^[[:space:]]*: "\${BRAID_AGENTS:=\(.*\)}"$/\1/p' lib/settings.sh)
for name in $SHIPPED; do
    case " $DEFAULT " in
        *" $name "*) ok "the default agent list offers $name" ;;
        *) bad "the default agent list omits $name" ;;
    esac
done
for name in $DEFAULT; do
    case " $SHIPPED " in
        *" $name "*) ok "and names nothing braid does not ship ($name)" ;;
        *) bad "the default agent list names $name, which braid does not ship" ;;
    esac
done

# --- the fourth argument ------------------------------------------------------

# agent_command takes four arguments whether or not an adapter uses the fourth. One
# declaring three still runs and silently drops whatever the engine passes in the
# position it did not declare, and a dropped argument has no symptom of its own — so it
# is checked in the source, which is where the contract can be read.
for file in lib/agents/*.sh; do
    name=$(basename "$file" .sh)
    for fn in agent_command agent_command_headless; do
        grep -q "^$fn()" "$file" || continue
        # shellcheck disable=SC2016  # a literal pattern, not an expansion
        if sed -n "/^$fn()/,/^}/p" "$file" | grep -q 'effort="${4:-}"'; then
            ok "$name $fn declares the fourth argument"
        else
            bad "$name $fn declares the fourth argument"
        fi
    done
done

# --- the effort chain ---------------------------------------------------------

# Effort resolves the way a model does, or the pair braid presents as matched is not.
# An adapter may declare a default; the variable overrides it; a level that says nothing
# falls through to the work seat, which is the only place BRAID_EFFORT_WORK can mean what
# BRAID_MODEL_WORK means.
OUT=$(BRAID_AGENTS=generic BRAID_AGENT=generic BRAID_GENERIC_CMD=true BRAID_EFFORT_WORK=high \
    with_engine agent_complexity_effort standard)
is "a level with no effort falls through to BRAID_EFFORT_WORK" "high" "$OUT"

OUT=$(BRAID_AGENTS=generic BRAID_AGENT=generic BRAID_GENERIC_CMD=true BRAID_EFFORT_WORK=high \
    BRAID_EFFORT_STANDARD=low with_engine agent_complexity_effort standard)
is "and the level still wins wherever it says something" "low" "$OUT"

OUT=$(with_hook 'agent_seat_effort() { printf high; }' agent_effort design)
is "an adapter may name an effort for a seat" "high" "$OUT"

OUT=$(BRAID_EFFORT_DESIGN=low with_hook 'agent_seat_effort() { printf high; }' agent_effort design)
is "and the repository overrides it" "low" "$OUT"

OUT=$(with_hook 'agent_level_effort() { printf medium; }' agent_complexity_effort high)
is "an adapter may name an effort for a complexity level" "medium" "$OUT"

OUT=$(with_hook ':' agent_effort design)
is "an adapter that names none is not an error" "" "$OUT"

# --- what counts as the same model name ---------------------------------------

# Compared name by name, never by a pattern. Model names are full of hyphens and dots and
# neither is a word character, so a `grep -w` against `fable opus sonnet haiku` is both
# too loose and a regex: it matches a prefix, and it reads a dot in the name it was given
# as "any character".
for near in fab opus- s.nnet "opus sonnet" ""; do
    [[ -n "$near" ]] || continue
    PATH="$TMP/bin:$PATH" BRAID_AGENTS="claude" BRAID_AGENT="claude" \
        refute "a model name that is merely close is not accepted ('$near')" \
        with_engine agent_check_model "$near"
done
for exact in fable opus sonnet haiku; do
    PATH="$TMP/bin:$PATH" BRAID_AGENTS="claude" BRAID_AGENT="claude" \
        check "and the ones it names are ('$exact')" with_engine agent_check_model "$exact"
done

# --- the rule about naming a model --------------------------------------------

# An adapter may name a model only where the name is an alias that outlives the model
# behind it — Claude's `opus` and `sonnet` stay put while what runs under them changes.
# A digit is how a version announces itself, and a version is what goes stale. When a
# name that is genuinely an alias needs one, this test and lib/agents/README.md change
# together, which is the friction that decision deserves.
for file in lib/agents/*.sh; do
    name=$(basename "$file" .sh)
    ADAPTER="$BRAID_HOME/$file"
    named=""
    for seat in design orchestrate work; do
        named="$named $( ( with_adapter agent_seat_model "$seat" ) )"
    done
    for level in low standard high; do
        named="$named $( ( with_adapter agent_complexity_model "$level" ) )"
    done
    case "$named" in
        *[0-9]*) bad "$name names a model whose name carries a version:$named" ;;
        *) ok "$name names no versioned model" ;;
    esac
done

# --- a probe that asks nothing ------------------------------------------------

# A probe exists to ask the installed CLI whether the flags this adapter sets still
# exist. generic sets none — the whole command line came from the person — so it has
# nothing to ask, and saying so by absence is the contract. Returning success instead
# reports a green check for a thing nobody verified, in the one adapter whose flags
# braid has never seen.
ADAPTER="$BRAID_HOME/lib/agents/generic.sh"
refute "generic probes no unattended mode it cannot see" \
    with_adapter declare -F agent_auto_mode_probe
refute "and probes no effort control it cannot see" \
    with_adapter declare -F agent_effort_probe
check "while still naming where unattended mode lives" \
    with_adapter agent_auto_mode

# --- who decides whether an adapter can run -----------------------------------

# `generic` is available exactly when it has been given a command to run, which is the
# same question for it that "is it on PATH" is for the others — and the adapter answers
# it, so an adapter added later can answer differently without the engine learning its
# name. None of this was covered; the engine's own copy of the answer was.
BRAID_GENERIC_CMD=true \
    check "generic is usable once it has a command" with_agent agent_usable generic
BRAID_GENERIC_CMD='' \
    refute "and unusable with none" with_agent agent_usable generic
BRAID_GENERIC_CMD='no-such-binary-anywhere' \
    refute "or with one that is not installed" with_agent agent_usable generic
refute "an adapter braid does not ship is never usable" with_agent agent_usable no-such-agent

# --- where an adapter lives ---------------------------------------------------

# One function rather than the path repeated at every call site, so the override branch
# shadowing will need has one place to be added.
for name in claude codex cursor-agent generic; do
    is "agent_file finds $name" "$BRAID_HOME/lib/agents/$name.sh" \
        "$( ( with_agent agent_file "$name" ) )"
done
refute "and refuses an adapter braid does not ship" with_agent agent_file no-such-agent

# --- the project's launch hook, on both paths ---------------------------------

# braid_agent_command is documented as the way to replace the launch command wholesale,
# and the detached worker is the path most launches take. An adapter defining
# agent_command_headless must not quietly outrank it, or the override covers the seat you
# watch and not the workers you do not.

OUT=$(with_hook 'braid_agent_command() { printf PROJECT; }' \
    agent_cmd_headless /tmp/wt a-model a-prompt "")
is "a project's launch hook reaches a detached worker" "PROJECT" "$OUT"

OUT=$(with_hook 'braid_agent_command() { printf PROJECT; }' \
    agent_cmd /tmp/wt a-model a-prompt "")
is "and still reaches the seat you are watching" "PROJECT" "$OUT"

OUT=$(with_hook 'braid_agent_command() { printf PROJECT; }
braid_agent_command_headless() { printf HEADLESS; }' \
    agent_cmd_headless /tmp/wt a-model a-prompt "")
is "a headless-specific hook wins where the project wrote one" "HEADLESS" "$OUT"

OUT=$(with_hook ':' agent_cmd_headless /tmp/wt a-model a-prompt "")
has "and with no hook the adapter's headless form still runs" "cursor-agent" "$OUT"

# --- the worker's model chain -------------------------------------------------

# The reference calls BRAID_MODEL_WORK "a worker's model when nothing else says", which
# makes it the last link in the complexity chain rather than a rival to it. It matters
# for an adapter that maps no models — Codex is one — where every level otherwise
# resolves to nothing and a repository has to set three variables to say one thing.
OUT=$(BRAID_AGENTS=generic BRAID_AGENT=generic BRAID_GENERIC_CMD=true BRAID_MODEL_WORK=zebra \
    with_engine agent_complexity standard)
is "a level that maps nothing falls through to BRAID_MODEL_WORK" "zebra" "$OUT"

OUT=$(BRAID_AGENTS=generic BRAID_AGENT=generic BRAID_GENERIC_CMD=true BRAID_MODEL_WORK=zebra \
    BRAID_MODEL_STANDARD=quagga with_engine agent_complexity standard)
is "and the level still wins wherever it says something" "quagga" "$OUT"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
