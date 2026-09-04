#!/usr/bin/env bash
# Teach braid about this repository.
#
#   braid setup                  scaffold, then open an agent session to learn the repo
#   braid setup --scaffold       the deterministic half only, no agent, no questions
#   braid setup --add-agent NAME add an agent to the ones this repository supports
#
#     --model NAME   which model runs the session   (default: the `design` tier)
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
ADD_AGENT=""
PRESET=""
MODEL=""
ASSUME_YES=0

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
        --preset)
            PRESET="${2:?--preset needs node, python or minimal}"
            shift 2
            ;;
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        -y | --yes)
            ASSUME_YES=1
            shift
            ;;
        --agent)
            # Read back by agent_resolve through indirect expansion of the seat name.
            export BRAID_AGENT_DESIGN="${2:?--agent needs a name}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

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

# --- --add-agent --------------------------------------------------------------

if [[ -n "$ADD_AGENT" ]]; then
    [[ -f "$BRAID_HOME/lib/agents/$ADD_AGENT.sh" ]] ||
        die "no adapter for '$ADD_AGENT' (have: $(cd "$BRAID_HOME/lib/agents" && printf '%s ' *.sh | sed 's/\.sh//g'))"
    [[ -f braid.sh ]] || die "no braid.sh yet — run braid setup first"
    if grep -q "BRAID_AGENTS.*\b$ADD_AGENT\b" braid.sh; then
        note "braid.sh already lists $ADD_AGENT"
        exit 0
    fi
    python3 - "$ADD_AGENT" <<'PY'
import pathlib
import re
import sys

name = sys.argv[1]
path = pathlib.Path("braid.sh")
text = path.read_text(encoding="utf-8")
pattern = re.compile(r'(: "\$\{BRAID_AGENTS:=)([^}]*)(\}")')
match = pattern.search(text)
if match:
    path.write_text(pattern.sub(rf"\g<1>\g<2> {name}\g<3>", text, count=1), encoding="utf-8")
else:
    text += f'\n: "${{BRAID_AGENTS:=claude {name}}}"\n'
    path.write_text(text, encoding="utf-8")
print(f"braid.sh now supports {name}")
PY
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

if [[ -f braid.sh ]]; then
    ok "braid.sh kept (--preset to start over from a template)"
else
    cp "$BRAID_HOME/lib/templates/braid.$PRESET.sh" braid.sh ||
        die "no preset '$PRESET' (expected: node, python, minimal)"
    ok "braid.sh from the $PRESET preset"
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

# Said before the session opens, and it names the escape hatch. This is the one command
# a person runs before they know anything about braid, so "it opened an expensive model
# and nobody told me I could change it" is a real way to lose someone — and the tier is a
# default from the adapter, which is a guess about somebody else's budget.
# Asked, not announced. Everything above scrolls past the instant the agent takes the
# terminal, so a line saying which model is about to run is a line nobody reads until
# they are already in the session and it is already running. A prompt is the only form
# of this that arrives before the thing it describes.
note "about to open a session to learn about this repository:"
info "agent:  $BRAID_AGENT_RESOLVED${MODEL:+  model: $MODEL   (the tier this repository calls 'design')}"
info "it will ask a handful of questions and write braid.sh and docs/agents/"
info "another:  braid setup --model <name>  |  --agent <name>   —  the whole table: braid doctor"

# Only where somebody is there to answer. Piped, or run from a script, it proceeds:
# blocking on a prompt nobody can see is worse than the thing the prompt guards against.
if [[ "$ASSUME_YES" -eq 0 && -t 0 ]]; then
    printf '\n  open it? [Y/n] ' >&2
    read -r ANSWER || ANSWER=""
    case "$ANSWER" in
        [nN]*)
            echo >&2
            note "nothing opened. the scaffolding above is done and committable."
            note "when you want the rest:  braid setup${MODEL:+ --model $MODEL}"
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
eval "$(agent_cmd "$CHECKOUT" "$MODEL" "$PROMPT")"
