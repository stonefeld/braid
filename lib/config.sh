#!/usr/bin/env bash
# What this repository and this machine have decided, and where each answer came from.
#
#   braid config                 the cost table, asked one row at a time
#   braid config list            every value, resolved, with the layer it came from
#   braid config get NAME        one value, resolved
#   braid config set NAME VALUE  write it to braid.sh — committed, for everyone
#
#     --machine   write ~/.config/braid/config instead: this computer, every repository
#
# The way to change something that needs neither an agent nor a text editor. `braid init`
# scaffolds a repository and `braid learn` opens the session that works out what it is;
# this is for afterwards, when you know the answer and only want it written down.
#
# Writing goes to braid.sh by default because that is the layer somebody can review: a
# decision about a repository belongs in the repository, where a pull request can argue
# with it. `--machine` is for facts about one computer — how many workers it survives,
# which agent that person prefers — and its file is not committed, so a value there is a
# value nobody else can see.

set -uo pipefail

# shellcheck source=seats.sh
source "$BRAID_HOME/lib/seats.sh"

MACHINE_FILE=0
ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --machine)
            MACHINE_FILE=1
            shift
            ;;
        -h | --help)
            braid_help "$0"
            exit 0
            ;;
        -*) die "unknown argument: $1" ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Captured before anything is resolved. braid_config exports most of what it reads, so
# asking afterwards would report braid's own exports as the caller's environment — and
# telling a committed decision from one person's shell is most of what this command is
# for.
EXPORTED=$(env)

braid_config
refuse_worker_seat

MACHINE="${XDG_CONFIG_HOME:-$HOME/.config}/braid/config"
setting_layer() {
    local name="${1:?name}"
    if grep -q "^$name=" <<<"$EXPORTED"; then
        printf 'environment'
    elif [[ -f "$MACHINE" ]] && braid_machine_allows "$name" &&
        grep -qE "^[[:space:]]*$name=" "$MACHINE"; then
        printf 'machine'
    elif [[ -f "$_BRAID_PROJECT_FILE" ]] &&
        grep -qE "^[[:space:]]*: \"\\\$\\{$name:=" "$_BRAID_PROJECT_FILE"; then
        printf 'braid.sh'
    else
        printf 'default'
    fi
}


# seats.sh has a `shown` for a table where empty means the CLI decides. Here empty
# means a lower layer answers, which is a different sentence.
unset_or() { printf '%s' "${1:-(unset — whatever is under it decides)}"; }

# What the machine file said that braid did not take. Read out where somebody is looking
# for it rather than on every command that happens to load configuration.
machine_refusals() {
    local name why
    while IFS='|' read -r name why; do
        [[ -n "$name" ]] || continue
        meh "$MACHINE: $name $why"
    done <<<"$_BRAID_MACHINE_REFUSED"
}

# Every name, set or not. A listing of only what somebody already decided answers the
# question you did not have — the point of a command that writes configuration without
# opening a file is finding out what there is to write.
config_list() {
    note "resolved for $(current_branch), from $_BRAID_PROJECT_FILE"
    echo >&2
    OUTSIDE=0
    for NAME in $_BRAID_SETTINGS; do
        FROM=$(setting_layer "$NAME")
        case "$FROM" in
            environment | machine) OUTSIDE=1 ;;
        esac
        printf '  %-28s %-11s %s\n' "$NAME" "$FROM" "${!NAME:-—}" >&2
    done
    echo >&2
    info "— is unset, and whatever is under it decides"
    [[ "$OUTSIDE" -eq 0 ]] ||
        meh "some values came from outside braid.sh, so they are not what your coworkers get"
    machine_refusals
}

case "${ARGS[0]:-}" in
    get)
        NAME="${ARGS[1]:-}"
        [[ -n "$NAME" ]] || die "braid config get <name>"
        braid_setting_known "$NAME" || die "'$NAME' is not a braid setting — braid config list names them all"
        printf '%s\n' "${!NAME:-}"
        ;;

    set)
        NAME="${ARGS[1]:-}"
        [[ -n "$NAME" ]] || die "braid config set <name> <value>"
        [[ "${#ARGS[@]}" -ge 3 ]] || die "braid config set $NAME <value>  (empty is '')"
        VALUE="${ARGS[2]}"
        braid_setting_known "$NAME" || die "$(
            printf '%s\n' \
                "'$NAME' is not a braid setting." \
                "  braid config list       every name there is" \
                "  docs/reference/configuration.md   what each one does"
        )"

        if [[ "$MACHINE_FILE" -eq 1 ]] && ! braid_machine_allows "$NAME"; then
            die "$(
                printf '%s\n' \
                    "$NAME is this repository's to decide, not one machine's." \
                    "  a file nobody else can see must not overrule a reviewed decision." \
                    "" \
                    "  braid config set $NAME <value>   in braid.sh, where it is argued with"
            )"
        fi

        BEFORE="${!NAME:-}"
        FROM=$(setting_layer "$NAME")
        if [[ "$MACHINE_FILE" -eq 1 ]]; then
            mkdir -p "$(dirname "$MACHINE")"
            python3 - "$NAME" "$VALUE" "$MACHINE" <<'PY'
import pathlib
import re
import sys

name, value, target = sys.argv[1], sys.argv[2], sys.argv[3]
path = pathlib.Path(target)
text = path.read_text(encoding="utf-8") if path.exists() else ""
line = "%s=%s" % (name, value)
pattern = re.compile(r"(?m)^[ \t]*%s=.*$" % re.escape(name))
if pattern.search(text):
    text = pattern.sub(lambda _: line, text, count=1)
else:
    text = (text.rstrip("\n") + "\n" if text.strip() else "") + line + "\n"
path.write_text(text, encoding="utf-8")
PY
            WHERE="$MACHINE"
        else
            [[ -f "$_BRAID_PROJECT_FILE" ]] ||
                die "no braid.sh on this branch — run braid init, or use --machine"
            ( cd "$(dirname "$_BRAID_PROJECT_FILE")" &&
                braid_sh_set "$NAME" "$VALUE" "" "$(basename "$_BRAID_PROJECT_FILE")" )
            WHERE="$_BRAID_PROJECT_FILE"
        fi

        # Both values, always. A setting whose old value came from a layer you are not
        # writing to is a setting that will not change, and saying only the new one hides
        # exactly that case.
        note "$NAME in $WHERE"
        info "was:  $(unset_or "$BEFORE")${BEFORE:+   (from $FROM)}"
        info "now:  $(unset_or "$VALUE")"
        if [[ "$FROM" == environment && "$MACHINE_FILE" -eq 0 ]]; then
            meh "$NAME is exported in this shell, which outranks both files — unset it to see this take effect"
        fi
        case "$NAME" in
            BRAID_AGENTS | BRAID_SLICE_SOURCE)
                note "what braid scaffolds follows this — braid init makes what it now calls for"
                ;;
        esac
        ;;

    "")
        # The table, when somebody is there to answer it. Piped or run from a script the
        # listing is the useful half, and a prompt nobody can see is worse than the
        # default it would have guarded.
        if [[ -t 0 ]]; then
            seats_ask || exit 1
        else
            config_list
        fi
        ;;

    list) config_list ;;

    *) die "unknown: braid config ${ARGS[0]} (expected: list, get, set, or nothing)" ;;
esac
