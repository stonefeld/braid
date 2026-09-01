#!/bin/sh
# Install braid.
#
#   curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
#   ./install.sh                              from a clone
#
#     --prefix DIR     where the dispatcher is linked   (default: ~/.local/bin)
#     --ref REF        which tag or branch to install   (default: main)
#     --no-symlink     install the engine, link nothing
#
# This half is deterministic and asks nothing: it puts the engine on the machine and
# tells you what it found. Teaching braid about a *repository* — its tracker, its test
# command, the language it writes issues in — is `braid setup`, which is a conversation
# with an agent and is deliberately not in this pipe.
#
# POSIX sh on purpose. `curl | sh` runs under /bin/sh, which is dash on Debian and
# busybox ash elsewhere; a bashism here fails on the very first thing a new user runs.

set -eu

REPO="stonefeld/braid"
REF="main"
PREFIX="${HOME}/.local/bin"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/braid"
SYMLINK=1

# --- output -------------------------------------------------------------------

# Colour only for a terminal: piped into a file or read by an agent, escape codes are
# noise. Same rule as the engine's, and it starts here.
if [ -t 2 ]; then
    R=$(printf '\033[31m') G=$(printf '\033[32m') Y=$(printf '\033[33m')
    D=$(printf '\033[2m') Z=$(printf '\033[0m')
else
    R='' G='' Y='' D='' Z=''
fi

say() { printf '%s\n' "$*" >&2; }
ok() { printf '  %sok%s    %s\n' "$G" "$Z" "$*" >&2; }
meh() { printf '  %swarn%s  %s\n' "$Y" "$Z" "$*" >&2; }
die() {
    printf '  %serror%s %s\n' "$R" "$Z" "$*" >&2
    exit 1
}

# --- arguments ----------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)
            PREFIX="${2:?--prefix needs a directory}"
            shift 2
            ;;
        --ref)
            REF="${2:?--ref needs a tag or branch}"
            shift 2
            ;;
        --no-symlink)
            SYMLINK=0
            shift
            ;;
        -h | --help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

say ""
say "braid"
say ""

# --- the machine --------------------------------------------------------------

# Refused rather than attempted. Under MSYS the failures are all silent: path
# translation against a native Windows git, no tmux so every launcher collapses to
# detached, and quoted commands crossing into npm .cmd shims. Someone watching workers
# quietly fail to commit blames braid, not their shell.
case "$(uname -s)" in
    Darwin | Linux) ;;
    MINGW* | MSYS* | CYGWIN*)
        say "  braid needs a Unix-like environment, and Git Bash is not one:"
        say "  git worktrees under MSYS path translation, no tmux, and quoted"
        say "  commands crossing into npm .cmd shims all fail quietly."
        say ""
        die "install this inside WSL2 instead"
        ;;
    *) meh "untested platform: $(uname -s) — continuing anyway" ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"
command -v bash >/dev/null 2>&1 || die "bash is required"
command -v python3 >/dev/null 2>&1 ||
    die "python3 is required (standard library only — braid never installs packages)"

# 2.20 is where `git config --worktree` arrived, which is how the push guard is
# installed per worktree without touching the human's own checkout.
git_version=$(git --version | awk '{print $3}')
git_major=$(printf '%s' "$git_version" | cut -d. -f1)
git_minor=$(printf '%s' "$git_version" | cut -d. -f2)
if [ "$git_major" -lt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -lt 20 ]; }; then
    die "git $git_version is too old — braid needs 2.20 or newer for per-worktree config"
fi

ok "git $git_version, bash, python3"

# --- the source ---------------------------------------------------------------

