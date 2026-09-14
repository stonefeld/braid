#!/usr/bin/env bash
# Teach braid about this repository.
#
#   braid setup                  scaffold, then open an agent session to learn the repo
#   braid setup --scaffold       the deterministic half only, no agent, no questions
#   braid setup --costs          reconfigure agent, model and effort without a session
#   braid setup --add-agent NAME add an agent to the ones this repository supports
#
#     --agents LIST  which agents this repository supports, best first
#     --model NAME   which model runs the session   (default: the `design` tier)
#     --effort LEVEL reasoning effort for the session
#     --agent NAME   which agent runs it            (default: this repository's first)
#     --preset NAME  node, python or minimal
#     --yes          do not ask before opening the session
#
# Two halves, deliberately separated. The scaffolding — hooks registered, .gitignore,
# a braid.sh from the right preset — is mechanical and asks nothing. Learning what this
# repository *is* is a conversation: the right answer to "what is your verify command"
# comes from reading the Makefile and the CI, and you need to be able to say "not that
# one, it takes forty minutes."
#
# That is also why the agent is not invoked from `curl | sh`. A pipe that calls a model
# is a pipe nobody should run, and the installer has to work on a machine with no agent
# installed at all.

set -uo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"

SCAFFOLD_ONLY=0
COSTS=0
ADD_AGENT=""
AGENTS_ARG=""
PRESET=""
MODEL=""
EFFORT=""
ASSUME_YES=0
AGENT_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scaffold)
            SCAFFOLD_ONLY=1
            shift
            ;;
        --costs)
            COSTS=1
            shift
            ;;
        --add-agent)
            ADD_AGENT="${2:?--add-agent needs a name}"
            shift 2
            ;;
        --agents)
            AGENTS_ARG="${2:?--agents needs a list, best first}"
            shift 2
            ;;
        --preset)
            PRESET="${2:?--preset needs node, python or minimal}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        --effort)
            EFFORT="${2:?--effort needs a level}"
            shift 2
            ;;
        -y | --yes)
            ASSUME_YES=1
            shift
            ;;
        --agent)
            # Read back by agent_resolve through indirect expansion of the seat name.
            AGENT_ARG="${2:?--agent needs a name}"
            export BRAID_AGENT_DESIGN="$AGENT_ARG"
            shift 2
            ;;
        -h | --help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Whether the list came from outside this repository. braid_config exports BRAID_AGENTS
# whatever its source, so the only moment this is answerable is before it runs — and it
# has to be answerable, because an answer to "which agents does this repository use"
# must not overrule somebody who exported BRAID_AGENTS for this one command.
BRAID_AGENTS_ENV="${BRAID_AGENTS:-}"

braid_config
# A worker implements one slice and never configures the repository. Committing braid.sh
# from inside a worktree that is about to be rebased and reaped is the one case here with
# no good reading.
refuse_worker_seat

# The worktree you are standing in, not the primary checkout. Everything setup writes —
# braid.sh, .gitignore, .claude/settings.json — is committed and reviewed, so it belongs
# on the branch you are on, where you can commit it and open a pull request for it.
#
# The old behaviour was not "write to the trunk", which would at least be a rule: it was
# "write to whatever branch the primary checkout happens to be standing on", and with a
# worktree per feature that checkout is just another worktree nobody is coordinating. It
# also disagreed with where braid_config *reads* braid.sh from, which is the branch you
# are on — so setup could leave you configured and doctor could still say you were not.
#
# Wanting the configuration on the trunk is a perfectly good workflow. It is spelled
# "stand on the trunk and run this", and braid no longer decides it for you.
CHECKOUT=$(current_worktree)
cd "$CHECKOUT" || die "cannot enter $CHECKOUT"

# --- which agents this repository supports --------------------------------------

# What braid.sh itself says, as against what this process resolved: the environment and
# ~/.config/braid/config both outrank the file, so $BRAID_AGENTS is the wrong thing to
# append to when the thing being edited is the file.
agents_listed() {
    [[ -f braid.sh ]] || return 0
    python3 - <<'PY'
import pathlib
import re

text = pathlib.Path("braid.sh").read_text(encoding="utf-8")
match = re.search(r'(?m)^: "\$\{BRAID_AGENTS:=([^}]*)\}"', text)
print(" ".join(match.group(1).split()) if match else "")
PY
}

