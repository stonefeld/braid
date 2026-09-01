#!/usr/bin/env python3
"""PreToolUse guard — keeps agents off the remote.

The role is derived from the git branch of the directory the tool call runs in:

    <prefix>/*   worker        no gh at all, no push, no remote surgery
    anything     orchestrator  may push its own branch; PR creation asks the human

Hooks fire only on Claude's tool calls, so commands the human types in a shell are never
affected by this. Override with BRAID_AGENT_ROLE=worker|orchestrator|off.

Hooks also run *before* the permission system, which is the whole reason workers can
launch in bypassPermissions: what actually has to be forbidden is forbidden here, in
every mode, and the prompt they bypass is the one that would have stopped a wave in a
panel nobody is watching.

The cases it has to get right are in test_guard_remote.py. Add one there before changing
anything here; every rule below exists because the obvious version of it had a hole.
"""

import json
import os
import re
import shlex
import subprocess
import sys

PREFIX = os.environ.get("BRAID_BRANCH_PREFIX", "agent")
PROTECTED_BRANCHES = set(
    (os.environ.get("BRAID_PROTECTED_BRANCHES") or "main master").split()
)

WORKER_DENY = (
    "Workers must not touch the remote. Commit locally and report in .braid/report.md — "
    "the orchestrator handles pushing, rebasing and any GitHub interaction. "
    "See the worker contract loaded at the start of this session."
)

WRITE_API_FLAGS = {"-X", "--method"}
WRITE_METHODS = {"POST", "PATCH", "PUT", "DELETE"}
# `gh api` sends POST as soon as any of these appear, with no -X in sight. Reading only
# the method flag let `gh api repos/o/r/pulls/1/merge -f merge_method=squash` through.
API_FIELD_FLAGS = {"-f", "--field", "-F", "--raw-field", "--input"}
# gh's global flags that swallow the next token, so it is not mistaken for a subcommand.
GH_FLAGS_WITH_VALUE = {"-R", "--repo", "--hostname"}

# git-push flags that consume the following token.
PUSH_FLAGS_WITH_VALUE = {"-o", "--push-option", "--receive-pack", "--exec", "--repo"}

PR_ASK = (
    "Opening a PR starts CI and re-runs it on every later push. Confirm the wave is "
    "integrated and green first. The proposed title and body should already be in "
    ".braid/pr.md."
)
PR_BODY_DENY = (
    "The closing block of this PR body does not do what it looks like it does — GitHub "
    "would leave the issues open.\n"
)
# Where the PR body comes from on the command line.
PR_BODY_FLAGS = {"-b", "--body"}
PR_BODY_FILE_FLAGS = {"-F", "--body-file"}

# The only words GitHub acts on. Everything else is decoration, however much it reads
# like a closing reference.
CLOSING_KEYWORDS = {
    "close", "closes", "closed",
    "fix", "fixes", "fixed",
    "resolve", "resolves", "resolved",
}
HOUSE_CLOSER = "closes"
# What an agent writing a non-English body reaches for instead. These close nothing, and
# they fail silently, which is the entire reason this check exists.
NON_CLOSERS = {
    "cierra", "cierran", "cierre", "cerrar",
    "arregla", "arreglan", "arreglar",
    "corrige", "corrigen", "corregir",
    "resuelve", "resuelven", "resolver",
    "soluciona", "solucionan",
    "fixea", "fixeado",
    "fecha", "fechar", "encerra", "corrigido",
    "schliesst", "schließt", "behebt",
    "ferme", "corrige",
    "chiude", "risolve",
}
ISSUE_REFERENCE = re.compile(r"#\d+|/issues/\d+")


