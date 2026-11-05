#!/usr/bin/env python3
"""Summarizes an .xcresult bundle as Markdown for a job summary: the counts, every failure with its
message, and the slowest tests.

    scripts/xcresult-summary.py path/to/Tests.xcresult
    scripts/xcresult-summary.py --json saved-test-results.json

Reads `xcrun xcresulttool get test-results tests` (Xcode 16 and later). A summary is never the reason a
job fails: when the bundle cannot be read this says so and exits 0.
"""

import json
import subprocess
import sys


def cases(nodes, path=()):
    """Yields one dict per test case in a `testNodes` tree, whatever the nesting above it."""
    for node in nodes or []:
        kind = node.get("nodeType")
        name = node.get("name", "")
        if kind == "Test Case":
            failures = [
                child.get("name", "")
                for child in node.get("children", [])
                if child.get("nodeType") == "Failure Message"
            ]
            yield {
                "suite": path[-1] if path else "",
                "name": name,
                "result": node.get("result", "Unknown"),
                "seconds": node.get("durationInSeconds"),
                "failures": failures,
            }
        else:
            yield from cases(node.get("children"), path + (name,))


def summarize(tree: dict, slowest: int = 8) -> str:
    found = list(cases(tree.get("testNodes")))
    if not found:
        return "No test cases were found in the result."
    counts = {}
    for case in found:
        counts[case["result"]] = counts.get(case["result"], 0) + 1
    order = ["Passed", "Failed", "Skipped", "Expected Failure"]
    parts = [f"{counts[k]} {k.lower()}" for k in order if k in counts]
    parts += [f"{v} {k.lower()}" for k, v in sorted(counts.items()) if k not in order]
    lines = [f"**{len(found)} tests:** " + ", ".join(parts), ""]

    failed = [c for c in found if c["result"] == "Failed"]
    if failed:
        lines += ["### Failed", ""]
        for case in failed:
            lines.append(f"- `{case['suite']}/{case['name']}`")
            for message in case["failures"][:3]:
                first = message.strip().splitlines()[0] if message.strip() else ""
                lines.append(f"  - {first}")
        lines.append("")

    timed = sorted((c for c in found if c["seconds"] is not None), key=lambda c: -c["seconds"])
    if timed:
        lines += ["### Slowest", "", "| Test | Seconds | Result |", "|---|---:|---|"]
        for case in timed[:slowest]:
            lines.append(
                f"| `{case['suite']}/{case['name']}` | {case['seconds']:.1f} | {case['result']} |"
            )
    return "\n".join(lines)


def read_bundle(path: str) -> dict:
    out = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(out.stdout)


def main() -> int:
    args = sys.argv[1:]
    try:
        if args[:1] == ["--json"]:
            with open(args[1], encoding="utf-8") as handle:
                tree = json.load(handle)
        else:
            tree = read_bundle(args[0])
    except (IndexError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"The test result could not be read ({type(error).__name__}).")
        return 0
    print(summarize(tree))
    return 0


if __name__ == "__main__":
    sys.exit(main())
