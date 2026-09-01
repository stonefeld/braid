#!/usr/bin/env python3
"""Find expansions that run straight into a multibyte character.

bash 3.2 reads the bytes of the following character as part of the variable name, so an
expansion written straight against an ellipsis fails at runtime with "unbound variable" —
on macOS, on whichever line happens to have one. Braces fix it.  compat-ignore

A line carrying `compat-ignore` is exempt, which this file's own docstring needs.
"""

import pathlib
import re
import sys

PATTERN = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
ROOTS = ("bin", "lib", "test", "install.sh")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    found = []
    for name in ROOTS:
        path = root / name
        files = [path] if path.is_file() else sorted(path.rglob("*"))
        for f in files:
            if not f.is_file():
                continue
            try:
                text = f.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for number, line in enumerate(text.splitlines(), start=1):
                if "compat-ignore" in line or not PATTERN.search(line):
                    continue
                found.append(f"{f.relative_to(root)}:{number}: {line.strip()[:88]}")
    if found:
        print("\n".join(found))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