# Set one `: "${VAR:=value}"` in braid.sh — rewritten where the line exists, appended
# where it does not. Always the `:=` form, which is what lets the environment win for a
# single command without editing a committed file.
#
# A third argument is a heading for whatever is being appended, written once. Every other
# line in this file explains itself; a block of assignments arriving at the end with
# nothing over them reads like something that fell in.
braid_sh_set() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import pathlib
import re
import sys

name, value, heading = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path("braid.sh")
text = path.read_text(encoding="utf-8")
pattern = re.compile(r'(?m)^(: "\$\{%s:=)([^}]*)(\}")' % re.escape(name))
if pattern.search(text):
    # A literal replacement, never a template: re.sub reads \g and \1 in a replacement
    # string, and everything being written here came from somebody typing it.
    text = pattern.sub(lambda m: m.group(1) + value + m.group(3), text, count=1)
else:
    lines = text.rstrip("\n").split("\n")
    block = ""
    if heading and heading not in text:
        block = "\n\n# " + heading + "\n"
    elif lines and lines[-1].startswith(': "${BRAID_'):
        # Several of these are appended in a row, and a blank line between each turns
        # one decision into a scattered list.
        block = "\n"
    else:
        block = "\n\n"
    text = "\n".join(lines) + block + ': "${%s:=%s}"' % (name, value) + "\n"
path.write_text(text, encoding="utf-8")
PY
}

# Order is the decision — BRAID_AGENTS is read best-first — so duplicates are dropped
# rather than sorted away.
agents_write() {
    local name seen="" ordered=""
    for name in $1; do
        case " $seen " in *" $name "*) continue ;; esac
        seen="$seen $name"
        ordered="$ordered $name"
    done
    braid_sh_set BRAID_AGENTS "${ordered# }"
}

# Asked once, at the moment braid.sh is created, and never again — the list is a
# decision about a repository, and a decision made once is not a question to re-ask on
# every run. What this machine has is shown as evidence and never written on its own:
# detecting PATH and committing the winner is how one laptop configures a team.
#
# It belongs here rather than in the session below, because the session is itself
# launched by one of these agents. A repository whose people run Codex used to be
# scaffolded `BRAID_AGENTS=claude` and then handed a Claude session to be told about
# it — the wrong agent, asking the wrong question, after the answer was already written.
agents_ask() {
    local installed shipped answer name reply=""
    installed=$(agents_installed || true)
    shipped=$(agents_shipped)

    echo >&2
    note "which agents will this repository use?"
    if [[ -n "$installed" ]]; then
        info "installed here:  $installed"
    else
        meh "none of braid's agents are on your PATH"
    fi
    info "braid has an adapter for:  $shipped"
    info "'generic' is any CLI at all, through BRAID_AGENT_CMD — see braid doctor"
    info "a decision, not a detection: a coworker's agent belongs here too"

    while :; do
        printf '\n  best first, space separated%s: ' "${installed:+ [$installed]}" >&2
        read -r answer || answer=""
        [[ -z "$answer" ]] && answer="$installed"
        [[ -z "$answer" ]] && {
            warn "nothing chosen — braid.sh keeps the $PRESET preset's list"
            return 1
        }
        reply=""
        for name in $answer; do
            if [[ ! -f "$BRAID_HOME/lib/agents/$name.sh" ]]; then
                warn "no adapter for '$name' — braid has: $shipped"
                reply=""
                break
            fi
            reply="$reply $name"
        done
        [[ -n "$reply" ]] && break
    done

    # Named but not installed is allowed and worth saying out loud. It is the normal
    # case for a team — the list is what this repository supports, not what this desk
    # can run — but it is also exactly what a typo looks like.
    for name in $reply; do
        agent_usable "$name" ||
            meh "$name is not installed here; braid will skip it until it is"
    done

    printf '%s' "${reply# }"
}

# --- which agent, model and effort runs each seat -------------------------------

