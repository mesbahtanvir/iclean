#!/usr/bin/env python3
"""Splits the UI tests into shards for a CI matrix, so each runs on its own simulator at once.

    scripts/ui-test-shards.py [--shards 4] [--dir icleanUITests]          # the matrix, as JSON
    scripts/ui-test-shards.py --table                                     # the plan, as Markdown

Every XCTestCase class in the folder lands in exactly one shard unless it is listed in EXCLUDED with the
reason, so a class that is added is run without anyone editing a workflow, and one that is renamed or
deleted without its exclusion being updated fails the plan rather than going quiet.

The matrix is `{"include": [{"shard": 1, "classes": "A B C", "tests": 12}, ...]}`.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Classes that are not part of the shards, and where they run instead.
EXCLUDED = {
    "ScreenshotTour": "its own job: it saves a PNG of every screen in four looks",
    "NoNetworkFlowTests": "its own job: the NoNetwork test plan (it needs -NetworkTripwire)",
    "ScrollPerformanceTests": "a measurement, run on request (it needs SCROLL_PERF=1)",
}

CLASS = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", re.MULTILINE)
TEST = re.compile(r"^\s*func\s+(test\w*)\s*\(", re.MULTILINE)


def discover(folder: Path):
    """{class name: number of test methods}, from the Swift files of a folder."""
    found = {}
    for path in sorted(folder.glob("*.swift")):
        text = path.read_text(encoding="utf-8")
        starts = [(m.start(), m.group(1)) for m in CLASS.finditer(text)]
        for index, (start, name) in enumerate(starts):
            end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
            found[name] = len(TEST.findall(text[start:end]))
    return found


def plan(classes: dict, shards: int):
    """Returns (shards, problems). A shard is {"classes": [names], "tests": n}. Heaviest class first
    into the lightest shard, so the shards come out about as long as each other."""
    problems = [
        f"{name} is excluded ({reason}) but no such test class exists"
        for name, reason in sorted(EXCLUDED.items())
        if name not in classes
    ]
    included = {name: count for name, count in classes.items() if name not in EXCLUDED}
    shards = max(1, min(shards, len(included) or 1))
    result = [{"classes": [], "tests": 0} for _ in range(shards)]
    for name in sorted(included, key=lambda n: (-included[n], n)):
        lightest = min(result, key=lambda s: (s["tests"], len(s["classes"])))
        lightest["classes"].append(name)
        lightest["tests"] += included[name]
    for shard in result:
        shard["classes"].sort()
    return result, problems


def matrix(shards):
    return {
        "include": [
            {"shard": i + 1, "classes": " ".join(s["classes"]), "tests": s["tests"]}
            for i, s in enumerate(shards)
        ]
    }


def table(classes: dict, shards) -> str:
    lines = ["| Shard | Tests | Classes |", "|---:|---:|---|"]
    for i, shard in enumerate(shards, 1):
        lines.append(f"| {i} | {shard['tests']} | {', '.join(shard['classes'])} |")
    lines += ["", "Not in a shard:", ""]
    for name, reason in sorted(EXCLUDED.items()):
        if name in classes:
            lines.append(f"- `{name}` ({classes[name]} tests): {reason}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shards", type=int, default=4)
    parser.add_argument("--dir", default="icleanUITests")
    parser.add_argument("--table", action="store_true")
    args = parser.parse_args()

    classes = discover(Path(args.dir))
    if not classes:
        print(f"no XCTestCase class in {args.dir}", file=sys.stderr)
        return 1
    shards, problems = plan(classes, args.shards)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print(table(classes, shards) if args.table else json.dumps(matrix(shards)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
