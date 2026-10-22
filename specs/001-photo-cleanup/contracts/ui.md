# Contract: Screens and states

What the user sees. UI tests are written against these screens, states, and
accessibility identifiers. Amended by spec 011 (calm polish): the screens below are the ones
shipped after that change; the words and layouts are in `specs/011-calm-polish/spec.md`.

## Screens

| Screen | Purpose | Key elements (accessibility id) |
|--------|---------|--------------------------------|
| **Access** | Ask for Photos access; explain why; explain "everything stays on this device" | `access.allow`, `access.openSettings` (when denied) |
| **Home** | One of a few states (see below); the answer first: how much space can be freed | `home.hero`, `home.scan`, `home.resume`, `home.lastScan`, `home.settings`, `home.continue`, `home.continueDismiss`, `home.opening`, `home.limitedAccess`, `home.storeVolatile`, `home.storeUnreadable` |
| **Scanning** | A quiet status: progress, pause/resume/stop, why it is paused | `scan.status`, `scan.progress`, `scan.pause`, `scan.resume`, `scan.stop`, `scan.failed`, `scan.whenYouLeave` |
| **Results** | The hero figure, one row per category with what is selected, one pinned Review button | `results.category.<name>`, `results.reviewAll`, `results.reviewNote`, `results.notScanned`, `results.foundSoFar`, `results.showNew`, `results.updating`, `results.empty` (clean, all cleaned, empty library) |
| **Category** | Grid of groups or items with selection marks; a list for Large Videos | `category.item.<assetID>`, `category.group.<id>`, `category.selectAll`, `category.removeSelected`, `category.showNew`, `category.loading`, `category.keeperBadge`, `category.albumBadge`, `category.previewOnlyBadge` |
| **Group detail** | Side-by-side compare, change keeper | `group.compare`, `group.summary`, `group.makeKeeper`, `group.toggle.<assetID>`, `group.keeperReason.<assetID>`, `group.dateNote.<assetID>.<reason>`, `group.dateLikely.<assetID>`, `group.loading` |
| **Photo viewer** | Full screen view, zoom, play a local video, keep/remove, "always keep" | `viewer.state`, `viewer.toggleSelect`, `viewer.alwaysKeep`, `viewer.play`; the button labelled "Done" |
| **Confirm sheet** | What will move to Recently Deleted, that it can be put back, one confirm button (FR-012) | `confirm.summary`, `confirm.reassurance`, `confirm.strip`, `confirm.removeAllWarning`, `confirm.dropped`, `confirm.error`, `confirm.checking`, `confirm.footnote`, `confirm.remove`, `confirm.cancel` |
| **Done** | The receipt: removed count (or "Nothing was removed"), the honest figure, one sentence and the steps to restore, failures | `done.removed` (exactly "N item(s) removed", or "Nothing was removed" when every item failed), `done.freed`, `done.restore`, `done.howTo`, `done.icloud`, `done.failures`, `done.close` |
| **Settings** | Three rows (Recent Scans, What iclean Remembers, Restore Removed Photos), the privacy line, and Delete All iclean Data in its own section | `settings.recentScans`, `settings.savedData`, `settings.restoreHelp`, `settings.deleteAllData`, `settings.confirmDelete`, `settings.baseline` (debug builds) |
| **What iclean Remembers** | What is kept, and the tools to clear it, each with a confirmation | `saved.results`, `saved.choices`, `saved.alwaysKeep`, `saved.clearResults`, `saved.resetChoices`, `saved.confirmReset`, `saved.clearAlwaysKeep`, `saved.confirmClearAlwaysKeep`, `saved.erase`, `saved.confirmErase` |
| **Recent Scans** | Full scans one by one, quick checks folded into one line | `settings.session` (label contains the outcome, e.g. "Completed"), `recentScans.empty` |
| **Restore Removed Photos** | How long they stay, and how to put removed photos back from Recently Deleted | `restoreHelp.retention`, `restoreHelp.steps` |

Removed in 009: `results.checking` (the separate "looking for things" row) and
`settings.clearKeepMarks` (clearing Always Keep moved to What iclean Remembers).

## Home states

Resolved in this order; every state keeps the Settings gear (`home.settings`) and the notices.

1. launching (`home.opening`) → 2. failed to read saved data (only the notice) → 3. scanning or
finishing a scan, or building results (never a clean or empty claim) → 4. results (hero, rows,
Review bar) → 5. interrupted with nothing found (`home.resume`) → 6. first run (`home.scan`,
"Scan Library") → 7. empty library (`results.empty`, "No photos to check") → 8. all cleaned up
(`results.empty`) → 9. clean (`results.empty`, "Nothing to clean up").