# What a seat resolves to right now: "<agent> <model>", or nothing when no agent in the
# repository's list is installed here. Loaded in a subshell, because agent_load sources
# an adapter into the shell that calls it and there are several of these.
seat_now() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 1
        printf '%s %s' "$BRAID_AGENT_RESOLVED" "$(agent_model "$1")"
    ) 2>/dev/null
}

# The same for a complexity level, which has no agent of its own: a slice says how much
# judgement the work needs and the agent on the `work` seat says what that is here.
level_now() {
    (
        agent_load work 2>/dev/null || exit 1
        agent_complexity "${1:?level}"
    ) 2>/dev/null
}

seat_effort_now() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 1
        if [[ "$1" == work ]]; then
            agent_complexity_effort standard
        else
            agent_effort "$1"
        fi
    ) 2>/dev/null
}

level_effort_now() {
    (
        agent_load work 2>/dev/null || exit 1
        agent_complexity_effort "${1:?level}"
    ) 2>/dev/null
}

# Refused the way the seat itself would refuse it, but without taking setup down with
# it: agent_check_model dies, which is right when a wave is about to start and wrong
# when somebody is typing an answer and can simply be asked again.
model_ok() {
    (
        agent_load "${1:?seat}" 2>/dev/null || exit 0
        agent_check_model "$2"
    ) >/dev/null 2>&1
}

# How an empty model or effort reads. It is not missing: it means the CLI picks, which is
# the right answer for defaults that can change faster than a committed file can.
shown() { printf '%s' "${1:-(the CLI chooses)}"; }

# One answer, with the current value as the default and empty meaning "keep it".
ask_value() {
    local label="${1:?label}" current="${2:-}" answer
    printf '  %-22s [%s]: ' "$label" "$(shown "$current")" >&2
    read -r answer || answer=""
    printf '%s' "$answer"
}

# Ask for one model, refuse what the seat's agent would refuse, and report the
# assignment rather than performing it. It runs inside a command substitution, so it
# cannot write anything the caller would see — which is the whole reason the answers are
# collected first and applied once, together.
ask_model() {
    local seat="${1:?seat}" label="${2:?label}" current="${3:-}" tier="${4:-$1}" model
    while :; do
        model=$(ask_value "$label" "$current")
        [[ -n "$model" ]] || return 0
        if model_ok "$seat" "$model"; then
            printf '%s %s' "$(seat_var MODEL "$tier")" "$model"
            return 0
        fi
        warn "that is not a model $(seat_now "$seat" | cut -d' ' -f1) accepts"
    done
}

ask_effort() {
    local tier="${1:?tier}" label="${2:?label}" current="${3:-}" seat="${4:?seat}" effort
    while :; do
        effort=$(ask_value "$label" "$current")
        [[ -n "$effort" ]] || return 0
        if (
            agent_load "$seat" 2>/dev/null || exit 1
            agent_check_effort "$effort"
        ) >/dev/null 2>&1; then
            printf '%s %s' "$(seat_var EFFORT "$tier")" "$effort"
            return 0
        fi
        warn "'$effort' is not a supported effort for $(seat_now "$seat" | cut -d' ' -f1)"
    done
}

