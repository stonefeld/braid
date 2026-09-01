#!/usr/bin/env bash
# Update the engine, without losing what you changed to unblock yourself.
#
#   braid upgrade
#   braid upgrade --check       say what would happen, change nothing
#   braid upgrade --ref v0.4.0  a particular tag or branch
#   braid upgrade --from DIR    a working copy, for developing braid itself
#
#     --take PATH   resolve one conflict in the new version's favour (repeatable)
#     --keep PATH   resolve one conflict in yours
#
# Three facts are compared, not two: what is on disk, what braid shipped last time
# (lib/../manifest), and what the new version brings. The middle one is the whole point
# — without it there is no way to tell "you edited this" from "we shipped it that way",
# and an upgrade has to pick one bad default: overwrite the fix somebody wrote while
# something was broken, or never replace anything and go stale.
#
#   unchanged by you, changed upstream    replaced, silently
#   changed by you, unchanged upstream    left alone, silently
#   changed by both                       a conflict: reported, nothing written

set -uo pipefail

# shellcheck source=core.sh
source "$BRAID_HOME/lib/core.sh"

CHECK=0
REF="main"
FROM=""
TAKE=""
KEEP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK=1
            shift
            ;;
        --ref)
            REF="${2:?--ref needs a tag or branch}"
            shift 2
            ;;
        --from)
            FROM="${2:?--from needs a directory}"
            shift 2
            ;;
        --take)
            TAKE="$TAKE ${2:?--take needs a path}"
            shift 2
            ;;
        --keep)
            KEEP="$KEEP ${2:?--keep needs a path}"
            shift 2
            ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1
    fi
}

# --- the new version ----------------------------------------------------------

