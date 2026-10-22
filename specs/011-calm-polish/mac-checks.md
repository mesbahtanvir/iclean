# 011 Mac checks

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
- Toolbar: Scan Library, then Pause or Resume and Stop while scanning. The count ("12,408 of 30,112
  checked") is in the middle of the toolbar only while the sidebar is hidden (the sidebar footer and
  the pane already show it). The photo-size slider (80 pt) on a grid category, not on Large Videos.
  At 820 x 540 with a category open and a scan running, with the sidebar shown and hidden: Scan
  controls, the slider and Select Suggested are all in the bar, none in the >> overflow menu. No Scan / Resume Scan button (and
  the Scan menu item is dimmed) while the window says "Getting ready…" or "Getting your results
  ready…", or while a scan is finishing.
- Continue reviewing (relaunch after more than a day with a category open, or a failed restore): the
  row is on the Overview, and in the sidebar footer while a category is open. Click it with another
  category already selected and with a group's compare screen open: the window goes to the saved
  category and group each time.
- Close the window with a category or a group open, then click the Dock icon: the window comes back
  to the same category and group, and results found meanwhile are still held ("Show N new items")
  until you go to the Overview. Remove the last photos of a category: the window goes to the
  Overview behind the receipt.
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
  Left and Right move the ring; Space toggles; Return looks at the copy. A group of 9 or more similar
  shots wraps into rows that build as you scroll (watch memory in Activity Monitor), and Right past
  the last copy of a row scrolls to the next. VoiceOver: one copy at a time (photo, one line with
  Taken, Dimensions and Size, verdict, checkbox), not all photos and then all dates; the reading
  order is by sort priority inside a Grid, which has not been heard yet.
- Held keys: hold Space on a photo, on a compare copy and on a picked video row: it toggles once.
  Hold an arrow key in a long grid: the focus keeps up and never jumps back.
- Check mark: Command-click toggles once (not twice), Shift-click selects the range from the last
  photo. A click on the album/favorite chip focuses the photo like a click anywhere else on it.
- Group header ("3 copies"): "Compare" and its chevron are always there (muted); the word turns to
  the accent on hover and, with Full Keyboard Access, on keyboard focus (`isFocused` in a link's label
  has not been seen to work).
- Viewer: Command-plus, Command-minus, Command-0, double-click between fit and 100%, two-finger
  scroll pans a zoomed photo, Escape closes. The header above the photo (date over size, Done on the
  right) is drawn in the sheet's content, because a sheet has no toolbar: see "Second review" below.
- Confirm and Done: the sheet is as tall as its content, 440 pt wide; Cancel left of the filled
  button; Return closes the receipt.
- Menus: Scan menu items enable and disable with the scan; every command is off while a sheet is up.
  Help > How Removal Works opens one small window and never at launch.
- Dock: a thin accent bar over the icon during a scan (try `-DemoScenario large30k -AutoScan`), dimmed
  while paused, gone when the scan ends. The icon is the placeholder (owner sign-off pending).
- Closing the window keeps a scan running; clicking the Dock icon brings a window back.
- Kill the app inside a category (`kill -9`) and relaunch with `-PersistStore`: the category, group
  and photo come back (spec 007).

## Second review (calm-mac-fixes2): what a human still has to confirm

The second independent review's findings were fixed by reading, Apple's documented behaviour and
builds only; none of this has been seen in a window. Each line says what to try and what must be true.
If a line fails, the part named in brackets is the one to look at.

Settings window
- Your Data, then Delete All iclean Data, confirm: the pane at once shows no scan results, 0 selections,
  "None" for Always Keep, no Always Keep section and no recent scans, while the pane is still open.
  Switch to the main window, scan, come back to Settings: the numbers are current (the pane is read
  again when the window comes to the front and when a scan starts or ends). A failed delete (damage
  the store files) shows "Something went wrong" over the Settings window, with the main window closed
  and open, and never over the main window. [MacSettingsView]

Window
- View has no Show Tab Bar, Window has no Merge All Windows, and no tab bar plus button can make a
  second window. [`NSWindow.allowsAutomaticWindowTabbing` in icleanApp.init]
- Overview at 1040 x 700 and at 820 x 540: the scroll bar is at the right edge of the window (with
  System Settings > Appearance > Show scroll bars: Always, too), the wheel scrolls with the pointer
  over the empty margins, the content is a centred column of about 560 pt. If the grouped Form ignores
  `contentMargins` the content is simply full width: tell me, and the fallback is a ScrollView around
  the sections. [Overview, ReadableFormColumn]