# The table, then one question about the whole of it.
#
# This is the largest lever there is on what a wave costs, and every value in it is a
# default from an adapter — a guess about somebody else's budget. It is also the only
# moment anybody is looking: after this, the table is something you have to know to go
# and ask `braid doctor` for.
#
# Asked here rather than in the session below for the same reason the agent list is: the
# session is opened by the design seat, so its model is already spent by the time an
# agent could ask you about it.
seats_ask() {
    local seat level agent model effort answer row writes="" agents=0

    for seat in $BRAID_AGENTS; do
        agents=$((agents + 1))
    done

    echo >&2
    note "which agent, model and reasoning effort runs each seat?"
    for seat in design orchestrate work; do
        row=$(seat_now "$seat")
        [[ -n "$row" ]] || {
            meh "no agent resolves for the $seat seat — nothing to ask about yet"
            return 1
        }
        effort=$(seat_effort_now "$seat")
        info "$(printf '%-13s %-9s %-24s effort: %s' "$seat" "${row%% *}" \
            "$(shown "${row#* }")" "$(shown "$effort")")"
    done
    echo >&2
    note "and what a slice's complexity means, on the work seat?"
    for level in low standard high; do
        info "$(printf '%-13s %-9s %-24s effort: %s' "$level" "" \
            "$(shown "$(level_now "$level")")" "$(shown "$(level_effort_now "$level")")")"
    done
    echo >&2
    info "the table resolves repository overrides first, then the adapter or CLI default."
    info "it is the biggest lever there is on what a wave costs."

    printf '\n  change any of it? [y/N] ' >&2
    read -r answer || answer=""
    case "$answer" in
        [yY]*) ;;
        *) return 0 ;;
    esac
    echo >&2

    for seat in design orchestrate work; do
        row=$(seat_now "$seat")
        # Only where there is a choice to make. A repository that supports one agent
        # answered this one question ago.
        if [[ "$agents" -gt 1 ]]; then
            agent=$(ask_value "$seat agent" "${row%% *}")
            if [[ -n "$agent" ]]; then
                if agent_supported "$agent" && agent_usable "$agent"; then
                    # Written and exported at once: the seats below resolve against it,
                    # and so does the session this command opens when it is done.
                    braid_sh_set "$(seat_var AGENT "$seat")" "$agent" \
                        "Which agent takes which seat. Only the seats pinned here; the rest fall to BRAID_AGENTS, in order."
                    export "$(seat_var AGENT "$seat")=$agent"
                    row=$(seat_now "$seat")
                elif agent_supported "$agent"; then
                    warn "'$agent' is not installed here — left alone"
                else
                    warn "'$agent' is not in this repository's list ($BRAID_AGENTS) — left alone"
                fi
            fi
        fi
        answer=$(ask_model "$seat" "$seat model" "${row#* }")
        [[ -z "$answer" ]] || writes="$writes$answer
"
        if [[ "$seat" != work ]]; then
            answer=$(ask_effort "$seat" "$seat effort" "$(seat_effort_now "$seat")" "$seat")
            [[ -z "$answer" ]] || writes="$writes$answer
"
        fi
    done

    for level in low standard high; do
        answer=$(ask_model work "complexity: $level" "$(level_now "$level")" "$level")
        [[ -z "$answer" ]] || writes="$writes$answer
"
        answer=$(ask_effort "$level" "$level effort" "$(level_effort_now "$level")" work)
        [[ -z "$answer" ]] || writes="$writes$answer
"
    done

    [[ -n "$writes" ]] || {
        note "nothing changed — every row keeps its current value"
        return 0
    }

    # Written together, under a heading, rather than one line at a time as they were
    # answered. Assignments scattered down a file nobody reads twice are several things
    # to find later; a block with a sentence over it is one.
    # A here-string, not a pipe: a pipe puts the loop in a subshell and the exports
    # below would be lost with it — and the design seat's model has to reach the session
    # this command opens in a moment, which braid_config read braid.sh too early to see.
    while read -r var value; do
        [[ -n "$var" ]] || continue
        braid_sh_set "$var" "$value" \
            "What each seat and each complexity level costs. braid doctor resolves the whole table."
        export "$var=$value"
    done <<<"$writes"
    ok "braid.sh records what you changed; the rest keeps its current resolution"
}

# Existing repositories opt into the new table explicitly. An absent effort value means
# the CLI chooses, so upgrading the engine alone cannot change their spend or behaviour.
# This mode does only this job: no scaffolding and no setup agent session afterwards.
if [[ "$COSTS" -eq 1 ]]; then
    [[ "$SCAFFOLD_ONLY" -eq 0 && -z "$ADD_AGENT" && -z "$AGENTS_ARG" &&
        -z "$PRESET" && -z "$MODEL" && -z "$EFFORT" && -z "$AGENT_ARG" &&
        "$ASSUME_YES" -eq 0 ]] ||
        die "--costs cannot be combined with other setup options"
    [[ -f braid.sh ]] || die "no braid.sh yet — run braid setup first"
    [[ -t 0 ]] || die "--costs needs an interactive terminal"
    seats_ask || exit 1
    exit 0
