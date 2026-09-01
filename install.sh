#!/bin/sh
# Install braid.
#
#   curl -fsSL https://braid.sh/install | sh
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
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
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
ok "engine $VERSION in $DATA"

if [ "$SYMLINK" -eq 1 ]; then
    mkdir -p "$PREFIX"
    ln -sf "$DATA/bin/braid" "$PREFIX/braid"
    ok "braid -> $PREFIX/braid"
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

say "  next:"
say ""
say "      braid help"
say ""
