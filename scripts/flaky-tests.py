#!/usr/bin/env python3
"""Lists the tests that failed and then passed in an xcodebuild log: a retry made them pass.

    scripts/flaky-tests.py build/shard-1.log

XCTest prints `Test Case '-[Class test]' passed|failed (1.2 seconds).` for every attempt. A test with
both is flaky; one with only failures failed for good (and the build already failed for it). Prints a
Markdown list and a GitHub warning per flaky test, and always exits 0: a report is never the reason a
job fails.
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


def report(log: str) -> str:
    tests = flaky(log)
    if not tests:
        return ""
    lines = ["### Flaky tests (failed, then passed on a retry)", ""]
    lines += [f"- `{name}` took {tries} tries" for name, tries in sorted(tests.items())]
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
            log = handle.read()
    except OSError:
        return 0
    text = report(log)
    if text:
        print(text)
        for name in sorted(flaky(log)):
            print(f"::warning::{name} is flaky: it failed and then passed on a retry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
