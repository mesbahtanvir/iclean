# 009 Mac checks

The Mac window was built from the spec and Apple's conventions, and compiled for macOS and the iOS
simulator, but it has not been looked at in a window yet (the build machine's screen was locked).
This is the list to go through once, on a Mac with an unlocked screen. Section 12 item 7 of the spec
names the same risks.

## Pictures without Screen Recording permission

`WindowSnapshot` (debug builds only) makes the app draw its own windows into PNG files and quit. Build:

```bash
xcodebuild build -project iclean.xcodeproj -scheme iclean -destination 'platform=macOS' \
  -derivedDataPath build/DerivedDataMac CODE_SIGNING_ALLOWED=NO
APP=build/DerivedDataMac/Build/Products/Debug/iclean.app/Contents/MacOS/iclean
D="-UITesting -DemoScenario standard"
```

Then one command per picture. `-SnapshotTo` writes the main window with any sheet drawn on it, and
`<name>-sheet1.png` / `<name>-window1.png` for the sheet and for any other window on its own.

| Picture | Launch line |
|---|---|
| First run, no sidebar | `$APP $D -WindowSize 1040x700 -SnapshotAfter 3 -SnapshotTo /tmp/first-run.png` |
| Scan card as the pane | `$APP -UITesting -DemoScenario verySlow -AutoScan -SnapshotAfter 4 -SnapshotTo /tmp/scanning.png` |
| Overview 1040 x 700 | `$APP $D -AutoScan -WindowSize 1040x700 -SnapshotAfter 10 -SnapshotTo /tmp/overview.png` |
| Overview 820 x 540 | `$APP $D -AutoScan -WindowSize 820x540 -SnapshotAfter 10 -SnapshotTo /tmp/overview-min.png` |
| A category (grid, status bar) | `$APP $D -AutoScan -SelectSidebar duplicates -SnapshotAfter 10 -SnapshotTo /tmp/duplicates.png` |
| Photos with no groups | `$APP $D -AutoScan -SelectSidebar blurry -SnapshotAfter 10 -SnapshotTo /tmp/blurry.png` |
| Large Videos table | `$APP $D -AutoScan -SelectSidebar largeVideos -SnapshotAfter 10 -SnapshotTo /tmp/large-videos.png` |
| Group compare | `$APP $D -AutoScan -OpenRoute group:duplicates -SnapshotAfter 12 -SnapshotTo /tmp/compare.png` |
| Confirm sheet | `$APP $D -AutoScan -SelectSidebar overview -OpenSheet confirm -SnapshotAfter 12 -SnapshotTo /tmp/confirm.png` |
| Viewer sheet | `$APP $D -AutoScan -SelectSidebar duplicates -OpenSheet viewer -SnapshotAfter 12 -SnapshotTo /tmp/viewer.png` |
| Settings, General tab | `$APP $D -ShowScreen settingsGeneral -WindowSize 820x540 -SnapshotAfter 3 -SnapshotTo /tmp/settings-general.png` |
| Settings, Your Data tab | `$APP $D -ShowScreen settingsData -WindowSize 820x640 -SnapshotAfter 3 -SnapshotTo /tmp/settings-data.png` |
| How Removal Works | `$APP $D -ShowScreen help -WindowSize 820x540 -SnapshotAfter 3 -SnapshotTo /tmp/help.png` |

`-DemoScenario clean`, `empty`, `denied`, `limited` and `large30k` give the other states.

## By hand

- Window: opens at 1040 x 700 and cannot be made smaller than 820 x 540. There is no File > New Window.
- Sidebar: appears once, when the first results do. Choosing a row changes only the detail pane.
  Clicking Overview never shows a blank pane. Sizes are badges. "Show N new items" appears while a
  category is open and results arrive.
- Overview: hero at 40 pt, one prominent "Review N Items…" under it, category rows (a click selects the
  sidebar row).
- Toolbar: Scan Library, then Pause or Resume and Stop while scanning, with the count in the middle.
  The photo-size slider on a grid category, not on Large Videos.
- Grid: at rest only photos. Hover shows the check mark and the expand control; a selected photo keeps
  its trash mark. Click focuses (3 pt accent ring) and changes nothing else; a click on the check
  mark toggles; Space toggles; Return and double-click open the viewer; arrows move (and scroll);
  Command-click toggles; Shift-click selects a range and never a suggested keeper; the context menu
  has View Larger, Always Keep, Select for Removal or Keep, Select the Rest of This Group.
- Delete, Command-Delete and Edit > Remove Selected… only open the Confirm sheet. In the sheet Return
  does nothing, Escape cancels. Edit > Select Suggested (Shift-Command-S) and Keep All
  (Option-Command-K) never collide with the system's Select All (Command-A): check that Command-A in
  Large Videos selects the table's rows and nothing is marked for removal, and that in a group's
  compare screen the two commands change only that group's copies.
- Large Videos: sorting by a header, checkbox per row, double-click and Return open the viewer, Space
  toggles the picked rows.
- Group compare: up to four copies in a row with Taken, Dimensions and Size lined up; checkboxes;
  Left and Right move the ring; Space toggles; Return looks at the copy.
- Viewer: Command-plus, Command-minus, Command-0, double-click between fit and 100%, two-finger
  scroll pans a zoomed photo, Escape closes.
- Confirm and Done: the sheet is as tall as its content, 440 pt wide; Cancel left of the filled
  button; Return closes the receipt.
- Menus: Scan menu items enable and disable with the scan; every command is off while a sheet is up.
  Help > How Removal Works opens one small window and never at launch.
- Dock: a thin accent bar over the icon during a scan (try `-DemoScenario large30k -AutoScan`), dimmed
  while paused, gone when the scan ends. The icon is the placeholder (owner sign-off pending).
- Closing the window keeps a scan running; clicking the Dock icon brings a window back.
- Kill the app inside a category (`kill -9`) and relaunch with `-PersistStore`: the category, group
  and photo come back (spec 007).