"A full scan has finished" means a session of kind full that ran to the end; a quick check or a
stopped scan does not count.

## Mac window (spec 011 section 6.15)

The Mac is a sidebar and a detail pane, not the phone's stack. The same screens and ids apply in the
detail pane (the Overview is Home's results screen with `results.reviewAll` as an inline button), and
these are Mac only:

- Sidebar: `sidebar.overview`, `sidebar.category.<name>` (the Overview keeps `results.category.<name>`).
  The sidebar footer holds `home.lastScan` and `home.scan` (Scan Again), `home.resume`, `home.continue`,
  `results.showNew` and, while scanning with results, the scan status. While the Overview is in the
  detail pane it shows `home.continue` and `results.showNew` itself and the footer leaves them out, so
  each id is on screen once; with the sidebar hidden they are still on the Overview. While scanning
  with nothing found yet the scan card is the detail pane; its controls are in the toolbar.
- Toolbar: `toolbar.scan` (Scan Library, Scan Again), `toolbar.resume` (Resume Scan after an interrupted
  scan), and while a scan runs `scan.pause`, `scan.resume`, `scan.stop`; on a category
  `category.photoSize` (the photo-size slider: steps of 10, accessibility value "150 points") and
  `category.selectAll`. The scan count in the middle of the toolbar is shown only while the sidebar is
  hidden: the sidebar's scan card and the pane have it otherwise. The toolbar ids differ from
  `home.scan` / `home.resume` on purpose: those stay on the buttons in the detail pane and the sidebar,
  which are on screen at the same time as the toolbar, and one window must not hold two views with one
  id. The toolbar offers a scan exactly when the phone's Home would (the order above): never while the
  saved data is opening or being built, after it could not be read, or while a scan runs or finishes.
- Category: `category.removeSelected` is the button in a 40 pt status bar. Large Videos is a table with
  `category.item.<assetID>` on the Size cell of each row. Group compare uses checkboxes for
  `group.toggle.<assetID>` (query `checkBoxes`, not `switches`).
- Edit menu (no ids; a menu is not queried by id): Select Suggested (Shift-Command-S; "Select All
  Videos" on Large Videos), Keep All (Option-Command-K) and Remove Selected… (Command-Delete, opens
  the Confirm sheet only). Command-A stays the system's Select All. Select Suggested and Keep All
  act on the screen in front: the category, or the group while its compare screen is on top.
  Compare This Group (Command-Down) opens the compare screen of the group the keyboard's photo is
  in; it is off elsewhere.
- Photo grid keys: the grid is one keyboard target; the ids of the cells (`category.item.<assetID>`)
  are unchanged. Arrows move, Shift-arrow extends a range from the last photo touched (never a
  suggested keeper), Space toggles the photo the keyboard is on (one that scrolled out of view is
  brought back first and not toggled), Return opens it, Delete and Command-Delete only open Confirm.
- Photo viewer: on a Mac the capture date, the size and Done are drawn in the sheet's content, above
  the photo (a sheet has no toolbar); the label of the button is still "Done".
- Settings window (Command-comma): a Delete All that fails shows its alert there, and the Your Data
  pane reads the saved data again whatever the outcome; the main window shows no alert for it.
- There is no `home.settings` on the Mac: Settings is the window opened with Command-comma, and the
  Help menu has "How Removal Works".

## Flow

```text
Access ─▶ Home ─▶ Scanning ─▶ Results ─▶ Category ─▶ (Group detail / Photo viewer)
                                  │            │
                                  └────────────┴─▶ Confirm sheet ─▶ iOS system prompt ─▶ Done
```

## States each screen must handle

- **Access**: not determined, limited ("only the photos you chose to share", a note on Home),
  denied (explain + open Settings button, nothing scanned).
- **Scanning**: starting, running, paused (by the person, the heat, leaving the app, a storage
  problem), interrupted-and-resumable (shown on Home after relaunch).
- **Results**: nothing found ("Nothing to clean up"), some items not scanned (count shown), item
  removed elsewhere during review (silently dropped), new results waiting ("Show N new items").
- **Confirm sheet**: checking the selection, removing every photo of a set shows a separate
  warning that gates the button (FR-016); sizes marked "about" when estimated.
- **Done**: full success, partial failure (a calm line says how many are still in the library),
  user cancelled the system prompt (nothing removed, back to Category).
- **Viewer**: a photo, a local video (play control), a video that is only in iCloud (still frame).
