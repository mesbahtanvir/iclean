#!/usr/bin/env python3
"""Summarizes JUnit XML test reports as Markdown for a job summary: the counts, every failure with its
message, every test that was skipped, and the slowest tests.

    swift test --xunit-output report.xml
    scripts/junit-summary.py report.xml report-swift-testing.xml

SwiftPM writes one report for XCTest and, beside it, `<name>-swift-testing.xml` for Swift Testing; both
are read. A summary is never the reason a job fails: a file that cannot be read is said so and the rest
are summarized (exit 0). With `--require N` it exits 1 when fewer than N tests ran, which catches a
filter that matched nothing.
"""

import sys
import xml.etree.ElementTree as ET


def cases(path: str):
    """Yields (suite, name, seconds, status, message) for each test case in a report."""
    root = ET.parse(path).getroot()
    for case in root.iter("testcase"):
        status, message = "passed", ""
        for child in case:
            if child.tag in ("failure", "error"):
                status = "failed"
                message = child.get("message") or (child.text or "").strip()
            elif child.tag == "skipped" and status != "failed":
                status = "skipped"
                message = child.get("message") or ""
        try:
            seconds = float(case.get("time") or 0)
        except ValueError:
            seconds = 0.0
        yield case.get("classname", ""), case.get("name", ""), seconds, status, message


def summarize(paths, slowest: int = 8):
    """Returns (markdown, number of tests, number of failures)."""
    found, unreadable = [], []
    for path in paths:
        try:
            found += list(cases(path))
        except (OSError, ET.ParseError):
            unreadable.append(path)
    notes = [f"The report {p} could not be read." for p in unreadable]
    if not found:
        return "\n".join(["No test cases were found in the reports."] + notes), 0, 0

    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for _, _, _, status, _ in found:
        counts[status] += 1
    parts = [f"{n} {status}" for status, n in counts.items() if n]
    lines = [f"**{len(found)} tests:** " + ", ".join(parts), ""] + notes

    failed = [c for c in found if c[3] == "failed"]
    if failed:
        lines += ["### Failed", ""]
        for suite, name, _, _, message in failed:
            lines.append(f"- `{suite}/{name}`")
            first = message.strip().splitlines()[0] if message.strip() else ""
            if first:
                lines.append(f"  - {first}")
        lines.append("")

    skipped = [c for c in found if c[3] == "skipped"]
    if skipped:
        lines += ["### Skipped", ""]
        for suite, name, _, _, message in skipped:
            lines.append(f"- `{suite}/{name}`" + (f": {message}" if message else ""))
        lines.append("")

    timed = sorted(found, key=lambda c: -c[2])[:slowest]
    if timed and timed[0][2] > 0:
        lines += ["### Slowest", "", "| Test | Seconds |", "|---|---:|"]
        lines += [f"| `{suite}/{name}` | {seconds:.2f} |" for suite, name, seconds, _, _ in timed]
    return "\n".join(lines), len(found), len(failed)


def main() -> int:
    args = sys.argv[1:]
    required = 0
    if args[:1] == ["--require"] and len(args) >= 2:
        required, args = int(args[1]), args[2:]
    if not args:
        print(__doc__)
        return 2
    text, total, _ = summarize(args)
    print(text)
    if total < required:
        print(f"\n**Only {total} tests ran; at least {required} were expected.**")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
