# Baseline photo library

A fixed set of 73 small photos and videos with known expected results. Run it on any
device or simulator to check that iclean finds the same duplicates, similar shots, blurry
photos, screenshots and large videos there as everywhere else. Videos are never analyzed (004
FR-004a, 016), so for videos it checks the size ranking and that no video was analyzed.

Nothing is stored in the repository. Every asset is drawn from a recipe, so every device
produces the same pixels, and the expected result for each asset is written next to its
recipe in `BaselineCatalogV4.swift`.

## What it checks

| Group | Assets | Expected result |
|---|---|---|
| Duplicate photos | 9 groups, 22 photos | Each group found exactly; the suggested keeper is the expected one: a favorite, else the copy with a possible date, else the highest resolution |
| Copies that differ in date, location or a default date | 3 of those groups (6 photos) | The same image dated years apart (the earlier date is kept, although the later copy is the larger file), exact copies of which one lost its location (the one with it is kept), and a larger copy dated 1 Jan 1970 (the smaller copy with a real date is kept) |
| Controls for duplicates | 2 crops, 3 low-detail skies | Never grouped |
| Similar shots | 3 bursts (4, 3 and 5 frames) and 1 decoy | Each burst found exactly; the decoy is left out |
| Blurry photos | 6 out-of-focus photos | All flagged |
| Borderline blur | 2 camera-shake photos | Reported per device, never asserted |
| Screenshots | 4 PNGs tagged as screenshots | Listed, where the system tags them |
| Videos | 2 copies of one clip and 3 unrelated clips | Never analyzed; all five are listed under Large Videos by size, largest first, none pre-selected, and the copies are not grouped |
| Unrelated photos | 16 sharp, different photos | Never flagged by anything |

The checks also cover that import keeps capture dates, pixel sizes, favorites, album
membership and locations, that every photo is analyzed from a local preview, that videos are stored by
metadata only, that favorites are never selected for removal, and that flagged items start
selected while keepers do not.

Precision and recall for duplicates, similar shots and blurry photos are saved in the report as metrics.

## Run it

On the Mac, with no Photos library involved. This is where the expectations are calibrated:

```bash
swift test --package-path Packages/CleanupKit --filter BaselineHostTests
```

On a simulator:

```bash
scripts/run-baseline.sh sim "iPhone 17 Pro"
```

On a connected iPhone or iPad, using its UDID from `xcrun devicectl list devices`:

```bash
DEVELOPMENT_TEAM=<team id> scripts/run-baseline.sh device <UDID>
```

The script builds the Debug app, installs it, adds the baseline assets to the Photos
library, scans only those through the real pipeline, copies the report to
`Fixtures/baseline-reports/` and exits 0 on pass, 1 on fail and 2 if it could not run.
`--no-build` reuses the installed app.

The first run on a device or simulator asks for Photos access, even after a privacy grant
from the command line. Tap **Allow Full Access** once. On a phone, unlock it first. The
answer is remembered.

You can also run it by hand: Settings, then **Baseline Library (Debug)**, in a Debug build.

## Compare devices

```bash
scripts/compare-baseline-reports.py Fixtures/baseline-reports/*.json
```

Each report is a column. A check whose result differs between devices is marked with `*`.
The table also shows scan speed, how many borderline photos were caught, whether the
system tagged the screenshots, whether Vision feature prints were available, whether the
system gave the date each photo was added to the library (iOS 26 and later; date-aware keepers
use it), and the
operating system and memory of each device.

## Photos library effects

- The assets go into an album called **iclean Baseline**, plus **iclean Baseline Trip** for
  one duplicate group, so they can be found and removed as a set.
- With iCloud Photos on, they sync to the account like any photo. Use a test library, or
  remove them afterwards.
- Running again adds only what is missing. Assets are recognised by their file name, which
  starts with `BASE` and the catalog version (`BASE4_` for the current version 4). A new catalog version
  therefore imports fresh assets; the older ones stay in the album until you remove them.
- Removal goes through the system confirmation and moves the assets to Recently Deleted:

```bash
scripts/run-baseline.sh --remove sim "iPhone 17 Pro"
```

On a device, use **Remove Baseline Photos** in the Baseline Library screen.

## Reading the results

- **Fail on every device**: the app changed. Check the failing asset ids in the report.
- **Fail on one device**: that device differs. Compare the reports and look at the
  capabilities row first. The iOS simulator, for one, has no Vision feature prints, so
  similar shots there rely on the pixel fingerprint and still pass.
- **Skipped**: the system did not tag the screenshots, so that check cannot run there.
- **Borderline blur**: the two camera-shake photos sit at the edge of the detector. They
  are caught on the Mac and missed in the iOS simulator. The count is a number to watch
  when the blur check is improved, not a pass or fail.

## Changing the catalog

Edit `BaselineCatalogV4.swift`, run the host test, and only keep an expectation that holds
there. If a recipe, a date or an expectation is changed, bump the catalog version: old
reports are then not compared with new ones, and the new file names make every device import
fresh assets instead of reusing the old ones. The host test also checks that ids and file
names are unique and carry the version, that every category is covered, that each group has
one keeper, and that drawing the same recipe twice gives identical pixels.
