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
# Why the tracker did not answer. Called only after something has already failed, so it
# can afford to ask questions the fast path never pays for — and "could not read #123"
# with no reason costs a great deal more than the second this takes.
#
# Three answers, and they have three different remedies. It does not pretend to separate
# "offline" from "not logged in": `gh auth status` fails the same way for both, guessing
# would be a coin flip, and the two lines it prints cover either.
gh_trouble() {
    if ! command -v gh >/dev/null 2>&1; then
        printf '%s\n' \
            "the gh CLI is not installed, and BRAID_SLICE_SOURCE=github needs it." \
            "  install it, or put the slices in files: BRAID_SLICE_SOURCE=files"
        return 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
        printf '%s\n' \
            "gh could not reach GitHub, or is not authenticated here." \
            "  gh auth status        what it thinks" \
            "  gh auth login         if that is the problem"
        return 0
    fi
    printf '%s\n' \
        "gh is working, so this is about the issue itself: it does not exist," \
        "  belongs to another repository, or this account cannot see it."
}

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
            command -v gh >/dev/null 2>&1 || die "$(gh_trouble)"
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
' || die "$(printf '%s\n' "could not read issue #$id." "$(gh_trouble)")"
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
    local feature="${1:?feature}" dir file id prd ids skipped

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
            command -v gh >/dev/null 2>&1 || die "$(gh_trouble)"
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
            # vocabulary can say which. `braid_slice_launchable` is the project saying
            # it; undefined, it returns 0 and everything open is work.
            ids=$(gh issue view "$prd" --json subIssues \
                --jq '.subIssues.nodes[] | select(.state == "OPEN") | .number' 2>/dev/null) ||
                die "$(printf '%s\n' "could not read the sub-issues of #$prd." "$(gh_trouble)")"
            progress_done
            # Counted and said once, not announced per issue: the PRD this was written
            # for has thirty-nine of them, and a line each turns every `braid next` into
            # a page of things that are deliberately not happening.
            skipped=0
            while read -r id; do
                [[ -n "$id" ]] || continue
                if braid_slice_launchable "$id"; then
                    printf '%s\n' "$id"
                else
                    skipped=$((skipped + 1))
                fi
            done <<<"$ids"
            [[ "$skipped" -eq 0 ]] ||
                note "$skipped open sub-issues withdrawn by braid_slice_launchable"
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
