#!/usr/bin/env python3
"""Turns the JSON that `swift test --enable-code-coverage` writes (llvm-cov export) into a Markdown table.

    scripts/coverage-summary.py path/to/CleanupKit.json [--prefix Sources/CleanupKit/] [--min 0]

Lists the files under the prefix, the least covered first, then the total. With --min N it exits 1 when
the total line coverage is below N percent, so a job can fail on a drop; the default (0) only reports.
"""

import argparse
import json
import sys


def summarize(export: dict, prefix: str):
    """Returns (rows, covered, count) for the files whose path contains `prefix`."""
    rows = []
    covered = count = 0
    for data in export.get("data", []):
        for entry in data.get("files", []):
            name = entry["filename"]
            if prefix not in name:
                continue
            lines = entry["summary"]["lines"]
            rows.append((name.split(prefix, 1)[1], lines["covered"], lines["count"]))
            covered += lines["covered"]
            count += lines["count"]
    rows.sort(key=lambda row: (row[1] / row[2] if row[2] else 1.0, row[0]))
    return rows, covered, count


def percent(covered: int, count: int) -> float:
    return 100.0 * covered / count if count else 100.0


def table(rows, covered: int, count: int) -> str:
    out = ["| File | Lines | Covered |", "|---|---:|---:|"]
    for name, hit, total in rows:
        out.append(f"| `{name}` | {total} | {percent(hit, total):.1f}% |")
    out.append(f"| **Total** | **{count}** | **{percent(covered, count):.1f}%** |")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("export")
    parser.add_argument("--prefix", default="Sources/CleanupKit/")
    parser.add_argument("--min", type=float, default=0.0)
    args = parser.parse_args()
    with open(args.export, encoding="utf-8") as handle:
        rows, covered, count = summarize(json.load(handle), args.prefix)
    if not rows:
        print(f"no files under {args.prefix} in {args.export}", file=sys.stderr)
        return 1
    print(table(rows, covered, count))
    if percent(covered, count) < args.min:
        print(
            f"\nLine coverage {percent(covered, count):.1f}% is below the minimum {args.min:.1f}%",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