TMP=""
cleanup() { [[ -n "$TMP" ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

if [[ -n "$FROM" ]]; then
    NEW=$(cd "$FROM" && pwd) || die "no such directory: $FROM"
    [[ -f "$NEW/install.sh" && -d "$NEW/lib" ]] || die "$NEW does not look like braid's repository"
else
    require_cmd curl
    TMP=$(mktemp -d)
    progress "fetching stonefeld/braid@$REF…"
    curl -fsSL "https://github.com/stonefeld/braid/archive/$REF.tar.gz" |
        tar -xzf - -C "$TMP" || die "could not download stonefeld/braid@$REF"
    progress_done
    NEW=$(find "$TMP" -maxdepth 1 -type d -name 'braid-*' | head -1)
    [[ -n "$NEW" ]] || die "the downloaded archive did not look like braid"
fi

HAVE=$(braid_version)
WANT=$(cat "$NEW/VERSION" 2>/dev/null || echo unknown)
note "$HAVE -> $WANT"

MANIFEST="$BRAID_HOME/manifest"
[[ -f "$MANIFEST" ]] ||
    warn "no manifest — every difference will look like a conflict. that is the honest answer, not a bug."

# --- classify -----------------------------------------------------------------

# Only files this installation actually has. Something the new version adds is simply
# new, and something it drops is gone; neither can be a conflict.
YOURS=""
CONFLICTS=""
CHANGED=0

while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    here="$BRAID_HOME/$rel"
    theirs="$NEW/$rel"
    [[ -f "$here" ]] || continue

    shipped=$(grep -F "  $rel" "$MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f1)
    now=$(hash_file "$here")
    new=$(hash_file "$theirs")

    [[ "$now" == "$new" ]] && continue
    CHANGED=$((CHANGED + 1))

    if [[ -n "$shipped" && "$now" == "$shipped" ]]; then
        continue # theirs, and you never touched it
    fi
    if [[ -z "$shipped" ]]; then
        CONFLICTS="$CONFLICTS $rel"
        continue
    fi
    if [[ "$new" == "$shipped" ]]; then
        YOURS="$YOURS $rel" # you changed it, upstream did not
    else
        CONFLICTS="$CONFLICTS $rel" # both
    fi
done < <(cd "$NEW" && find bin lib docs VERSION -type f 2>/dev/null | sed 's|^\./||')

# Taking the new version overwrites something somebody wrote while they were blocked,
# so it is kept — outside the engine, where the next install cannot remove it and the
# manifest will not count it as a delivered file.
REPLACED="${XDG_STATE_HOME:-$HOME/.local/state}/braid/replaced/$(date +%Y%m%d-%H%M%S)"
for path in $TAKE; do
    CONFLICTS=" $(printf '%s' " $CONFLICTS " | sed "s| $path | |") "
    if [[ -f "$BRAID_HOME/$path" && "$CHECK" -eq 0 ]]; then
        mkdir -p "$REPLACED/$(dirname "$path")"
        cp "$BRAID_HOME/$path" "$REPLACED/$path"
        info "yours saved: $REPLACED/$path"
    fi
done
for path in $KEEP; do
    CONFLICTS=" $(printf '%s' " $CONFLICTS " | sed "s| $path | |") "
    YOURS="$YOURS $path"
done
CONFLICTS=$(printf '%s' "$CONFLICTS" | tr -s ' ' | sed 's/^ //; s/ $//')
YOURS=$(printf '%s' "$YOURS" | tr -s ' ' | sed 's/^ //; s/ $//')

# --- report -------------------------------------------------------------------

echo >&2
[[ "$CHANGED" -eq 0 ]] && ok "nothing changed upstream"
[[ -n "$YOURS" ]] && {
    for rel in $YOURS; do info "yours, kept: $rel"; done
}
if [[ -n "$CONFLICTS" ]]; then
    for rel in $CONFLICTS; do
        meh "conflict: $rel"
        printf '            diff %s %s\n' "$BRAID_HOME/$rel" "$NEW/$rel" >&2
    done
    warn "$(printf '%s\n' \
        "nothing was written." \
        "  take theirs:  braid upgrade --take <path>   (yours is kept under ~/.local/state/braid)" \
        "  keep yours:   braid upgrade --keep <path>")"
    exit 6
fi

if [[ "$CHECK" -eq 1 ]]; then
    note "--check: nothing written"
    exit 0
fi

# --- apply --------------------------------------------------------------------

# Set aside before the installer replaces the tree wholesale, restored after. They are
# deliberately not re-hashed into the new manifest: on the next upgrade they must still
# read as yours.
STASH=""
if [[ -n "$YOURS" ]]; then
    STASH=$(mktemp -d)
    for rel in $YOURS; do
        mkdir -p "$STASH/$(dirname "$rel")"
        cp "$BRAID_HOME/$rel" "$STASH/$rel"
    done
fi

# The new version installs itself, so there is one installation path rather than two
# that can disagree about what an installation is.
sh "$NEW/install.sh" --prefix "$(dirname "$(command -v braid || echo "$HOME/.local/bin/braid")")" >&2 ||
    die "the new version's installer failed — the old engine is still in $BRAID_HOME"

if [[ -n "$STASH" ]]; then
    for rel in $YOURS; do
        cp "$STASH/$rel" "$BRAID_HOME/$rel"
        info "restored yours: $rel"
    done
    rm -rf "$STASH"
fi

# --- overrides ----------------------------------------------------------------

# A launcher you wrote shadows the built-in and is never touched by an upgrade. But if
# the built-in it shadows has changed, yours may no longer be needed — and nothing else
# would ever tell you.
OVERRIDES="${XDG_CONFIG_HOME:-$HOME/.config}/braid/launchers"
if [[ -d "$OVERRIDES" ]]; then
    for file in "$OVERRIDES"/*.sh; do
        [[ -f "$file" ]] || continue
        name=$(basename "$file" .sh)
        rel="lib/launchers/$name.sh"
        [[ -f "$NEW/$rel" ]] || continue
        shipped=$(grep -F "  $rel" "$MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f1)
        [[ -n "$shipped" && "$(hash_file "$NEW/$rel")" != "$shipped" ]] || continue
        meh "you override $name, and the built-in changed in $WANT — yours may no longer be needed"
        printf '            diff %s %s\n' "$file" "$BRAID_HOME/$rel" >&2
    done
fi

echo >&2
ok "braid $WANT"
