#!/usr/bin/env bash
# A worker's own port and its own .env.
#
# Isolation is the point of the worktree, and it stops being isolation the moment two
# workers share a port. The failure that costs something is not the second one failing
# to bind — it is the second one succeeding against the *first* one's dev server, or
# against yours, and reporting a green end-to-end test for code it never ran.

[[ -n "${_BRAID_ENV_SH:-}" ]] && return 0
_BRAID_ENV_SH=1

# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

# --- .env ---------------------------------------------------------------------

env_value() {
    local file="${1:?file}" key="${2:?key}"
    [[ -f "$file" ]] || return 1
    grep -m1 "^${key}=" "$file" | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'
}

# Rewrite a key in place, or append it. The key is removed and re-appended rather than
# edited in place so a value containing sed metacharacters cannot corrupt the file.
set_env_key() {
    local file="${1:?file}" key="${2:?key}" value="${3-}" tmp
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        tmp=$(mktemp)
        grep -v "^${key}=" "$file" >"$tmp"
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
        mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

# --- ports --------------------------------------------------------------------

# Every port already written into some worktree's .env. Read from the files rather than
# probed on the network: a worker whose dev server is not running yet still owns its
# port, and handing it to a second worker is exactly the collision this prevents.
claimed_ports() {
    local worktree
    git -C "$(primary_checkout)" worktree list --porcelain |
        sed -n 's/^worktree //p' |
        while read -r worktree; do
            [[ -f "$worktree/.env" ]] || continue
            env_value "$worktree/.env" BRAID_PORT || true
        done
}

# Derived from the slice id so it is stable across re-provisions of the same worktree —
# a worker sent back to fix something keeps the port its notes and its browser tabs
# refer to — then walked forward past anything already claimed.
worker_port() {
    local slug="${1:?slug}" n claimed port i
    if [[ "$slug" =~ ^([0-9]+)(-|$) ]]; then
        n=$((10#${BASH_REMATCH[1]} % BRAID_PORT_RANGE))
    else
        n=$(($(printf '%s' "$slug" | cksum | cut -d' ' -f1) % BRAID_PORT_RANGE))
    fi
    claimed=$(claimed_ports)
    for ((i = 0; i < BRAID_PORT_RANGE; i++)); do
        port=$((BRAID_PORT_BASE + (n + i) % BRAID_PORT_RANGE))
        grep -qx "$port" <<<"$claimed" || {
            printf '%s' "$port"
            return 0
        }
    done
    die "no free port in ${BRAID_PORT_BASE}-$((BRAID_PORT_BASE + BRAID_PORT_RANGE - 1))"
}

# A short unique suffix for anything else that needs a per-worker name: a test schema,
# a queue, a container. Recomputable from the branch, so a teardown that runs after the
# worktree is gone can still name what it has to remove.
worker_suffix() {
    local slug="${1:?slug}"
    if [[ "$slug" =~ ^([0-9]+)(-|$) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'h%s' "$(printf '%s' "$slug" | cksum | cut -d' ' -f1)"
    fi
}

# --- the common case ----------------------------------------------------------

# What most projects need from provisioning: the primary checkout's .env, with this
# worker's own port. Call it from braid.sh rather than reimplementing it.
provision_env() {
    local worktree="${1:?worktree}" slug="${2:?slug}" source_env port
    source_env="$(primary_checkout)/.env"

    if [[ -f "$worktree/.env" ]]; then
        note "$worktree/.env already exists — leaving it alone"
        return 0
    fi
    if [[ -f "$source_env" ]]; then
        cp "$source_env" "$worktree/.env"
    else
        : >"$worktree/.env"
    fi

    port=$(worker_port "$slug")
    set_env_key "$worktree/.env" BRAID_PORT "$port"
    note "wrote $worktree/.env (port $port)"
}
