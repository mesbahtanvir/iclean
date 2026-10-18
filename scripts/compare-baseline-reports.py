#!/usr/bin/env python3
"""Lines up baseline reports from different devices.

    scripts/compare-baseline-reports.py Fixtures/baseline-reports/*.json

Each report is one column. A check that differs between devices is marked with '*', so a
device that behaves differently from the rest stands out. Exits 1 if any report failed.
"""
import json
import sys

if len(sys.argv) < 2:
    sys.exit(__doc__)
reports = []
for path in sys.argv[1:]:
    r = json.load(open(path))
    d = r["device"]
    os_version = d["osVersion"].split("(")[0].replace("Version ", "").strip()
    r["_label"] = f'{d["platform"]} {os_version} {d["model"]}{" sim" if d["isSimulator"] else ""}'
    reports.append(r)

ids = []
for r in reports:
    for c in r["checks"]:
        if c["id"] not in ids:
            ids.append(c["id"])
width = max(len(i) for i in ids) + 2
labels = [r["_label"][:19] for r in reports]
print(" " * (width + 2) + "".join(f"{l:<20}" for l in labels))
for i in ids:
    cells = []
    for r in reports:
        c = next((c for c in r["checks"] if c["id"] == i), None)
        cells.append(c["status"].upper() if c else "-")
    flag = "*" if len(set(cells)) > 1 else " "
    print(f"{flag} {i:<{width}}" + "".join(f"{c:<20}" for c in cells))

print()
print(" " * (width + 2) + "".join(f"{l:<20}" for l in labels))
for key in ["scanSeconds", "itemsPerSecond", "resultsSeconds", "importSeconds"]:
    row = [r["timings"].get(key) for r in reports]
    if any(v is not None for v in row):
        print(f"  {key:<{width}}" + "".join(f'{("%.1f" % v) if v is not None else "-":<20}' for v in row))
row = []
for r in reports:
    m = r.get("metrics", {})
    row.append(f'{int(m["informational.caught"])}/{int(m["informational.total"])}'
               if "informational.total" in m else "-")
print(f"  {'borderline caught':<{width}}" + "".join(f"{c:<20}" for c in row))
for key in ["featurePrints", "screenshotsTaggedBySystem", "localPreviews", "addedDates"]:
    print(f"  {key:<{width}}" + "".join(f'{r["capabilities"].get(key, "-")[:18]:<20}' for r in reports))
print(f"  {'OS':<{width}}" + "".join(f'{r["device"]["osVersion"].split("(")[0].replace("Version ", "")[:18]:<20}' for r in reports))
print(f"  {'memory MB':<{width}}" + "".join(f'{r["device"]["physicalMemoryMB"]:<20}' for r in reports))
failed = [r["_label"] for r in reports if any(c["status"] == "fail" for c in r["checks"])]
print()
print("ALL PASS" if not failed else "FAILED: " + ", ".join(failed))
sys.exit(1 if failed else 0)