fi

# --- --add-agent --------------------------------------------------------------

if [[ -n "$ADD_AGENT" ]]; then
    [[ -f "$BRAID_HOME/lib/agents/$ADD_AGENT.sh" ]] ||
        die "no adapter for '$ADD_AGENT' (have: $(agents_shipped))"
    [[ -f braid.sh ]] || die "no braid.sh yet — run braid setup first"
    # What the file says, or — when it says nothing — what this repository effectively
    # supports today. The old code appended to a hardcoded "claude", which quietly
    # narrowed a repository that had never narrowed itself.
    BRAID_AGENTS_LISTED=$(agents_listed)
    [[ -n "$BRAID_AGENTS_LISTED" ]] || BRAID_AGENTS_LISTED="$BRAID_AGENTS"
    for listed in $BRAID_AGENTS_LISTED; do
        [[ "$listed" == "$ADD_AGENT" ]] || continue
        note "braid.sh already lists $ADD_AGENT"
        exit 0
    done
    agents_write "$BRAID_AGENTS_LISTED $ADD_AGENT"
    note "braid.sh now supports $ADD_AGENT"
    warn "commit this — it is a decision about the repository, not about your machine"
    exit 0
fi

# --- the deterministic half ---------------------------------------------------

# Said before anything is written, and it names the branch as well as the directory:
# everything below this line is committed, and which branch it lands on is the thing
# worth being sure about.
note "scaffolding $CHECKOUT on '$(current_branch)'"

if [[ -z "$PRESET" ]]; then
    if [[ -f package.json ]]; then
        PRESET=node
    elif [[ -f pyproject.toml || -f requirements.txt ]]; then
        PRESET=python
    else
        PRESET=minimal
    fi
fi

FRESH=0
if [[ -f braid.sh ]]; then
    ok "braid.sh kept (--preset to start over from a template)"
else
    cp "$BRAID_HOME/lib/templates/braid.$PRESET.sh" braid.sh ||
        die "no preset '$PRESET' (expected: node, python, minimal)"
    ok "braid.sh from the $PRESET preset"
    FRESH=1
fi

# Told, asked, or left alone — in that order. Left alone covers a re-run (the answer is
# already committed) and a run with nobody in front of it: a prompt nobody can see is
# worse than the default it was guarding, and this command runs in CI.
CHOSEN=""
if [[ -n "$AGENTS_ARG" ]]; then
    for name in $AGENTS_ARG; do
        [[ -f "$BRAID_HOME/lib/agents/$name.sh" ]] ||
            die "no adapter for '$name' (have: $(agents_shipped))"
    done
    CHOSEN="$AGENTS_ARG"