def emit(decision: str, reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision,
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


def tokens(command: str) -> list[str]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return command.split()


SEPARATORS = {"&&", "||", "|", ";", "&", "(", ")", "{", "}", "!", "then", "do", "else", "\n"}
PREFIXES = {"sudo", "nohup", "time", "command", "xargs", "env", "exec", "builtin"}


def in_command_position(toks: list[str], index: int) -> bool:
    """Distinguish `gh pr create` from `grep -rn gh docs/`."""
    cursor = index - 1
    while cursor >= 0:
        previous = toks[cursor]
        if previous in SEPARATORS:
            return True
        if previous in PREFIXES or "=" in previous and not previous.startswith("-"):
            cursor -= 1
            continue
        return False
    return True


def invocations(toks: list[str], program: str) -> list[list[str]]:
    """Every argument list for `program` invoked as a command."""
    found = []
    for index, token in enumerate(toks):
        if token.rsplit("/", 1)[-1] != program or not in_command_position(toks, index):
            continue
        args = []
        for arg in toks[index + 1 :]:
            if arg in ("&&", "||", "|", ";", "&"):
                break
            args.append(arg)
        found.append(args)
    return found


SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def shell_payloads(toks: list[str]) -> list[str]:
    """Arguments that a shell will itself execute as a command.

    Only `sh -c <arg>` and `eval <args>` qualify. Recursing into every quoted token that
    merely contained "gh" or "git" denied a commit message mentioning a command, and a
    heredoc quoting one — text that is never executed.
    """
    payloads = []
    for index, token in enumerate(toks):
        name = token.rsplit("/", 1)[-1]
        if not in_command_position(toks, index):
            continue
        args = []
        for arg in toks[index + 1 :]:
            if arg in ("&&", "||", "|", ";", "&"):
                break
            args.append(arg)
        if name in SHELLS:
            for position, arg in enumerate(args):
                # -c, and combined short flags ending in c such as -lc or -ec.
                if arg == "-c" or (
                    arg.startswith("-") and not arg.startswith("--") and arg.endswith("c")
                ):
                    if position + 1 < len(args):
                        payloads.append(args[position + 1])
                    break
        elif name == "eval":
            payloads.extend(args)
    return payloads


def token_streams(command: str, depth: int = 0) -> list[list[str]]:
    """The command, plus anything a nested shell would execute.

    `bash -c "gh pr create"` arrives as a single token, so without this the guard reads
    it as an invocation of bash and nothing else.
    """
    toks = tokens(command)
    streams = [toks]
    if depth < 2:
        for payload in shell_payloads(toks):
            streams.extend(token_streams(payload, depth + 1))
    return streams


def git_subcommand(args: list[str]) -> tuple[str, list[str]]:
    """Skip git's global flags (-C dir, -c k=v, --git-dir=...) to reach the subcommand."""
    rest = list(args)
    while rest:
        head = rest[0]
        if head in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            rest = rest[2:]
            continue
        if head.startswith("-"):
            rest = rest[1:]
            continue
        return head, rest[1:]
    return "", []


def branch_of(cwd: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def resolve_role(branch: str) -> str:
    override = os.environ.get("BRAID_AGENT_ROLE", "").strip().lower()
    if override in ("worker", "orchestrator", "off"):
        return override
    return "worker" if branch.startswith(f"{PREFIX}/") else "orchestrator"


def pushes_to_protected(rest: list[str], branch: str) -> bool:
    """Whether `git push <rest>` would write to a protected branch.

    Matching a bare "main" token missed every form that matters: a plain `git push` while
    main is checked out, and `git push origin HEAD:main`. What decides the destination is
    the refspec's right-hand side, or — when there is no refspec — the branch that
    happens to be checked out.
    """
    if any(flag in rest for flag in ("--all", "--mirror")):
        return True

    positional = []
    skip = False
    for arg in rest:
        if skip:
            skip = False
            continue
        if arg in PUSH_FLAGS_WITH_VALUE:
            skip = True
            continue
        if arg.startswith("-"):
            continue
        positional.append(arg)

    refspecs = positional[1:]  # positional[0] is the remote
    if not refspecs:
        # No refspec and no readable branch (detached HEAD, or git failed) means the
        # destination is unknowable, so fail closed. Naming the branch is always allowed.
        return not branch or branch in PROTECTED_BRANCHES

    for refspec in refspecs:
        destination = refspec.split(":")[-1].lstrip("+")
        if destination.removeprefix("refs/heads/") in PROTECTED_BRANCHES:
            return True
    return False


def gh_positional(args: list[str]) -> list[str]:
    """Subcommand path for a gh invocation, with flags and their values removed."""
    positional = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in GH_FLAGS_WITH_VALUE:
            skip = True
            continue
        if arg.startswith("-"):
            continue
        positional.append(arg)
    return positional


def pr_body(args: list[str], cwd: str) -> str:
    """The body `gh pr create` would send, or "" when it cannot be known.

    Unknowable covers `--fill`, a body read from stdin, and the heredoc form
    `--body "$(cat <<'EOF' ...)"` — the shell expands that, the guard does not, so what
    reaches here is the substitution and not a word of the real body.
    """
    for index, arg in enumerate(args):
        name, separator, inline = arg.partition("=")
        if name not in PR_BODY_FLAGS and name not in PR_BODY_FILE_FLAGS:
            continue
        value = inline if separator else (args[index + 1] if index + 1 < len(args) else "")
        if name in PR_BODY_FLAGS:
            return "" if value.lstrip().startswith("$(") else value
        if value in ("", "-"):
            return ""
        path = value if os.path.isabs(value) else os.path.join(cwd, value)
        try:
            with open(path, encoding="utf-8") as handle:
                return handle.read()
        except OSError:
            return ""
    return ""


def closing_line_problems(body: str) -> tuple[list[str], list[str]]:
    """Deal-breakers and style warnings in a PR body's closing references.

    Only lines that *start* with a closing verb are judged. A body that mentions
    "no corrige #295 todavía" mid-sentence is prose about an issue, not a failed attempt
    to close one, and denying it would make the guard something to work around.

    Nothing here requires a closing block to exist — a chore or a dependency bump
    legitimately closes nothing.
    """
    problems: list[str] = []
    warnings: list[str] = []

    for number, raw in enumerate(body.splitlines(), start=1):
        line = raw.strip().lstrip("-*+ ").lstrip("*").strip()
        if not line or not ISSUE_REFERENCE.search(line):
            continue
        head = line.split()[0]
        word = head.rstrip(":").lower()

        if word in NON_CLOSERS:
            problems.append(
                f"  line {number}: {line!r} — GitHub only acts on English keywords "
                f"(close/fix/resolve). Write 'Closes #N'."
            )
            continue
        if word not in CLOSING_KEYWORDS:
            continue

        if head.endswith(":"):
            problems.append(
                f"  line {number}: {line!r} — the colon breaks the link. "
                f"It is 'Closes #N', with nothing between the keyword and the number."
            )
            continue
        references = ISSUE_REFERENCE.findall(line)
        if len(references) > 1:
            problems.append(
                f"  line {number}: {line!r} — only {references[0]} would close. "
                f"The keyword has to be repeated: one 'Closes #N' per line."
            )
            continue
        if word != HOUSE_CLOSER:
            warnings.append(
                f"  line {number}: '{head}' works, but the house form is 'Closes'."
            )

    return problems, warnings


def gh_api_is_write(args: list[str]) -> bool:
    method = ""
    has_field = False
    for index, arg in enumerate(args):
        if arg in WRITE_API_FLAGS and index + 1 < len(args):
            method = args[index + 1].upper()
        elif arg.startswith("--method="):
            method = arg.split("=", 1)[1].upper()
        elif arg.split("=", 1)[0] in API_FIELD_FLAGS:
            has_field = True
    if method in WRITE_METHODS:
        return True
    # An explicit read method wins: `gh api -X GET x -f a=b` sends the fields as query
    # parameters. Anything else with a field is a POST, including every graphql call.
    return has_field and method not in ("GET", "HEAD")


def check_worker(toks: list[str]) -> None:
    if invocations(toks, "gh"):
        emit("deny", WORKER_DENY)
    for args in invocations(toks, "git"):
        subcommand, _ = git_subcommand(args)
        if subcommand in ("push", "remote", "request-pull", "send-email"):
            emit("deny", WORKER_DENY)


def check_orchestrator(toks: list[str], branch: str, cwd: str) -> None:
    for args in invocations(toks, "gh"):
        verb = gh_positional(args)[:2]

        if verb[:2] == ["pr", "create"]:
            problems, warnings = closing_line_problems(pr_body(args, cwd))
            if problems:
                emit("deny", PR_BODY_DENY + "\n".join(problems))
            emit("ask", PR_ASK + ("\n\n" + "\n".join(warnings) if warnings else ""))
        if verb[:2] in (["pr", "merge"], ["pr", "close"], ["issue", "delete"]):
            emit(
                "deny",
                "Merging and closing are the human's call. Report the state and let them decide.",
            )
        if verb[:1] == ["repo"] and len(verb) > 1 and verb[1] in ("delete", "archive", "rename"):
            emit("deny", "Repository-level operations are never an agent's to make.")
        if verb[:1] == ["api"] and gh_api_is_write(args):
            emit(
                "deny",
                "`gh api` writes bypass the PR rules — and it sends POST as soon as you "
                "pass -f/-F, with no -X needed, which is also every graphql call. Use a "
                "read-only REST call, or ask the human to perform the write.",
            )

    for args in invocations(toks, "git"):
        subcommand, rest = git_subcommand(args)
        if subcommand == "push" and pushes_to_protected(rest, branch):
            emit(
                "deny",
                f"Never push to a protected branch (you are on '{branch or 'an unknown branch'}'; "
                f"protected: {', '.join(sorted(PROTECTED_BRANCHES))}). "
                "Push the feature branch by name; the human merges it.",
            )


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    if payload.get("tool_name") != "Bash":
        sys.exit(0)

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not command.strip():
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()
    branch = branch_of(cwd)
    role = resolve_role(branch)
    if role == "off":
        sys.exit(0)

    for toks in token_streams(command):
        if role == "worker":
            check_worker(toks)
        check_orchestrator(toks, branch, cwd)
    sys.exit(0)


if __name__ == "__main__":
    main()