# Two ways in. From a clone, install what is checked out — which is what you want while
# working on braid itself. Piped from curl there is no clone, so fetch a tarball.
SOURCE=""
case "$0" in
    */*)
        candidate=$(cd "$(dirname "$0")" && pwd)
        [ -d "$candidate/lib" ] && [ -f "$candidate/bin/braid" ] && SOURCE="$candidate"
        ;;
esac

TMP=""
# Written as an `if` rather than `[ … ] && …` on purpose: an EXIT trap whose last
# command fails sets the script's exit status, so the short-circuit form made a
# successful install from a clone — where TMP is empty — exit 1.
cleanup() {
    if [ -n "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT INT TERM

if [ -n "$SOURCE" ]; then
    ok "installing from $SOURCE"
else
    command -v curl >/dev/null 2>&1 || die "curl is required to download braid"
    TMP=$(mktemp -d)
    [ -t 2 ] && printf '  %s…fetching %s@%s%s\r' "$D" "$REPO" "$REF" "$Z" >&2
    curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xzf - -C "$TMP" ||
        die "could not download $REPO@$REF"
    SOURCE=$(find "$TMP" -maxdepth 1 -type d -name 'braid-*' | head -1)
    [ -n "$SOURCE" ] || die "the downloaded archive did not look like braid"
    ok "fetched $REPO@$REF"
fi

VERSION=$(cat "$SOURCE/VERSION" 2>/dev/null || echo "unknown")

# --- the engine ---------------------------------------------------------------

# Replaced wholesale rather than merged. The engine is never edited in place — a repo's
# own settings live in its braid.sh and in docs/agents/, never in here — so there is
# nothing in this directory worth preserving across an install.
rm -rf "$DATA"
mkdir -p "$DATA"
for part in bin lib docs VERSION; do
    [ -e "$SOURCE/$part" ] && cp -R "$SOURCE/$part" "$DATA/"
done
chmod +x "$DATA/bin/braid" 2>/dev/null || true
find "$DATA/lib" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
# --- the manifest -------------------------------------------------------------

# The sha256 of every file as braid delivered it. Later, `braid upgrade` compares three
# things — what is on disk, what this manifest says was shipped, and what the new
# version brings — which is what separates the three cases that matter:
#
#   on disk == manifest, upstream changed    nobody touched it     replace silently
#   on disk != manifest, upstream unchanged  it is yours           leave it alone
#   on disk != manifest, upstream changed    a conflict            ask, change nothing
#
# Without the middle column there is no way to tell "you edited this" from "we shipped
# it that way", and an upgrade either overwrites work somebody did to unblock
# themselves, or never updates anything.
write_manifest() {
    target="$1"
    (
        cd "$target" || exit 1
        find . -type f ! -path './manifest' -print |
            LC_ALL=C sort |
            while IFS= read -r file; do
                printf '%s  %s\n' "$(hash_file "$file")" "${file#./}"
            done
    ) >"$target/manifest"
}

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        # No hashing tool is not fatal: the engine still installs and runs. It only
        # means upgrade cannot tell an edit from a delivery, and it says so there.
        printf 'unhashed'
    fi
}

write_manifest "$DATA"
ok "engine $VERSION in $DATA ($(wc -l <"$DATA/manifest" | tr -d ' ') files hashed)"

if [ "$SYMLINK" -eq 1 ]; then
    mkdir -p "$PREFIX"
    ln -sf "$DATA/bin/braid" "$PREFIX/braid"
    ok "braid -> $PREFIX/braid"
fi

# The skills go into the shared ~/.agents/skills/, which is the convention the agents
# already use between them — ~/.claude/skills and ~/.codex/skills hold relative links
# into it. braid joins that rather than inventing a third place, so installing once is
# enough however many agents are on the machine.
#
# Linked, not copied, so `braid upgrade` updates them with everything else. A directory
# that is not a symlink is somebody's own version and is left alone.
link_skill() {
    from="$1"
    to="$2"
    if [ -d "$to" ] && [ ! -L "$to" ]; then
        meh "$(basename "$to") kept — it is yours, not a link"
        return 1
    fi
    rm -f "$to"
    ln -s "$from" "$to"
}

if [ -d "$DATA/lib/skills" ]; then
    SHARED="$HOME/.agents/skills"
    mkdir -p "$SHARED"
    for skill in "$DATA"/lib/skills/*/; do
        [ -d "$skill" ] || continue
        name=$(basename "$skill")
        link_skill "${skill%/}" "$SHARED/$name" || continue
        ok "/$name"

        # And into each agent that keeps its own directory, the way the others already
        # do it — relative, so the chain survives the home directory moving. Only where
        # the directory exists: creating one would be braid configuring an agent nobody
        # installed.
        for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
            [ -d "$(dirname "$agent_dir")" ] || continue
            mkdir -p "$agent_dir"
            link_skill "../../.agents/skills/$name" "$agent_dir/$name" >/dev/null 2>&1 || true
        done
    done
fi

# --- what is on this machine --------------------------------------------------

# Reported, not decided. Which agents a *repository* supports is a committed decision
# made in `braid setup`; what happens to be on this PATH is not it.
found=""
for agent in claude codex; do
    command -v "$agent" >/dev/null 2>&1 && found="$found $agent"
done
if [ -n "$found" ]; then
    ok "agents on PATH:$found"
else
    meh "no agent CLI found — install one (claude, codex, …) before running a wave"
fi

# --- done ---------------------------------------------------------------------

say ""
case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *)
        if [ "$SYMLINK" -eq 1 ]; then
            say "  ${Y}$PREFIX is not on your PATH.${Z} Add this to your shell profile:"
            say ""
            say "      export PATH=\"\$PATH:$PREFIX\""
            say ""
        fi
        ;;
esac

say "  next: from inside a repository you want to use braid in, run"
say ""
say "      braid setup"
say ""
say "  it asks a handful of questions and writes braid.sh. Everything above this line"
say "  was mechanical; that part has to read your code."
say ""