elif [[ "$FRESH" -eq 1 && "$SCAFFOLD_ONLY" -eq 0 && "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    CHOSEN=$(agents_ask) || CHOSEN=""
fi

if [[ -n "$CHOSEN" ]]; then
    agents_write "$CHOSEN"
    ok "braid.sh supports: $CHOSEN"
    # The session below is opened by the first of these, so the answer has to reach this
    # process and not only the file. The environment still outranks it — somebody who
    # exported BRAID_AGENTS said something about *this run*, and answering a question
    # about the repository does not overrule that.
    [[ -n "${BRAID_AGENTS_ENV:-}" ]] || export BRAID_AGENTS="$CHOSEN"
fi

# Whatever route got here — asked, told, or a braid.sh somebody else committed — this is
# the last moment before a session is opened, and "the list in the file names nothing
# this machine can run" is a thing to hear now rather than as a resolution failure. Not
# said when the environment set the list, where disagreeing with the file is the point.
if [[ -z "${BRAID_AGENTS_ENV:-}" ]]; then
    LISTED=$(agents_listed)
    for name in $LISTED; do
        agent_usable "$name" && LISTED="" && break
    done
    [[ -z "$LISTED" ]] || warn "$(printf '%s\n' \
        "braid.sh supports '$LISTED', and none of those is installed here." \
        "  installed:  $(agents_installed || echo none)" \
        "  braid setup --agents '<best first>'    say what this repository uses")"
fi

# Which model and effort each seat and each complexity level gets. Under the same
# conditions as the question above, and immediately after it, because it is the same
# conversation: you have just said which agents run here, and this is what they cost.
if [[ "$FRESH" -eq 1 && "$SCAFFOLD_ONLY" -eq 0 && "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    seats_ask || true
fi

mkdir -p "$BRAID_FEATURES_DIR"
# No placeholder file. The directory is empty only between now and the first slice, and
# nothing depends on it existing in the meantime: plan and next both say what to do when
# it is missing. A README here would be braid's own documentation copied into somebody
# else's repository, where it would drift.
ok "$BRAID_FEATURES_DIR/"

# `.braid/` is where everything braid and its agents write is supposed to go. The glob
# beside it is for when an agent writes beside the checkout anyway — which is what
# happened for a whole feature before the seats had a .braid/ of their own, and `.braid/`
# does not match `.braid-verify-<slug>.log`.
for pattern in '.braid/' '.braid-*.log' '.env'; do
    touch .gitignore
    grep -qxF "$pattern" .gitignore || {
        printf '%s\n' "$pattern" >>.gitignore
        ok ".gitignore + $pattern"
    }
done

# Claude Code's hooks, registered whatever the workers run: they fire in any Claude Code
# session here, which is usually the orchestrator's seat — the one that can actually
# push and open pull requests. Registered by name, never by path, which is what lets the
# engine live outside this repository.
mkdir -p .claude
# Checked directly rather than through $?: the registration refuses to touch a
# settings.json it cannot parse, and setup used to report success over that refusal.
if ! python3 "$BRAID_HOME/lib/setup/hooks.py"; then
    die "could not register the hooks — nothing was changed"
fi

echo
if [[ "$SCAFFOLD_ONLY" -eq 1 ]]; then
    note "scaffolded. braid.sh still has to be filled in — run braid setup without --scaffold"
    exit 0
fi

# --- the half that needs judgement --------------------------------------------

agent_load design || exit 1
MODEL="${MODEL:-$(agent_model design)}"
agent_check_model "$MODEL"
EFFORT="${EFFORT:-$(agent_effort design)}"
agent_check_effort "$EFFORT"

# Said before the session opens, and it names the escape hatch. This is the one command
# a person runs before they know anything about braid, so "it opened an expensive model
# and nobody told me I could change it" is a real way to lose someone — and the tier is a
# default from the adapter, which is a guess about somebody else's budget.
# Asked, not announced. Everything above scrolls past the instant the agent takes the
# terminal, so a line saying which model is about to run is a line nobody reads until
# they are already in the session and it is already running. A prompt is the only form
# of this that arrives before the thing it describes.
note "about to open a session to learn about this repository:"
info "agent:  $BRAID_AGENT_RESOLVED${MODEL:+  model: $MODEL   (the tier this repository calls 'design')}${EFFORT:+  effort: $EFFORT}"
info "it will ask a handful of questions and write braid.sh and docs/agents/"
info "another:  braid setup --model <name>  |  --effort <level>  |  --agent <name>"
info "the whole table: braid doctor  |  change it: braid setup --costs"

# Only where somebody is there to answer. Piped, or run from a script, it proceeds:
# blocking on a prompt nobody can see is worse than the thing the prompt guards against.
if [[ "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    printf '\n  open it? [Y/n] ' >&2
    read -r ANSWER || ANSWER=""
    case "$ANSWER" in
        [nN]*)
            echo >&2
            note "nothing opened. the scaffolding above is done and committable."
            note "when you want the rest:  braid setup${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}"
            exit 0
            ;;
    esac
fi
echo

PROMPT="$(
    cat "$BRAID_HOME/lib/setup/SETUP.md"
    printf '\n\n---\n\nThe scaffolding is already done: braid.sh exists from the %s preset, the hooks are registered, and %s/ was created. Start at section 1.\n' \
        "$PRESET" "$BRAID_FEATURES_DIR"
)"

# In this terminal, not a panel. You are sitting here, and this is a conversation.
eval "$(agent_cmd "$CHECKOUT" "$MODEL" "$PROMPT" "$EFFORT")"
