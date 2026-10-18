# bench30k: scale measurements behind spec 004

A command-line program that builds a synthetic library of up to 30,000 stored items and
times the real `CleanupKit` code on it: the results build, each detector, the store,
the planner, and the analyzer. It produced every "measured" number in
[`../../research.md`](../../research.md). Nothing here ships in the app.

```bash
swift build -c release                      # builds against ../../../../Packages/CleanupKit
.build/release/bench30k pool count=1000 out=pool.bin   # real Vision feature prints, once
./run_all.sh                                # Release cases, writes results-release.log
./run_debug.sh                              # Debug cases (very slow), writes results-debug.log
```

`results-release.log` and `results-debug.log` are the logs the spec cites. They come from
one Apple M4 Max Mac (14 cores, 36 GB) and synthetic data, not from a phone.

What it copies instead of importing: `ScanPlanner.plan`, `HashIndex` and the detector set in
`iclean/App/Detectors.swift`, because they are not public. If those change, update the copy
before trusting a new run. Task T003 in `tasks.md` turns this into a maintained target.

The logs were produced before the Duplicate Videos detector was removed from the app
(2026-10-18, 004 FR-004a). The detector set here no longer includes it; the removed detector
took about 1 ms at 30,000 items, so the logged build times stay representative.
