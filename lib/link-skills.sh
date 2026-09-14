#!/bin/sh
# Put braid's own skills where the agents on this machine look for them.
#
#   sh lib/link-skills.sh <engine-directory>
#
# Called by the installer and by `braid upgrade`, because an install is not the only
# moment this is true: install an agent next month and it has no links, and a skill that
# arrives in an upgrade is linked nowhere for anybody until somebody reruns the
# installer. Both were silent.
#
# POSIX sh, not bash, because the installer is.
#
# Agents share ~/.agents/skills, and each keeps relative links into it. braid joins that
# convention rather than inventing a third place, so linking once is enough however many
# agents are on the machine. Linked and never copied, so an upgrade updates them with
# everything else; a directory that is not a symlink is somebody's own and is left alone.

set -u

DATA="${1:?engine directory}"
[ -d "$DATA/lib/skills" ] || exit 0

link_skill() {
    if [ -d "$2" ] && [ ! -L "$2" ]; then
        return 1
    fi
    rm -f "$2"
    ln -s "$1" "$2"
}

SHARED="$HOME/.agents/skills"
for skill in "$DATA"/lib/skills/*/; do
    [ -d "$skill" ] || continue
    name=$(basename "$skill")

    # Only where an agent keeps a skills directory. ~/.agents is a convention agents
    # share, not one braid may start on their behalf: creating it on a machine with no
    # agent at all is braid leaving a mark to prove it was here.
    linked=""
    for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.cursor/skills"; do
        [ -d "$(dirname "$agent_dir")" ] || continue
        mkdir -p "$SHARED" "$agent_dir"
        link_skill "${skill%/}" "$SHARED/$name" || continue
        link_skill "../../.agents/skills/$name" "$agent_dir/$name" >/dev/null 2>&1 || continue
        linked="$linked $(basename "$(dirname "$agent_dir")")"
    done
    [ -z "$linked" ] || printf '%s:%s\n' "$name" "$linked"
done