Viewer (a sheet)
- Date over "4,032 × 3,024 · 3.2 MB" in the middle of a black header, Done on the right (Escape also
  closes), no second Done, the header and the stage are one black. [PhotoViewer.macHeader]
- A photo of 12 MP or more: zoom in (Command-plus, pinch, or double-click for 100%). A moment after
  the zoom passes the picture's pixels the photo gets sharper (its real pixels), and zooming out to fit
  lets that picture go (watch the app's memory in Activity Monitor with a 48 MP photo: about 115 MB
  while zoomed in, gone at fit). A photo of 3072 px or less never asks for a second picture. Nothing
  is downloaded: run once with `-NetworkTripwire`. [PhotoViewer.needsDetail]

Grid keyboard (the grid is one focus target now)
- Click a photo: 3 pt ring, nothing else changes. Arrow keys move the ring and scroll to it; hold an
  arrow key in a long grid and the ring keeps up and never jumps back. Space toggles it (held Space once),
  Return opens the viewer, Delete opens the Confirm sheet only when something is selected. In a
  grouped category the arrows cross from one group to the next.
- Shift-arrow: with a photo clicked, Shift-Right marks it and the next photo, Shift-Down marks a whole
  row and a bit; never a photo suggested to keep; Shift-click afterwards still extends from the same
  photo. Moving back with Shift does not unmark (like Shift-click); that is expected. If Shift-arrow does
  nothing at all, SwiftUI is not passing the shifted key to `onKeyPress`. [MacGridKeys]
- Click a photo, scroll far away with the wheel, press Space: the grid scrolls back to the photo and
  nothing is toggled; press Space again: it toggles. The arrows after scrolling away carry on from that
  photo. Click a photo then press an arrow and Space at once: it toggles (no scroll-back). [GridNavigator.photoToAct]
- Hold the pointer still in the top-left or top-right corner of a photo, scroll so a different photo
  arrives under it, click without moving: the click only focuses that photo (no viewer opens, nothing
  toggles); its check mark and expand button are then there. With Full Keyboard Access (System
  Settings > Keyboard > Keyboard navigation) Tab visits the grid as one stop, not three per photo, and
  never stops on an invisible control. [MarkControl, ExpandControl]
- Edit > Compare This Group (Command-Down) is on when the keyboard is on a photo of a group and opens that
  group's compare screen; it is off in a flat category, on Large Videos, and on a compare screen.
- With a mouse (or Show scroll bars: Always): resize the window across a column boundary and press Down
  from a photo in the first row: it goes straight down every time (the column count is measured on
  the scroll content, not the scroll view). Also with the trackpad only.
- Without Full Keyboard Access there is still no Tab route from the sidebar into the grid: click a photo
  first. (A Focus Photos command was left out; say if it is wanted.)

Photo size slider
- Drag it across its whole range on `-DemoScenario large30k` in Duplicates and in Screenshots: the grid
  follows the thumb in steps of 10 without stutter, the pictures stay as they were while the thumb is down
  and sharpen when it is let go, and the size is remembered on relaunch. The arrow keys move it by 10,
  VoiceOver says "150 points". If the step ticks on the track look cluttered, drop `step:` from the
  slider and round in code instead. [PhotoSizeSlider]

Group compare
- Two portrait duplicates in a maximised window: the photos stop short of the window's height and the
  Remove checkboxes and Keep This Copy are on screen without scrolling; the rows stay lined up across the
  copies and sit in the middle of the pane. [MacCompareGrid.maxPhotoHeight]
- At 820 x 540 with the sidebar at its widest: four copies wrap two by two, nine similar shots go one per
  row, nothing is cut off at the right edge, with and without Show scroll bars: Always.
- Open Compare and press Right (and Space) with no click: the ring moves. Up and Down move by a row in a
  group that wraps. Escape goes back to the category. Delete opens the Confirm sheet only when something is
  selected. A click on a copy's checkbox or Keep This Copy moves the ring to that copy.

Large Videos
- Click a row (the table has the keyboard) and press Space: the picked rows toggle once, held Space once.
  Return and double-click open the viewer. VoiceOver on the checkbox says "Remove, Video, <length>, <size>,
  <date>"; the Size cell does not repeat whether it is selected. If Space does nothing, both routes failed:
  the SwiftUI `onKeyPress` and the key monitor in `TableSpaceKey`. [MacVideoTable]
