#!/usr/bin/env bash
# The invariants that rot silently.
#
#   test/compat.sh
#
# None of these break loudly. A bash 4 construct works on the machine that wrote it and
# fails on macOS's stock bash months later; a third-party python import works until
# somebody without it runs `curl | sh`. So they are checked mechanically rather than
# remembered.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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

echo
echo "compat"
echo

# --- bash 3.2 -----------------------------------------------------------------

# macOS still ships 3.2 as /bin/bash, and a tool installed with `curl | sh` cannot ask
# people to brew install a shell before the first command works.
# A line carrying this marker is exempt — which the pattern below needs, since it
# contains every construct it looks for.
BASH4='declare -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}|&>>|;;&' # compat-ignore
hits=$(grep -rnE "$BASH4" bin lib test test.sh 2>/dev/null |
    grep -v 'compat-ignore' | grep -v '^[^:]*:[0-9]*: *#' || true)
if [[ -z "$hits" ]]; then
    ok "no bash 4 constructs"
else
    bad "bash 4 constructs found:"
    printf '%s\n' "$hits" | sed 's/^/          /'
fi

if command -v bash >/dev/null && [[ -x /bin/bash ]]; then
    version=$(/bin/bash --version | head -1 | sed -E 's/.*version ([0-9]+\.[0-9]+).*/\1/')
    for f in bin/braid lib/*.sh lib/agents/*.sh lib/templates/*.sh test/*.sh test.sh; do
        /bin/bash -n "$f" 2>/dev/null || bad "/bin/bash $version cannot parse $f"
    done
    ok "/bin/bash $version parses every script"
fi

# --- POSIX sh -----------------------------------------------------------------

# install.sh is reached as `curl … | sh`, which is dash on Debian and busybox ash
# elsewhere. A bashism here fails on the very first thing a new user runs.
if sh -n install.sh 2>/dev/null; then
    ok "install.sh parses as POSIX sh"
else
    bad "install.sh is not valid POSIX sh"
fi
if grep -nE '\[\[|<<<|\$\(\(.*\+\+|\barray=\(' install.sh >/dev/null 2>&1; then
    bad "install.sh contains bashisms"
else
    ok "install.sh has no obvious bashisms"
fi

# --- python -------------------------------------------------------------------

# Standard library only, everywhere, forever. "Needs python3" is a dependency people
# already have; "needs a python environment" is a support burden.
if python3 - <<'PY'; then
import ast, pathlib, sys

allowed = getattr(sys, "stdlib_module_names", None)
offenders = []
for path in pathlib.Path("lib").rglob("*.py"):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            names = [(node.module or "").split(".")[0]] if node.level == 0 else []
        else:
            continue
        for name in names:
            if not name:
                continue
            if allowed is not None and name not in allowed:
                offenders.append(f"{path}: {name}")
if offenders:
    print("\n".join(offenders))
    sys.exit(1)
PY
    ok "python hooks import the standard library only"
else
    bad "a python hook imports something outside the standard library"
fi

for f in lib/hooks/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" ||
        bad "$f does not parse"
done
ok "python hooks parse"

# --- the installer's exit status ----------------------------------------------

# It printed every success line and then exited 1, because an EXIT trap whose last
# command fails sets the script's status. Nothing in the output said so, which is the
# reason this is checked rather than read.
TMPPREFIX=$(mktemp -d)
if XDG_DATA_HOME="$TMPPREFIX/share" sh ./install.sh --prefix "$TMPPREFIX/bin" >/dev/null 2>&1; then
    ok "install.sh exits 0 on success"
else
    bad "install.sh exits $? despite succeeding"
fi
if XDG_DATA_HOME="$TMPPREFIX/share" BRAID_HOME="$TMPPREFIX/share/braid" \
    "$TMPPREFIX/bin/braid" version >/dev/null 2>&1; then
    ok "the installed dispatcher runs"
else
    bad "the installed dispatcher does not run"
fi
rm -rf "$TMPPREFIX"

# --- what the bootstrapper may say to the installer ----------------------------

# install.sh piped from curl hands over to the install.sh inside the tarball it just
# downloaded — which is whatever version was asked for, possibly years old. Its public
# flags are --prefix and --no-symlink; anything else is an "unknown argument" die on the
# first thing a new user types, and only when installing an old version, which is exactly
# the case nobody tries. Newer information travels as an environment variable instead,
# which an old script ignores.
handover=$(grep -E '^[[:space:]]*(\[.*\][[:space:]]*\|\|[[:space:]]*)?set -- ' install.sh |
    grep -oE '\-\-[a-z-]+' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
if [[ "$handover" == "--no-symlink --prefix" ]]; then
    ok "the bootstrapper passes only the installer's stable flags"
else
    bad "the bootstrapper passes: ${handover:-nothing} — only --prefix and --no-symlink may cross"
fi

# --- the manifest -------------------------------------------------------------

# It has to cover everything and be reproducible, or upgrade cannot tell an edit from a
# delivery — and its whole job is telling those apart.
#
# Two files are outside it, for the same reason: `manifest` cannot hash itself, and `REF`
# records where this install came from rather than something braid shipped. Hashing REF
# would make every install of the same version report as edited by whoever installed it.
TMPMAN=$(mktemp -d)
XDG_DATA_HOME="$TMPMAN/share" sh ./install.sh --prefix "$TMPMAN/bin" >/dev/null 2>&1
MAN="$TMPMAN/share/braid/manifest"
if [[ -s "$MAN" ]]; then
    installed=$(cd "$TMPMAN/share/braid" &&
        find . -type f ! -path './manifest' ! -path './REF' | wc -l | tr -d ' ')
    listed=$(wc -l <"$MAN" | tr -d ' ')
    if [[ "$installed" == "$listed" ]]; then
        ok "manifest covers all $listed installed files"
    else
        bad "manifest lists $listed of $installed installed files"
    fi
    before=$(cat "$MAN")
    XDG_DATA_HOME="$TMPMAN/share" sh ./install.sh --prefix "$TMPMAN/bin" >/dev/null 2>&1
    if [[ "$before" == "$(cat "$MAN")" ]]; then
        ok "manifest is reproducible across installs"
    else
        bad "manifest changes between identical installs"
    fi
else
    bad "no manifest was written"
fi
rm -rf "$TMPMAN"

# --- shellcheck, when it is here ----------------------------------------------

# Pinned. Versions disagree about what to flag, so an unpinned linter makes "clean
# here" and "clean in CI" two different claims — and the difference only ever appears
# as a red build on a commit that passed before it was pushed. When the version does
# not match, this says so and leaves the verdict to the job that does pin it, rather
# than failing on a finding nobody can reproduce.
SHELLCHECK_PINNED=0.11.0
if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  --    shellcheck not installed; the shellcheck job runs %s\n' "$SHELLCHECK_PINNED"
elif [[ "$(shellcheck --version | awk '/version:/ {print $2}')" != "$SHELLCHECK_PINNED" ]]; then
    printf '  --    shellcheck %s, not the pinned %s — the shellcheck job owns this\n' \
        "$(shellcheck --version | awk '/version:/ {print $2}')" "$SHELLCHECK_PINNED"
elif shellcheck --shell=bash bin/braid lib/*.sh lib/agents/*.sh lib/launchers/*.sh \
    lib/templates/*.sh test/*.sh test.sh && shellcheck --shell=sh install.sh; then
    ok "shellcheck clean ($SHELLCHECK_PINNED)"
else
    bad "shellcheck findings"
fi

# --- markdown that renders where it is read -----------------------------------

# A code fence left open, or a closing fence with the next sentence stuck to it, turns
# the rest of a document into one grey box. It is invisible in the diff — the source
# reads correctly, the prose is all there — and shows up only on the page somebody else
# is looking at. The README shipped that way twice: once from a nested ```` fence a
# renderer closed early, once from an edit that ended mid-sentence.
if python3 - <<'PY'; then
import pathlib, re, sys

problems = []
roots = [pathlib.Path(".")]
files = sorted(pathlib.Path(".").glob("*.md"))
for d in ("docs", "lib", "braid"):
    files += sorted(pathlib.Path(d).rglob("*.md")) if pathlib.Path(d).is_dir() else []

for f in files:
    stack = []
    for n, line in enumerate(f.read_text(encoding="utf-8").split("\n"), 1):
        m = re.match(r"^(`{3,}|~{3,})(.*)$", line)
        if not m:
            continue
        mark, rest = m.group(1), m.group(2)
        if stack and mark[0] == stack[-1][0] and len(mark) >= len(stack[-1]):
            if rest.strip():
                problems.append(f"{f}:{n}: a closing fence with text after it")
            stack.pop()
        else:
            # A backtick fence opened inside a backtick fence is legal and renderers
            # disagree about it. Tildes outside, backticks inside.
            if stack and mark[0] == "`" == stack[-1][0]:
                problems.append(f"{f}:{n}: backtick fence nested in a backtick fence")
            stack.append(mark)
    if stack:
        problems.append(f"{f}: {len(stack)} code fence(s) never closed")

if problems:
    print("\n".join(problems))
    sys.exit(1)
PY
    ok "every code fence in every document opens and closes"
else
    bad "markdown that will not render:"
fi

# --- the runner knows about every suite ---------------------------------------

# ./test.sh is what a person runs; CI runs the files. A suite added to test/ and not to
# the runner passes locally by never running, which is the failure this whole file is
# about.
declared=$(./test.sh --list | LC_ALL=C sort | tr '\n' ' ')
present=$(for f in test/*.sh; do basename "$f" .sh; done | LC_ALL=C sort | tr '\n' ' ')
if [[ "$declared" == "$present" ]]; then
    ok "./test.sh runs every suite in test/"
else
    bad "./test.sh runs [$declared] but test/ holds [$present]"
fi

# --- names that were renamed --------------------------------------------------

# A rename that misses a document is silent in the worst way: the worker contract told
# every worker to read AGENT_PORT out of its .env long after the variable had  compat-ignore
# BRAID_PORT, so each one bound to nothing and the failure looked like the project's.
stale=$(grep -rnE 'AGENT_PORT|HARNESS_[A-Z_]+|\.agent/' bin lib docs test install.sh 2>/dev/null | # compat-ignore
    grep -v 'compat-ignore' || true)
if [[ -z "$stale" ]]; then
    ok "no names left over from the rename"
else
    bad "stale names:"
    printf '%s\n' "$stale" | sed 's/^/          /'
fi

# --- unbraced expansions before multibyte text --------------------------------

# bash 3.2 reads the bytes of a following multibyte character as part of the variable
# name, so an ellipsis straight after an expansion fails with "unbound variable" — on
# macOS only, and only on the one line that happens to have one.
#
# Checked in python rather than with grep. The GNU form (-P) does not exist on BSD, so it
# errored on macOS and this passed vacuously; the portable byte-range forms match tabs
# too, which are fine. A check that cannot fail is worse than none, because it is also a
# claim.
if loose=$(python3 "$(dirname "${BASH_SOURCE[0]}")/multibyte.py"); then
    ok "no unbraced expansion runs into multibyte text"
else
    bad "unbraced expansions before a multibyte character:"
    printf '%s\n' "$loose" | sed 's/^/          /'
fi

# --- the guard's own cases ----------------------------------------------------

# Every case exists because the obvious version of a rule had a hole. They are the one
# part of braid where a regression is silent and expensive.
if BRAID_HOME="$(pwd)" python3 lib/hooks/test_guard_remote.py >/dev/null 2>&1; then
    ok "remote guard: all cases pass"
else
    bad "remote guard cases fail — run: python3 lib/hooks/test_guard_remote.py"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
echo
[[ "$FAIL" -eq 0 ]]
