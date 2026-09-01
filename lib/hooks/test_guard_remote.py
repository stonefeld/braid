#!/usr/bin/env python3
"""Cases the guard has to get right.

Not a pytest suite: the hooks have to run in a repository that has no test runner at
all. Plain python3, no dependencies, exit code is the verdict.

Each case is (role, command, expected decision). "allow" means the guard stays out of
the way and the normal permission flow decides.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK = Path(__file__).with_name("guard_remote.py")

# Assembled at runtime so this file's own text cannot trip a guard reading it.
GH = "g" + "h"
PUSH = "pu" + "sh"

CASES = [
    # --- worker: no GitHub, no remote, in any spelling ------------------------------
    ("worker", f"{GH} issue view 1", "deny"),
    ("worker", f"{GH} pr list", "deny"),
    ("worker", f'bash -c "{GH} pr create"', "deny"),
    ("worker", f"sh -lc '{GH} pr create'", "deny"),
    ("worker", f'eval "{GH} pr create"', "deny"),
    ("worker", f"cd /tmp && {GH} pr list", "deny"),
    ("worker", f"GH_TOKEN=x {GH} pr list", "deny"),
    ("worker", f"/opt/homebrew/bin/{GH} pr create", "deny"),
    ("worker", f"git {PUSH}", "deny"),
    ("worker", "git remote add upstream x", "deny"),
    # ... but reading and writing locally is the whole job
    ("worker", f"grep -rn {GH} docs/", "allow"),
    ("worker", "git fetch origin", "allow"),
    ("worker", "git commit -m 'fix(x): use the API'", "allow"),
    ("worker", f'git commit -m "revert: git {PUSH} to main"', "allow"),
    ("worker", "npm test", "allow"),
    ("worker", "pytest -x", "allow"),
    # --- orchestrator: PRs ask, merges and closes are denied ------------------------
    ("orchestrator", f"{GH} pr create --fill", "ask"),
    ("orchestrator", f"{GH} pr create --title x --body y", "ask"),
    ("orchestrator", f"{GH} pr merge 211", "deny"),
    ("orchestrator", f"{GH} pr close 211", "deny"),
    ("orchestrator", f"{GH} issue delete 211", "deny"),
    ("orchestrator", f"{GH} repo delete o/r", "deny"),
    ("orchestrator", f"{GH} issue view 211 --comments", "allow"),
    ("orchestrator", f"{GH} issue list --state open", "allow"),
    # --- orchestrator: the closing block has to actually close ----------------------
    # deal-breakers: every one of these looks like it worked and closes nothing
    ("orchestrator", f"{GH} pr create --body 'Cierra #263'", "deny"),
    ("orchestrator", f"{GH} pr create --body 'Corrige #295 y #296'", "deny"),
    ("orchestrator", f"{GH} pr create --body 'Closes #1, #2'", "deny"),
    ("orchestrator", f"{GH} pr create --body 'Closes #1 and #2'", "deny"),
    ("orchestrator", f"{GH} pr create --body 'Closes: #1'", "deny"),
    ("orchestrator", f"{GH} pr create --body 'Closes #1\nCierra #2'", "deny"),
    ("orchestrator", f"{GH} pr create --body='Closes #1, #2'", "deny"),
    ("orchestrator", f"{GH} pr create --body-file pr.md", "deny", "feat/x", {"pr.md": "Cierra #263\n"}),
    # ... and the shapes that are fine, which must stay merely "ask"
    ("orchestrator", f"{GH} pr create --body 'Closes #1'", "ask"),
    ("orchestrator", f"{GH} pr create --body 'Closes #1\nCloses #2\n\n## Why\n'", "ask"),
    ("orchestrator", f"{GH} pr create --body 'Fixes #1'", "ask"),  # valid, warned about
    ("orchestrator", f"{GH} pr create --body 'chore(deps): bump x'", "ask"),  # closes nothing
    ("orchestrator", f"{GH} pr create --body-file pr.md", "ask", "feat/x", {"pr.md": "Closes #1\n"}),
    ("orchestrator", f"{GH} pr create --body-file missing.md", "ask"),
    # prose about an issue is not a failed attempt to close one
    ("orchestrator", f"{GH} pr create --body 'This does not fix #295 yet'", "ask"),
    ("orchestrator", f"{GH} pr create --body 'Follow-up to the PRD #182 (later batch)'", "ask"),
    # a body the guard cannot expand must not be judged on the substitution
    ("orchestrator", f"{GH} pr create --body \"$(cat <<'EOF'\nCierra #263\nEOF\n)\"", "ask"),
    # --- orchestrator: gh api sends POST as soon as a field appears -----------------
    ("orchestrator", f"{GH} api -X DELETE repos/o/r", "deny"),
    ("orchestrator", f"{GH} api --method POST repos/o/r", "deny"),
    ("orchestrator", f"{GH} api --method=PATCH repos/o/r", "deny"),
    ("orchestrator", f"{GH} api repos/o/r/pulls/1/merge -f merge_method=squash", "deny"),
    ("orchestrator", f"{GH} api repos/o/r/issues/1/comments -F body=@note.md", "deny"),
    ("orchestrator", f"{GH} api graphql -f query=mutation_mergePullRequest", "deny"),
    ("orchestrator", f"{GH} api --field state=closed repos/o/r/issues/1", "deny"),
    ("orchestrator", f"{GH} api repos/o/r/pulls/1", "allow"),
    ("orchestrator", f"{GH} api -X GET search/issues -f q=braid", "allow"),
    # --- orchestrator: pushing the trunk, in the forms people actually use ----------
    ("orchestrator", f"git {PUSH} origin master", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} -u origin main", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} --force origin main", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} origin HEAD:master", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} origin +master", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} origin refs/heads/master", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} --delete origin master", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} --all origin", "deny", "feat/x"),
    ("orchestrator", f"git {PUSH} --mirror origin", "deny", "feat/x"),
    # bare push takes whatever is checked out
    ("orchestrator", f"git {PUSH}", "deny", "master"),
    ("orchestrator", f"git {PUSH} origin", "deny", "main"),
    ("orchestrator", f"git -C /somewhere {PUSH}", "deny", "master"),
    ("orchestrator", f"git checkout master && git {PUSH}", "deny", "master"),
    # unreadable branch + no refspec: the destination is unknowable, so fail closed
    ("orchestrator", f"git {PUSH}", "deny", ""),
    ("orchestrator", f"git {PUSH} origin feat/x", "allow", ""),
    # the feature branch is the whole point — it must stay pushable
    ("orchestrator", f"git {PUSH}", "allow", "feat/x"),
    ("orchestrator", f"git {PUSH} -u origin feat/x", "allow", "feat/x"),
    ("orchestrator", f"git {PUSH} origin master:feat/x", "allow", "feat/x"),
    ("orchestrator", f"git {PUSH} origin feat/main-menu", "allow", "feat/main-menu"),
    ("orchestrator", f"git {PUSH} -o ci.skip origin feat/x", "allow", "feat/x"),
    # --- text that merely mentions a command is not a command ----------------------
    ("orchestrator", f'echo "git {PUSH} origin master"', "allow", "feat/x"),
    ("orchestrator", f"git commit -m 'git {PUSH} origin master'", "allow", "feat/x"),
    ("orchestrator", f"grep -rn '{GH} pr merge' docs/", "allow"),
    # --- the escape hatch ----------------------------------------------------------
    ("off", f"{GH} pr merge 211", "allow"),
]

# The generalized parts: the role comes from the branch prefix, and what counts as
# protected is configuration. Neither may be hardcoded — a project whose trunk is
# `develop` and whose workers live under `bot/` has to get the same protection.
ENV_CASES = [
    # role derived from the branch, with the default prefix
    ({}, f"{GH} pr list", "deny", "agent/3-x"),
    ({}, f"{GH} pr list", "allow", "feat/x"),
    # ... and with a custom one
    ({"BRAID_BRANCH_PREFIX": "bot"}, f"{GH} pr list", "deny", "bot/3-x"),
    ({"BRAID_BRANCH_PREFIX": "bot"}, f"{GH} pr list", "allow", "agent/3-x"),
    # a project whose trunk is not called main
    ({"BRAID_PROTECTED_BRANCHES": "develop"}, f"git {PUSH} origin develop", "deny", "feat/x"),
    ({"BRAID_PROTECTED_BRANCHES": "develop"}, f"git {PUSH} origin main", "allow", "feat/x"),
    ({"BRAID_PROTECTED_BRANCHES": "main develop"}, f"git {PUSH}", "deny", "develop"),
]


_REPOS: dict[str, str] = {}


def repo_on(branch: str) -> str:
    """A throwaway git repo checked out on `branch`.

    The guard reads the branch off the filesystem, so the test gives it a real one to
    read rather than a seam in the hook that would double as a way around it.
    """
    if branch not in _REPOS:
        path = tempfile.mkdtemp(prefix="guard-test-")
        if not branch:  # not a git repo at all — the guard cannot read a branch
            _REPOS[branch] = path
            return path
        run = lambda *a: subprocess.run(["git", "-C", path, *a], check=True, capture_output=True)
        run("init", "-q", "-b", branch)
        run("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x")
        _REPOS[branch] = path
    return _REPOS[branch]


def decide(
    command: str,
    branch: str,
    files: dict[str, str] | None = None,
    env_extra: dict[str, str] | None = None,
) -> str:
    env = dict(os.environ)
    env.pop("BRAID_AGENT_ROLE", None)
    env.pop("BRAID_BRANCH_PREFIX", None)
    env.pop("BRAID_PROTECTED_BRANCHES", None)
    env.update(env_extra or {})
    cwd = repo_on(branch)
    for name, content in (files or {}).items():
        Path(cwd, name).write_text(content, encoding="utf-8")
    payload = json.dumps({"tool_name": "Bash", "cwd": cwd, "tool_input": {"command": command}})
    result = subprocess.run(
        [sys.executable, str(HOOK)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )
    if result.returncode != 0:
        return f"crash({result.stderr.strip().splitlines()[-1:]})"
    if not result.stdout.strip():
        return "allow"
    return json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"]


def main() -> int:
    failures = 0
    total = 0

    for case in CASES:
        role, command, expected = case[0], case[1], case[2]
        branch = case[3] if len(case) > 3 else "feat/x"
        files = case[4] if len(case) > 4 else None
        actual = decide(command, branch, files, {"BRAID_AGENT_ROLE": role})
        for name in files or ():
            Path(repo_on(branch), name).unlink(missing_ok=True)
        total += 1
        label = command.replace("\n", "\\n")
        if actual == expected:
            print(f"  ok    {expected:6} {label}")
        else:
            failures += 1
            print(f"  FAIL  want {expected}, got {actual}: {label}")

    for env_extra, command, expected, branch in ENV_CASES:
        actual = decide(command, branch, None, env_extra)
        total += 1
        label = f"[{branch}] {command}" + (f" {env_extra}" if env_extra else "")
        if actual == expected:
            print(f"  ok    {expected:6} {label}")
        else:
            failures += 1
            print(f"  FAIL  want {expected}, got {actual}: {label}")

    for path in _REPOS.values():
        shutil.rmtree(path, ignore_errors=True)
    print(f"\n{total - failures}/{total} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
