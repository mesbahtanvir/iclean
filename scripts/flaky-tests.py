#!/usr/bin/env python3
"""Reads the XCTest results of one or more xcodebuild logs, in the order they were made.

    scripts/flaky-tests.py build/shard-1.log build/shard-1-rerun1.log      # the flaky ones, as Markdown
    scripts/flaky-tests.py --failing build/shard-1.log build/shard-1-rerun1.log   # `Class/test`, one per line

XCTest prints `Test Case '-[Class test]' passed|failed (1.2 seconds).` for every attempt. A test that
failed and then passed is flaky; one whose last attempt failed is failing, and is what a rerun is for.
The report prints a GitHub warning per flaky test and always exits 0: a report is never the reason a job
fails.
"""

import re
import sys

ATTEMPT = re.compile(r"Test Case '-\[([\w.]+) (\w+)\]' (passed|failed) \(")


def attempts(log: str):
    """{'Class/test': ['failed', 'passed', ...]} in the order the attempts happened."""
    found = {}
    for match in ATTEMPT.finditer(log):
        name = f"{match.group(1).split('.')[-1]}/{match.group(2)}"
        found.setdefault(name, []).append(match.group(3))
    return found


def flaky(log: str):
    """The tests that failed at least once and passed in the end, with how many tries it took."""
    return {
        name: len(results)
        for name, results in attempts(log).items()
        if "failed" in results and results[-1] == "passed"
    }


def failing(log: str):
    """The tests whose last attempt failed, sorted."""
    return sorted(name for name, results in attempts(log).items() if results[-1] == "failed")


def report(log: str) -> str:
    tests = flaky(log)
    if not tests:
        return ""
    lines = ["### Flaky tests (failed, then passed on a retry)", ""]
    lines += [f"- `{name}` took {tries} tries" for name, tries in sorted(tests.items())]
    return "\n".join(lines)


def read(paths) -> str:
    """The logs one after the other; one that cannot be read is skipped."""
    text = []
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text.append(handle.read())
        except OSError:
            continue
    return "\n".join(text)


def main() -> int:
    args = sys.argv[1:]
    only_failing = False
    if args[:1] == ["--failing"]:
        only_failing, args = True, args[1:]
    if not args:
        print(__doc__)
        return 2
    log = read(args)
    if only_failing:
        for name in failing(log):
            print(name)
        return 0
    text = report(log)
    if text:
        print(text)
        for name in sorted(flaky(log)):
            print(f"::warning::{name} is flaky: it failed and then passed on a retry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
