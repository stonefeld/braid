#!/usr/bin/env bash
# Teach braid about this repository.
#
#   braid setup                  scaffold, then open an agent session to learn the repo
#   braid setup --scaffold       the deterministic half only, no agent, no questions
#   braid setup --add-agent NAME add an agent to the ones this repository supports
#
#     --agents LIST  which agents this repository supports, best first
#     --model NAME   which model runs the session   (default: the `design` tier)
#     --effort LEVEL reasoning effort for the session
#     --agent NAME   which agent runs it            (default: this repository's first)
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

# shellcheck source=seats.sh
source "$BRAID_HOME/lib/seats.sh"

SCAFFOLD_ONLY=0
ADD_AGENT=""
AGENTS_ARG=""
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
        --add-agent)
            ADD_AGENT="${2:?--add-agent needs a name}"
            shift 2
            ;;
        --agents)
            AGENTS_ARG="${2:?--agents needs a list, best first}"
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
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Whether the list came from outside this repository. braid_config exports BRAID_AGENTS
# whatever its source, so the only moment this is answerable is before it runs — and it
# has to be answerable, because an answer to "which agents does this repository use"
# must not overrule somebody who exported BRAID_AGENTS for this one command.
_BRAID_AGENTS_ENV="${BRAID_AGENTS:-}"

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
    info "'generic' is any CLI at all, through BRAID_GENERIC_CMD — see braid doctor"
    info "a decision, not a detection: a coworker's agent belongs here too"

    while :; do
        printf '\n  best first, space separated%s: ' "${installed:+ [$installed]}" >&2
        read -r answer || answer=""
        [[ -z "$answer" ]] && answer="$installed"
        [[ -z "$answer" ]] && {
            warn "nothing chosen — braid.sh decides no agents, and braid accepts any adapter it has"
            return 1
        }
        reply=""
        for name in $answer; do
            if ! agent_file "$name" >/dev/null; then
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

# --- --add-agent --------------------------------------------------------------

if [[ -n "$ADD_AGENT" ]]; then
    agent_file "$ADD_AGENT" >/dev/null ||
        die "no adapter for '$ADD_AGENT' (have: $(agents_shipped))"
    [[ -f braid.sh ]] || die "no braid.sh yet — run braid setup first"
    # What the file says, or — when it says nothing — what this repository effectively
    # supports today. The old code appended to a hardcoded "claude", which quietly
    # narrowed a repository that had never narrowed itself.
    _BRAID_AGENTS_LISTED=$(agents_listed)
    [[ -n "$_BRAID_AGENTS_LISTED" ]] || _BRAID_AGENTS_LISTED="$BRAID_AGENTS"
    for listed in $_BRAID_AGENTS_LISTED; do
        [[ "$listed" == "$ADD_AGENT" ]] || continue
        note "braid.sh already lists $ADD_AGENT"
        exit 0
    done
    agents_write "$_BRAID_AGENTS_LISTED $ADD_AGENT"
    note "braid.sh now supports $ADD_AGENT"
    warn "commit this — it is a decision about the repository, not about your machine"
    exit 0
fi

# --- the deterministic half ---------------------------------------------------

# Said before anything is written, and it names the branch as well as the directory:
# everything below this line is committed, and which branch it lands on is the thing
# worth being sure about.
note "scaffolding $CHECKOUT on '$(current_branch)'"

FRESH=0
if [[ -f braid.sh ]]; then
    ok "braid.sh kept — delete it to start over from the template"
else
    cp "$BRAID_HOME/lib/templates/braid.sh" braid.sh ||
        die "no template at $BRAID_HOME/lib/templates/braid.sh — reinstall"
    ok "braid.sh written — every value braid reads, commented out"
    FRESH=1
fi

# Told, asked, or left alone — in that order. Left alone covers a re-run (the answer is
# already committed) and a run with nobody in front of it: a prompt nobody can see is
# worse than the default it was guarding, and this command runs in CI.
CHOSEN=""
if [[ -n "$AGENTS_ARG" ]]; then
    for name in $AGENTS_ARG; do
        agent_file "$name" >/dev/null ||
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
    [[ -n "${_BRAID_AGENTS_ENV:-}" ]] || export BRAID_AGENTS="$CHOSEN"
fi

# Whatever route got here — asked, told, or a braid.sh somebody else committed — this is
# the last moment before a session is opened, and "the list in the file names nothing
# this machine can run" is a thing to hear now rather than as a resolution failure. Not
# said when the environment set the list, where disagreeing with the file is the point.
if [[ -z "${_BRAID_AGENTS_ENV:-}" ]]; then
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
info "agent:  $BRAID_RUN_AGENT${MODEL:+  model: $MODEL   (the tier this repository calls 'design')}${EFFORT:+  effort: $EFFORT}"
info "it will ask a handful of questions and write braid.sh and docs/agents/"
info "another:  braid setup --model <name>  |  --effort <level>  |  --agent <name>"
info "the whole table: braid doctor  |  change it: braid config"

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
    printf '\n\n---\n\nThe scaffolding is already done: braid.sh exists with every value commented out, the hooks are registered, and %s/ was created. Read the repository to work out what it is — the template names no stack. Start at section 1.\n' \
        "$BRAID_FEATURES_DIR"
)"

# In this terminal, not a panel. You are sitting here, and this is a conversation.
eval "$(agent_cmd "$CHECKOUT" "$MODEL" "$PROMPT" "$EFFORT")"
