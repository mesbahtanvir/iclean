#!/usr/bin/env python3
"""Fails if a relative link in a Markdown file points at a file or folder that does not exist.

The specs link to each other and to the code (`[004](../004-phased-cleaning/spec.md)`), so a renamed
folder breaks them without anything noticing. Only relative links are checked: no network is used
(constitution II), and an anchor is not resolved, only the file it is in.

    scripts/check-doc-links.py [root]
"""

import pathlib
import re
import sys
import urllib.parse

SKIP_DIRS = {".git", ".build", "build", "DerivedData", ".swiftpm", "node_modules"}
# Templates carry placeholders such as [###-feature-name], which are not links to anything yet.
SKIP_PATHS = (".specify/templates/",)

INLINE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFERENCE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
CODE_SPAN = re.compile(r"`[^`\n]*`")


def is_external(target: str) -> bool:
    return (
        target.startswith("#")
        or "://" in target
        or target.startswith(("mailto:", "tel:", "data:"))
    )


def links_in(text: str):
    """Yields (line number, target) for every link outside code fences and code spans."""
    fenced = False
    fence = ""
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            marker = stripped[:3]
            if not fenced:
                fenced, fence = True, marker
            elif marker == fence:
                fenced = False
            continue
        if fenced:
            continue
        line = CODE_SPAN.sub("", line)
        for match in INLINE.finditer(line):
            yield number, match.group(1)
        reference = REFERENCE.match(line)
        if reference:
            yield number, reference.group(1)


def broken_links(root: pathlib.Path):
    for path in sorted(root.rglob("*.md")):
        relative = path.relative_to(root)
        if any(part in SKIP_DIRS for part in relative.parts):
            continue
        if any(str(relative).startswith(prefix) for prefix in SKIP_PATHS):
            continue
        for number, target in links_in(path.read_text(encoding="utf-8")):
            if is_external(target):
                continue
            clean = urllib.parse.unquote(target.split("#", 1)[0].split("?", 1)[0])
            if not clean:
                continue
            base = root if clean.startswith("/") else path.parent
            if not (base / clean.lstrip("/")).exists():
                yield relative, number, target


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    broken = list(broken_links(root))
    for relative, number, target in broken:
        print(f"{relative}:{number}: broken link: {target}")
    checked = sum(1 for _ in root.rglob("*.md"))
    if broken:
        print(f"{len(broken)} broken relative link(s) in Markdown files under {root.name}/")
        return 1
    print(f"all relative links resolve ({checked} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
