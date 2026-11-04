#!/usr/bin/env python3
"""Picks the iPhone simulator a CI job should test on, from `xcrun simctl list devices available -j`.

The runner image decides which devices exist, so nothing here names one the job cannot do without. The
newest iOS runtime wins; on it, the first of the preferred names that exists, else any iPhone.

    xcrun simctl list devices available -j | scripts/pick-simulator.py

Prints `udid=<id>` and `name=<name>` lines, ready to append to $GITHUB_OUTPUT. Exits 1 when no iPhone
simulator is available.
"""

import json
import re
import sys

PREFERRED = ["iPhone 17 Pro", "iPhone 17", "iPhone 16 Pro", "iPhone 16"]


def runtime_version(identifier: str):
    """'com.apple.CoreSimulator.SimRuntime.iOS-26-1' -> (26, 1); None for anything not iOS."""
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", identifier)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("-"))


def pick(listing: dict):
    runtimes = []
    for identifier, devices in listing.get("devices", {}).items():
        version = runtime_version(identifier)
        if version is None:
            continue
        phones = [
            d for d in devices if d.get("isAvailable", True) and d.get("name", "").startswith("iPhone")
        ]
        if phones:
            runtimes.append((version, phones))
    if not runtimes:
        return None
    _, phones = max(runtimes, key=lambda pair: pair[0])
    by_name = {d["name"]: d for d in phones}
    for name in PREFERRED:
        if name in by_name:
            return by_name[name]
    return sorted(phones, key=lambda d: d["name"])[0]


def main() -> int:
    chosen = pick(json.load(sys.stdin))
    if chosen is None:
        print("no available iPhone simulator", file=sys.stderr)
        return 1
    print(f"udid={chosen['udid']}")
    print(f"name={chosen['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
