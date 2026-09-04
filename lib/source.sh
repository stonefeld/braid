#!/usr/bin/env bash
# Where slices come from.
#
#   files    markdown under $BRAID_FEATURES_DIR/<feature>/   (the default)
#   github   issues, with a PRD issue as their parent
#
# The braid block is parsed the same way from either — it is markdown in both, and that
# is the whole reason a slice can move between them without being rewritten. What
# changes is only how the text is fetched and how the set is enumerated.
#
# A project overrides `braid_fetch_slice` in braid.sh to read from something else. The
# only contract is: given an id, print the slice's markdown.

[[ -n "${_BRAID_SOURCE_SH:-}" ]] && return 0
_BRAID_SOURCE_SH=1

# shellcheck source=slice.sh
source "$BRAID_HOME/lib/slice.sh"
# shellcheck source=config.sh
source "$BRAID_HOME/lib/config.sh"

# The one definition of where a feature's slices and plan live. Three commands used to
# build this path themselves, which is why fixing it in one place would have left three
# reading the wrong tree.
slice_dir() {
    branch_path "$BRAID_FEATURES_DIR/${1:?feature}"
}

# --- one slice ----------------------------------------------------------------

# A path is always a path, whatever the source: it is unambiguous, and it is what makes
# `braid spawn ./some/slice.md` work in a repository configured for a tracker.
fetch_slice() {
    local id="${1:?id}" match

    if [[ -f "$id" ]]; then
        cat "$id"
        return 0
    fi
    if declare -F braid_fetch_slice >/dev/null; then
        braid_fetch_slice "$id"
        return $?
    fi

    case "$BRAID_SLICE_SOURCE" in
        files)
            match="$(slice_dir "${BRAID_FEATURE:-}")/$id.md"
            [[ -f "$match" ]] || die "no slice at $match"
            cat "$match"
            ;;
        github)
            require_cmd gh "BRAID_SLICE_SOURCE=github needs the gh CLI"
            progress "reading #${id}…"
            gh issue view "$id" --json number,title,body,url 2>/dev/null |
                python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)

# The title becomes the heading and the URL follows it, so a worker reading
# .braid/slice.md sees what a person opening the issue would. The braid block, wherever
# it sits in the body, is still the first fence in the document.
print("# " + d["title"] + "\n")
print(d["url"] + "\n")
print("---\n")
print(d["body"] or "")
' || die "could not read issue #$id"
            progress_done
            ;;
        *) die "unknown BRAID_SLICE_SOURCE '$BRAID_SLICE_SOURCE' (expected: files, github)" ;;
    esac
}

# The title, for naming a branch after something a person can read. Files carry it in
# their name already; an issue does not.
slice_display_id() {
    local id="${1:?id}" title
    case "$BRAID_SLICE_SOURCE" in
        github)
            [[ "$id" =~ ^[0-9]+$ ]] || {
                printf '%s' "$id"
                return 0
            }
            title=$(gh issue view "$id" --json title --jq .title 2>/dev/null) || title=""
            printf '%s' "$id${title:+-$(slugify "$title")}"
            ;;
        *) printf '%s' "$id" ;;
    esac
}

# --- the set ------------------------------------------------------------------

# Every slice in a feature, in a stable order, so a re-run of plan produces the same
# schedule and an unchanged plan produces no diff.
list_slices() {
    local feature="${1:?feature}" dir file id prd

    case "$BRAID_SLICE_SOURCE" in
        files)
            dir=$(slice_dir "$feature")
            [[ -d "$dir" ]] || return 1
            for file in "$dir"/*.md; do
                [[ -f "$file" ]] || continue
                id=$(basename "$file" .md)
                case "$id" in prd | plan | README) continue ;; esac
                printf '%s\n' "$id"
            done
            ;;
        github)
            require_cmd gh "BRAID_SLICE_SOURCE=github needs the gh CLI"
            # Given on the command line the first time, read back out of the plan every
            # time after — which is why `braid plan --prd N` is said once and never again.
            prd="${BRAID_PRD:-$(feature_prd "$feature" 2>/dev/null || true)}"
            [[ -n "$prd" ]] ||
                die "$(printf '%s\n' \
                    "this feature has no PRD issue recorded." \
                    "  braid plan --prd <number>    say it once; it is kept in plan.md")"
            progress "reading the sub-issues of #${prd}…"
            # A closed sub-issue is not work, whatever it once was. A PRD that has
            # shipped three waves keeps every one of them as a child, and scheduling
            # them again would be wrong once per slice ever built under it.
            #
            # Open is necessary and not sufficient — a spike, or an issue still waiting
            # on an answer, is open and not launchable, and only the tracker's own
            # vocabulary can say which. That needs a project hook, and a project hook
            # needs braid.sh to be read from the branch that defines it, which is not
            # true yet.
            gh issue view "$prd" --json subIssues \
                --jq '.subIssues.nodes[] | select(.state == "OPEN") | .number' 2>/dev/null ||
                die "could not read the sub-issues of #$prd"
            progress_done
            ;;
    esac
}

# The PRD an existing plan was built from. Recorded in the plan's own braid block the
# first time, so every later command finds it without being told again.
feature_prd() {
    local plan prd
    plan="$(slice_dir "${1:?feature}")/plan.md"
    [[ -f "$plan" ]] || return 1
    prd=$(slice_field "$(cat "$plan")" prd) || return 1
    prd="${prd#\#}"
    [[ -n "$prd" ]] || return 1
    printf '%s' "$prd"
}
