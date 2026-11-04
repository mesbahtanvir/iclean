#!/usr/bin/env python3
"""Compares two `ScaleBench --real-scan` outputs, a one-pass scan and a tiered one of the same library.

    scripts/compare-bench.py one-pass.txt tiered.txt

The results digest and the analysis digest must be equal: a tiered scan finds exactly what a one-pass
scan finds. The times are only reported (a CI machine is a virtual one, and not a phone). Prints a
Markdown table and exits 1 when a digest differs or one is missing.
"""

import re
import sys

RESULTS = re.compile(r"^\s*digest ([0-9a-f]+)\s*$", re.MULTILINE)
ANALYSIS = re.compile(r"analysis digest \(without feature prints\) ([0-9a-f]+)")
SCAN = re.compile(r"scan done \((\w+)\): ([\d.]+) s\s+= (\d+) items/s")
TIERS = re.compile(
    r"tiers: photo check done at ([\d.]+) s \((\d+) items/s\), deep check compared (\d+) photos, "
    r"all done at ([\d.]+) s"
)
BUILD = re.compile(r"results build: ([\d.]+) s")


def first(pattern, text):
    match = pattern.search(text)
    return match.groups() if match else None


def digests(text: str):
    results = first(RESULTS, text)
    analysis = first(ANALYSIS, text)
    return (results[0] if results else None, analysis[0] if analysis else None)


def report(one: str, tiered: str):
    """Returns (markdown, ok)."""
    d1, d2 = digests(one), digests(tiered)
    problems = []
    for label, a, b in (("results digest", d1[0], d2[0]), ("analysis digest", d1[1], d2[1])):
        if a is None or b is None:
            problems.append(f"{label} missing ({'one-pass' if a is None else 'tiered'} output)")
        elif a != b:
            problems.append(f"{label} differs: one-pass {a}, tiered {b}")

    scan1, scan2 = first(SCAN, one), first(SCAN, tiered)
    tiers = first(TIERS, tiered)
    build1, build2 = first(BUILD, one), first(BUILD, tiered)
    rows = ["| | One pass | Tiered |", "|---|---:|---:|"]
    if scan1 and scan2:
        rows.append(f"| Whole scan | {scan1[1]} s ({scan1[2]}/s) | {scan2[1]} s ({scan2[2]}/s) |")
    if tiers:
        rows.append(f"| Photo check done | | {tiers[0]} s ({tiers[1]}/s) |")
        rows.append(f"| Deep check compared | | {tiers[2]} photos |")
    if build1 and build2:
        rows.append(f"| Results build | {build1[0]} s | {build2[0]} s |")
    rows.append(f"| Results digest | `{d1[0]}` | `{d2[0]}` |")
    rows.append(f"| Analysis digest | `{d1[1]}` | `{d2[1]}` |")
    text = "\n".join(rows)
    if problems:
        text += "\n\n**Not the same scan:** " + "; ".join(problems)
    return text, not problems


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    with open(sys.argv[1], encoding="utf-8") as one, open(sys.argv[2], encoding="utf-8") as tiered:
        text, ok = report(one.read(), tiered.read())
    print(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
