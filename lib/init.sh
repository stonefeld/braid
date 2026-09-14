#!/usr/bin/env bash
# Scaffold this repository, then hand over to `braid learn`.
#
#   braid init
#   braid init --no-learn        the scaffolding only, and stop
#
#     --agents LIST  which agents this repository supports, best first
#     --yes          take the answers it can and ask nothing
#
# Everything here is mechanical: a braid.sh, the directories this repository's answers
# call for, and the hooks of whichever agents it named. It asks what it cannot work out
# and refuses to detect what it must not decide — which agents a team supports is not a
# fact about whose binary happens to be on this PATH.
#
# Re-running it reconciles: it makes what the configuration now calls for, and says
# nothing about what already matches. So adding an agent in six months is `braid config
# set BRAID_AGENTS …` and then this, which is the same pair as the first day.
#
# Working out what this repository *is* — what its gate runs, what a worker needs before
# its first turn — is `braid learn`, because that is a conversation rather than a
# procedure.

set -uo pipefail

# shellcheck source=seats.sh
source "$BRAID_HOME/lib/seats.sh"

NO_LEARN=0
AGENTS_ARG=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-learn)
            NO_LEARN=1
            shift
            ;;
        --agents)
            AGENTS_ARG="${2:?--agents needs a list, best first}"
            shift 2
            ;;
        -y | --yes)
            ASSUME_YES=1
            shift
            ;;
        -h | --help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2
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
elif [[ "$FRESH" -eq 1 && "$NO_LEARN" -eq 0 && "$ASSUME_YES" -eq 0 && -t 0 ]]; then
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
        "  braid init --agents '<best first>'     say what this repository uses")"
fi

# Which model and effort each seat and each complexity level gets. Under the same
# conditions as the question above, and immediately after it, because it is the same
# conversation: you have just said which agents run here, and this is what they cost.
if [[ "$FRESH" -eq 1 && "$NO_LEARN" -eq 0 && "$ASSUME_YES" -eq 0 && -t 0 ]]; then
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
if ! python3 "$BRAID_HOME/lib/hooks/register.py"; then
    die "could not register the hooks — nothing was changed"
fi

echo
if [[ "$NO_LEARN" -eq 1 ]]; then
    note "scaffolded. what this repository is has not been worked out yet — braid learn"
    exit 0
fi

# Handed over rather than reimplemented, so that the first run is one command and the
# second is the one that has a name.
if [[ "$ASSUME_YES" -eq 1 ]]; then
    exec bash "$BRAID_HOME/lib/learn.sh" --yes
fi
exec bash "$BRAID_HOME/lib/learn.sh"

