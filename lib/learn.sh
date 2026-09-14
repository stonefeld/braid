#!/usr/bin/env bash
# Open the session that works out what this repository is.
#
#   braid learn
#
#     --model NAME    which model runs it   (default: the `design` tier)
#     --effort LEVEL  reasoning effort for it
#     --agent NAME    which agent runs it   (default: this repository's first)
#     --yes           do not ask before opening it
#
# The half of setting braid up that cannot be mechanical. The right answer to "what is
# your verify command" comes from reading the Makefile and the CI, and you need to be
# able to say "not that one, it takes forty minutes" — so it is a conversation, held by
# an agent that can read the repository, and it writes the four functions in braid.sh
# and this project's rules for workers.
#
# Run it again whenever the repository changes underneath what it wrote. That is the
# whole reason it has a name of its own: `braid init` scaffolds once, and how this
# project builds and tests itself moves for as long as the project does.
#
# It is not invoked from `curl | sh`. A pipe that calls a model is a pipe nobody should
# run, and the installer has to work on a machine with no agent installed at all.

set -uo pipefail

# shellcheck source=agent.sh
source "$BRAID_HOME/lib/agent.sh"

MODEL=""
EFFORT=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="${2:?--model needs a name}"
            shift 2
            ;;
        --effort)
            EFFORT="${2:?--effort needs a level}"
            shift 2
            ;;
        --agent)
            # Read back by agent_resolve through indirect expansion of the seat name.
            export BRAID_AGENT_DESIGN="${2:?--agent needs a name}"
            shift 2
            ;;
        -y | --yes)
            ASSUME_YES=1
            shift
            ;;
        -h | --help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

braid_config
# A worker implements one slice and never configures the repository.
refuse_worker_seat

CHECKOUT=$(current_worktree)
cd "$CHECKOUT" || die "cannot enter $CHECKOUT"

[[ -f "$_BRAID_PROJECT_FILE" ]] ||
    die "no braid.sh on '$(current_branch)' — braid init writes one"

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
info "another:  braid learn --model <name>  |  --effort <level>  |  --agent <name>"
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
            note "when you want it:  braid learn${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}"
            exit 0
            ;;
    esac
fi
echo

PROMPT="$(
    cat "$BRAID_HOME/lib/learn.md"
    printf '\n\n---\n\nThe scaffolding is done: braid.sh exists, the hooks are registered where they belong, and %s/ was created if this repository keeps slices in files. Read the repository to work out what it is — nothing scaffolded names a stack. Start at section 1.\n' \
        "$BRAID_FEATURES_DIR"
)"

# In this terminal, not a panel. You are sitting here, and this is a conversation.
eval "$(agent_cmd "$CHECKOUT" "$MODEL" "$PROMPT" "$EFFORT")"
