#!/bin/sh
# Install braid.
#
#   curl -fsSL https://raw.githubusercontent.com/stonefeld/braid/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --ref v0.1.0      pin a version
#   ./install.sh                              from a clone
#
#     --prefix DIR     where the dispatcher is linked   (default: ~/.local/bin)
#     --ref REF        which tag or branch to install   (default: the latest release)
#     --no-symlink     install the engine, link nothing
#
# This half is deterministic and asks nothing: it puts the engine on the machine and
# tells you what it found. Teaching braid about a *repository* — its tracker, its test
# command, the language it writes issues in — is `braid setup`, which is a conversation
# with an agent and is deliberately not in this pipe.
#
# **It is two programs in one file.** Piped from curl it is a bootstrapper: it checks the
# machine, resolves which version you asked for, downloads it, and hands over to the
# install.sh *inside that tarball*. From a directory that holds the engine it is the
# installer itself.
#
# That split exists because the installer can change between versions. Without it, the
# file on `main` installs an older engine using a newer installer — a combination nobody
# tested and nothing declares. Delegating means the installer that runs is always the one
# that shipped with the engine it is installing, which is the property `braid upgrade`
# already had and a fresh install did not.
#
# The consequence to keep in mind when editing: **the inner run may be an old version**,
# so the bootstrapper may only pass it flags that have always existed.
#
# POSIX sh on purpose. `curl | sh` runs under /bin/sh, which is dash on Debian and
# busybox ash elsewhere; a bashism here fails on the very first thing a new user runs.

set -eu

REPO="stonefeld/braid"
# Empty means "resolve the latest release". Not `main`: main is where work in progress
# lives, and defaulting an installer to it means every new user is a tester and every
# `braid upgrade` is an unannounced jump.
REF=""
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
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

# --- which of the two programs this is ----------------------------------------

# From a directory that holds the engine, this file *is* the installer — which is what
# you want from a clone while working on braid itself. Read off stdin by `curl | sh`,
# $0 has no directory in it, nothing is beside us, and this run is the bootstrapper.
SOURCE=""
case "$0" in
    */*)
        candidate=$(cd "$(dirname "$0")" && pwd)
        [ -d "$candidate/lib" ] && [ -f "$candidate/bin/braid" ] && SOURCE="$candidate"
        ;;
esac

# The bootstrapper stays quiet on success: everything it would print, the run it hands
# over to prints properly a second later, and a doubled banner is the first thing a new
# user sees.
if [ -z "$SOURCE" ]; then
    BOOTSTRAP=1
else
    BOOTSTRAP=0
    say ""
    say "braid"
    say ""
fi

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

[ "$BOOTSTRAP" -eq 1 ] || ok "git $git_version, bash, python3"

# --- the source ---------------------------------------------------------------

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

# Which ref an unpinned install means. Asked of git rather than of the GitHub API: git is
# already a hard dependency, it needs no token and has no rate limit, and `--sort` makes
# it do the version ordering — `sort -V` is not on a stock macOS.
latest_release() {
    git ls-remote --sort=-v:refname --tags --refs "https://github.com/$REPO" 'v*' 2>/dev/null |
        sed -n 's#.*refs/tags/##p' | head -1
}

# What braid was installed from, next to what it is. Without it there is no way to tell
# an engine that came from a release from one that came from main, which is exactly the
# question you have when something behaves unlike the changelog.
record_ref() {
    printf '%s\n' "${1:?ref}" >"$DATA/REF" 2>/dev/null || true
}

if [ -z "$SOURCE" ]; then
    # --- the bootstrapper ------------------------------------------------------
    command -v curl >/dev/null 2>&1 || die "curl is required to download braid"
    [ -z "${BRAID_INSTALL_DELEGATED:-}" ] ||
        die "the archive for $REF has no engine in it — not fetching again"

    if [ -z "$REF" ]; then
        REF=$(latest_release)
        if [ -n "$REF" ]; then
            ok "latest release: $REF"
        else
            REF="main"
            meh "no release tag found — installing main, which is not a release"
        fi
    fi

    TMP=$(mktemp -d)
    [ -t 2 ] && printf '  %s…fetching %s@%s%s\r' "$D" "$REPO" "$REF" "$Z" >&2
    curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xzf - -C "$TMP" ||
        die "could not download $REPO@$REF"
    SOURCE=$(find "$TMP" -maxdepth 1 -type d -name 'braid-*' | head -1)
    [ -n "$SOURCE" ] || die "could not find braid in the archive for $REF"
    ok "fetched $REPO@$REF"

    # Hand over to the installer that shipped inside that tarball, so the installer
    # that runs is always the one belonging to the engine being installed.
    #
    # Only --prefix and --no-symlink cross this line: the inner run may be any released
    # version, and a flag it does not know is a `die` on the first thing a user runs.
    # Anything newer travels as an environment variable instead, which an older script
    # ignores harmlessly.
    say ""
    set -- --prefix "$PREFIX"
    [ "$SYMLINK" -eq 1 ] || set -- "$@" --no-symlink
    BRAID_INSTALL_DELEGATED=1 BRAID_INSTALL_REF="$REF" sh "$SOURCE/install.sh" "$@" || exit $?
    # Written here as well as inside, because an older inner run does not know to.
    record_ref "$REF"
    exit 0
fi

ok "installing from $SOURCE"
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
# Whatever the bootstrapper resolved; from a clone, what git calls this checkout. The
# manifest does not cover it, deliberately — it is a fact about the install, not a file
# braid shipped.
INSTALLED_REF="${BRAID_INSTALL_REF:-}"
if [ -z "$INSTALLED_REF" ]; then
    INSTALLED_REF=$(git -C "$SOURCE" describe --tags --always --dirty 2>/dev/null || echo local)
fi
record_ref "$INSTALLED_REF"
ok "engine $VERSION ($INSTALLED_REF) in $DATA ($(wc -l <"$DATA/manifest" | tr -d ' ') files hashed)"

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
