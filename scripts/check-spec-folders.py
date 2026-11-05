#!/usr/bin/env python3
"""Checks the shape of the Spec Kit folders under specs/, which every feature is written in.

- a folder is named `NNN-some-words` and the numbers are unique and run on from 001 without a gap;
- each has a non-empty spec.md;
- a tasks.md, when there is one, has well-formed checkboxes and no task id twice.

    scripts/check-spec-folders.py [root]
"""

import pathlib
import re
import sys

FOLDER = re.compile(r"^(\d{3})-[a-z0-9]+(?:-[a-z0-9]+)*$")
# A task line: a checkbox followed by its id. A line such as "- [P] = different files" in the notes
# is a legend, not a task.
TASK = re.compile(r"^\s*- \[(.)\]\s+(T\d{3,})\b")


def problems(root: pathlib.Path):
    specs = root / "specs"
    folders = sorted(p for p in specs.iterdir() if p.is_dir())
    numbers = []
    for folder in folders:
        match = FOLDER.match(folder.name)
        if not match:
            yield f"specs/{folder.name}: the name must look like 018-some-words"
            continue
        numbers.append(int(match.group(1)))

        spec = folder / "spec.md"
        if not spec.is_file() or not spec.read_text(encoding="utf-8").strip():
            yield f"specs/{folder.name}: spec.md is missing or empty"

        tasks = folder / "tasks.md"
        if tasks.is_file():
            seen = {}
            for number, line in enumerate(tasks.read_text(encoding="utf-8").splitlines(), 1):
                task = TASK.match(line)
                if not task:
                    continue
                mark, identifier = task.groups()
                if mark not in " xX":
                    yield f"specs/{folder.name}/tasks.md:{number}: checkbox is [{mark}], not [ ] or [X]"
                if identifier in seen:
                    yield (
                        f"specs/{folder.name}/tasks.md:{number}: {identifier} is also on "
                        f"line {seen[identifier]}"
                    )
                seen[identifier] = number

    for wanted, found in enumerate(sorted(numbers), start=1):
        if wanted != found:
            yield f"specs: numbering has a gap or a repeat at {found:03d} (expected {wanted:03d})"
            break


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if not (root / "specs").is_dir():
        print(f"{root}: no specs/ folder")
        return 1
    found = list(problems(root))
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} problem(s) in specs/")
        return 1
    count = sum(1 for p in (root / "specs").iterdir() if p.is_dir())
    print(f"specs/ is well formed ({count} folders)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
