# 011 Calm polish: final design for iclean

Status: design, ready to build. Branch: claude/calm-design-polish. Platforms: iPhone (iOS 18+) and Mac (macOS 15+, Apple silicon) now; iPad later.
Trigger: the owner looked at the Mac build and said: "This one looks ugly as hell."
Goal: production quality that follows calm design: one answer per screen, one filled control per state, caveats in the periphery, reassurance next to the action it qualifies.

Data and Network check (constitution): this change touches no stored data except one Mac UI preference (the photo-size slider, UserDefaults). It adds no network call, entitlement, dependency or web content. The Mac Help window, Dock tile and Settings scene are local. No screen links to a website.


---

## 0. Amendments after the critic's review (these override anything below that disagrees)

An independent critic checked this spec against the code and found the points below. Each is decided here so no builder has to guess.

### 0.1 Facts the spec got wrong
- **Duplicate Videos keep the group layout.** Only Large Videos is a list (CategoryView uses `listLayout` for `.largeVideos` alone). Duplicate Videos stay grouped sections with Compare and Keep This Copy (DuplicateVideosFlowTests depends on it). Section 6.6 and the Mac Table apply to **Large Videos only**.
- **"Finished a full scan" is its own fact.** `lastScanDate` is the newest session of any kind (a quick check on every foreground, a Stop) and cannot decide "Nothing to clean up". Add `LaunchState.lastFullScanCompletedAt` (newest session with kind `.full` and state `.completed`) and `AppModel.hasFinishedFullScan`; "Scanned … ago" uses it too.
- **`libraryItemCount` is the store's item count**, re-read after a scan completes (`Store.itemCount()`), never `progress.total` (a rescan of an unchanged library reports 0 or a handful of new items).
- **The `.failed` launch phase** gets its own branch ahead of first run: only the "Saved results couldn't be read" notice and the Settings gear. Never "Nothing to clean up".
- **Finishing is building.** Expose `isFinishing`; between the end of the scan and the final build Home shows the list/progress, never a clean or empty claim.
- **The scan-end VoiceOver announcement** is posted from `AppModel` after the final rebuild (ScanningView is gone by then).

### 0.2 Decisions
1. **State order** (replaces 6.2): launching → failed → scanning/finishing → building → results → interrupted-empty → first run (no full scan finished) → empty library (store count 0) → all cleaned → clean.
2. **Navigation scaffolding is stable across states**: `navigationDestination`, the toolbar gear (`home.settings`, present in every state including first run and failed), the alert and the tripwire overlay live on the NavigationStack's root container, not on the List. The limited-access note has a slot in every state (a bottom footnote inset in the ContentUnavailableView states).
3. **Row figures reconcile with the hero.** A category row's trailing figure is the size of what is **selected** in it; when nothing is selected it shows the removable total in secondary text and the detail says "None selected". Detail words: "All 3 selected" / "2 of 4 selected" / "None selected" (a single item: "Selected" / "Not selected"). They are decision text, so **primary** colour, `.subheadline` (not secondary footnote). The same for the group summary line and the viewer state line.
4. **Words**: "sets" for groups of copies or similar shots in counts and in the whole-sets callout ("3 sets · about 6.4 MB", "Nothing will be kept from 2 sets"); headers stay "3 copies" / "5 similar shots".
5. **Plurals and grouping**: counted strings use automatic grammar agreement (`^[\(n) photo](inflect: true)`) in Text so the number is grouped and the noun agrees; where a String is required use `String(localized:)` with a plural variation and a grouped number passed separately only after checking the catalog output. `done.removed` must remain exactly "N item(s) removed" (seven tests).
6. **Selection summary** is built off the main actor in the same detached task that builds results; the bars show on `summary.count > 0`, never on `selection.isEmpty`, so no frame shows "Review 0 Items".
7. **Confirm sheet**: order is hero, reassurance, then the photo strip, so the reassurance is visible in the medium detent on a small phone; the pinned button is always on screen. Detents `[.medium, .large]`; start at `.large` for accessibility sizes and compact height; the detent never changes after the plan arrives (no flicker). Strip tiles come from `plan.ids` in one pass.
8. **Preview-only glyph** is `photo.badge.exclamationmark` (not the misleading iCloud glyph), with the VoiceOver text "Checked from a preview only".
9. **Recent Scans** lists full scans individually (latest 10) and folds quick checks into one quiet line ("Checked for new photos 12 times · last today at 1:16 PM") so real scans never scroll out.
10. **Videos can be previewed.** The viewer plays a local video (PhotoKit player item, network off) with a play control; copy for videos is "Keep This Video" / "Select for Removal"; the poster is a still only when the video is not on the device.
11. **Mac**: the window size, minimum size and removal of New Window ship **before** the split-view shell (they fix "ugly as hell" at low risk). While scanning with no results the **detail pane shows the scan card** (thermal / storage / failed lines included), not only the sidebar footer. Sidebar rows use `sidebar.category.<name>`; the Overview keeps `results.category.<name>`. The sidebar shows a "Show N new items" row for held results. Menus use `CommandGroup(after: .pasteboard)`, never replace the pasteboard group, and are disabled while a sheet is up or no category is focused.
12. **Hit regions**: every small borderless button (Scan Again, Stop, dismiss) has a 44 pt minimum hit area (`frame(minHeight: 44)` and `contentShape`).
13. **Thumbnails** (done in the first package): PhotoKit's caching manager, opportunistic delivery, cancellable stream, id-based prefetch window, decoded-image cache. Pixel size = cell width in pixels rounded up to a multiple of 64, capped at 512 (768 on Mac); cache limit 128 MB iOS / 192 MB Mac (a 512 px image is about 1.4 MB, so the 40 MB figure above would hold fewer than a screenful).
14. **Demo scenarios** added so every state can be shown and tested: `clean` (photos, nothing found), plus a flow that removes everything for "All cleaned up".
15. **Mac app icon** is a placeholder rendered from the existing art and needs the owner's sign-off; it is not a silent deferral.
16. **iCloud Optimize Storage**: the hero and receipt say "about" and the Done paragraph adds "If your photos are in iCloud, the space you get back on this device can differ."

### 0.3 Build order (replaces section 13)
Foundation, built in order by one author: thumbnail pipeline (done first) → WP0 harness/spec → WP1 accent → Mac window basics (size, minimum, no New Window) → WP2 style kit → WP3 formatting/copy → WP4 selection summary, store facts (`lastFullScanCompletedAt`, `itemCount`) → restore-help text. Screens (independent files): Home and Access, Category and Group and Viewer, Confirm and Done and Settings family. Then localization and docs, then Mac layers (menus, pointer/keyboard, shell) last.

### 0.4 Mac review decisions after the first read of the Mac layer (these override 6.15 and 005 FR-015 where they differ)
- **The selection shortcuts do not take Command-A.** Command-A is the system's Select All (the Large Videos table answers it, and so does any text field), so a second command on the same chord is unreliable: which one the key reaches depends on the focus. Edit > Select Suggested is **Shift-Command-S** and Edit > Keep All is **Option-Command-K**; Remove Selected… keeps Command-Delete. This replaces "Command-A MUST mark all removable photos" of 005 FR-015 (and the Command-A steps of 005 quickstart, plan and tasks) for the key chord only: the command, and the rule that it never marks a keeper, are unchanged.
- **Toolbar ids**: `toolbar.scan` / `toolbar.resume`, because `home.scan` / `home.resume` stay on the buttons in the detail pane and the sidebar footer that are on screen at the same time (see contracts/ui.md). A scan is offered by the toolbar, the Scan menu and the sidebar footer under one rule, the phone's Home states.
- **Group compare is built lazily**: the copies are laid out in rows of up to four, each row a Grid (so Taken, Dimensions and Size line up across its copies), and the rows are in a lazy stack; a group of many copies builds, and asks for pictures of, the rows near the screen only. The rows wrap; there is still no horizontal scroller.
- **"Continue reviewing" and "Show N new items"** are on the Overview as well as in the sidebar footer (each shown once in a window), so they are reachable with the sidebar hidden.

### 0.5 Mac review decisions after the second review (these override 6.15 and 005 FR-015 where they differ)
- **The photo grid is one keyboard target**, not one per photo: the scroll view is focusable and carries the keys once. The photo the keyboard is on is a plain property of the grid's navigator, so it exists after its cell scrolled away; only the cell's ring and its two controls read it. Arrows move, Shift-arrow extends a range from the anchor (never a suggested keeper; it does not unmark when moving back, like Shift-click), Space toggles, Return opens, Delete only opens Confirm. Space on a photo that scrolled out of view scrolls it back and does not toggle; the next press does. Edit > Compare This Group (Command-Down) opens the compare screen of the group the keyboard's photo is in.
- **Hidden on-photo controls are inert**: the check mark and the expand control are not just faded; until the pointer, the keyboard or the selection shows them they take no clicks, show no tooltip and are not Tab stops. The expand control's hit area is 36 pt on a Mac.
- **The grid's width is the scroll content's**, not the scroll view's, so a legacy scroll bar cannot make the column count one too many.
- **The photo-size slider steps by 10, keeps its value local while it is dragged and writes the setting when let go.** The grid follows the thumb; the pictures it asks for keep the size that was set until then.
- **Group compare fits the window**: a photo is no taller than the viewport minus the rows under it (never under 240 pt), so the Remove checkbox and Keep This Copy stay on screen with it; a row is as many copies as fit the width of the scroll content (four at most, each at least 140 pt, or 240 pt for more than four), and the rest wrap. Up and Down move by a row, Escape goes back, Delete only opens Confirm.
- **The viewer on a Mac draws its date, size and Done in its content** (a sheet has no toolbar). Zoomed past the pixels of the 3072 px picture it asks the library for the photo at up to its own size (6144 px at most), from this device only, and lets it go when zoomed out.
- **The Overview's Form keeps the whole pane**; the readable column comes from content margins, not from a maximum width on the scroll view.
- **The scan count is in the toolbar only while the sidebar is hidden**, and the photo-size slider is 80 pt, so the toolbar fits at the 820 pt minimum.
- **Delete All's result belongs to the Settings window**: the Your Data pane is read again from it, and a failure is shown there; the main window has no alert. Automatic window tabbing is off.

### 0.6 Amendments after the independent audit of the iPhone build (UI, accessibility, copy)
An independent five-reviewer audit of the iPhone build confirmed the points below. They override sections 4 to 8 where they disagree.
1. **Text colour.** System `.secondary` is 3.4:1 on white in light mode, so it is only for icons and decoration. Supporting text (captions, footnotes, caveats, the hero overline and caption, the Review note) uses `Palette.quietText`, the QuietText asset (light #5C5C60, dark #A6A6AB, Increase Contrast #3F3F42 and #C7C7CC; at least 4.5:1 on white, on the grouped background and on a bordered button's fill). Reassurance at reading size (the Home messages, the Access trust rows, the Done sentence and steps) is `.primary` and body size.
2. **Accent as text.** The accent is for fills with a white label. Accent-coloured text and the tint of a bordered button use `Palette.accentText`, the AccentText asset (light #0857BD, dark #70ADFF, Increase Contrast #064A9E and #8CB9FF; at least 4.5:1 on white, grouped, a bordered fill and #1C1C1E, and lighter, not darker, with Increase Contrast in dark).
3. **Prominent buttons** are drawn by `actionShape(pinned:)` (Components.swift): a capsule, or a rounded rectangle (Radius.card) at accessibility sizes, because a capsule around a wrapped label is an oval blob. A pinned button (Review, Remove, Confirm, Done, Access) also stops growing at accessibility1; its text is allowed in the accessibility audit lists. At accessibility sizes the Remove bar is one line and the Category summary line carries "Nothing is removed until you confirm. Removed items go to Recently Deleted in Photos." at the top.
4. **A category that empties** (the receipt closed after removing its last item) pops back to Home, which says what is left. Where the screen is not pushed (a Mac detail pane) and when it empties from outside, it shows "All Clear" without the caption and without the bar.
5. **Done** (replaces the paragraph in 6.10): the headline and the honest figure as before; then one primary sentence, "They stay in Recently Deleted for at least 30 days, then Photos erases them for good." (`done.restore`); a "How to put them back" disclosure (`done.howTo`) that opens the numbered steps (`restoreHelp.steps`); and the iCloud caveat as a quiet note (`done.icloud`). When nothing was removed the headline is "Nothing was removed" (id `done.removed`), with the failure line and no figure, no guidance and no note.
6. **Restore Removed Photos** (replaces the string in 6.14): the sentence "Removed photos stay in Recently Deleted in the Photos app for at least 30 days, then Photos erases them for good." (`restoreHelp.retention`), then "To put them back" and three numbered steps in primary text (iPhone: Open Photos. Choose Albums, then Utilities, then Recently Deleted (Face ID or your passcode may be asked). Select the photos you want and tap Recover. Mac: Open Photos. Choose Recently Deleted in the sidebar. Select the photos you want and click Recover.), then "To get the space back sooner, empty Recently Deleted there."
7. **Scan card** (6.4): Pause and Resume are one button whose label, id and look change (the focus stays on it). The model's one announcement at the end of a scan is joined by "Scan paused", "Scan resumed", the reason for a pause the system caused, and "Scan stopped", posted by the card. Stop is at least 44 x 44 pt.
8. **Category rows** (6.3 item 2): with nothing selected the figure reads "up to 933 MB" and VoiceOver says "Large Videos, None selected, up to 933 megabytes could be freed"; a figure never comes before the words "none selected".
9. **Hit areas** (0.2.12): the labels of borderless buttons in Form rows fill the row and are at least 44 pt tall; "Keep This Copy" is a large bordered button.
10. **Lengths** (4.5): Format.durationShort and Format.duration round once, to whole seconds and then to whole minutes, so no length ever says 60 minutes; the words come from `Duration.UnitsFormatStyle` (abbreviated: "12 secs.", "5 mins", "1 hr, 2 mins").
11. **VoiceOver hints** describe the result, never the gesture: "Changes whether this photo is removed". The viewer has no zoom hint; the adjustable trait and the "Zoom N percent" value say it.
12. **System text** for a scan (Lock Screen, Live Activity) uses the card's words and the device noun: "Paused to let your iPhone cool down", "12,408 of 30,112 checked".
13. **Photos permission prompt** (NSPhotoLibraryUsageDescription, both plists): "iclean looks through your photos to find duplicates, similar shots, blurry photos, screenshots and large videos. You choose what to remove, and nothing leaves your iPhone." (Mac: "your Mac").

---

## 1. Diagnosis: why it looks ugly

1. There is no focal point. Home never says how much space can be freed. The hero metric of the product is absent (docs/DESIGN.md sections 5 and 10). The first element on Home is a small row, "Scan Again".
2. There is no primary action. "Scan Again", "Remove All Selected (12)", category icons, Pause and info glyphs are all the same blue. The one consequential action is a plain accent-text list row under two gray footers.
3. The first screen after permission is a single row on an empty screen. The Mac window is a 560x780 phone shape with no minimum size, no sidebar, no toolbar, no Settings window, no menu commands, no keyboard path and no app icon.
4. Colour is spent on the wrong things. Selection is a wall of red check discs. A saturated red slab ends the removal flow although removal is recoverable for at least 30 days. Green text is used for "Suggested to keep" at about 2:1 contrast.
5. Words are the system's, not the person's: "Remove All Selected (12)", "Saved on this iPhone" (on a Mac), "Review choices: 0", "marks", "Results saved", "ticked".
6. Reassurance is treated as a caveat and set in small gray text, while the thing that creates worry (the red button) is the loudest object.

## 2. Facts verified against the code (they changed the design)

| Claim made by a proposal or audit | What the code says | Consequence |
|---|---|---|
| The accent colour is not applied | The AccentColor asset is sRGB 0.20/0.55/0.95 and project.yml has no ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME. The built iOS and Mac Info.plist files have no NSAccentColorName. | WP1 wires it. |
| The proposed dark accent #5AA9FF is fine | White on #5AA9FF is 2.46:1. | Dark accent is #2F78EE (white label 4.16:1, text on black 5.04:1, on #1C1C1E 4.09:1). Light #0A66D6 gives 5.41:1 both ways. Re-measure on device. |
| Selection totals are cheap (about 3 ms at 30,000) | DefaultRemover.totals calls CleanupResults.category(of:) for every selected id. That is categories.first { allMembers.contains(id) }, and allMembers is a flatMap that allocates on every call. The cost is selection x members. ConfirmSheet also calls removalPreview(plan) inside body. | WP4 builds a one-pass index and fixes Remover.totals and the Confirm body. |
| An asset can sit in two categories | DefaultResultsBuilder keeps an `assigned` set: an asset is in exactly one category. | A per-asset index is safe. |
| Stop gives a Resume state | stopScan ends the session as .stopped. isActive is only running or paused. hasInterruptedScan is set only at launch from the last session. lastScanDate is set only on .completed. | After an in-session Stop the only scan control is Scan Library or Scan Again. Resume exists only after a relaunch of a killed scan. |
| ReviewAllButton can own the sheet | The sheet lives on a button inside the results section. If everything is removed the section disappears and takes the open Done screen with it (already latent). If the new bar hides when the selection empties, the sheet would die mid-Done. | The Confirm sheet is presented from HomeView. |
| Progress ticks are isolated | ResultsView.body reads model.progress in its header, so every row re-evaluates on every tick; each row runs totals and an allMembers flatMap. | Rows read the cached summary; only the scan card reads progress. |
| Category groups are lazy | CategoryView uses a plain VStack with ForEach(result.groups). It builds every group section. CategoryView.body also reads selection (removeBar), so it re-runs on every toggle. | LazyVStack, and the bar and select-all become their own subviews. |
| Keeper reasons can be shown ("Largest copy", "In 2 albums") | Duplicate keeper order is: favorite, believable date, then resolution, far-from-earliest date, date credibility, tie-break by time, file size, oldest. Albums are not a signal. Similar-shot keepers are favorite then sharpness. | Only "Marked as a favorite" (a real first rule) and the existing date notes are shown. No invented reasons. |
| The Mac click and key semantics are free to choose | Spec 005 FR-015/016 fix them: click focuses, click on the check mark toggles, Space toggles, Return opens, arrows move, Delete only opens the confirmation, Return never confirms. FR-014 wants a sidebar. FR-017 wants viewer and compare windows. FR-024 wants an icon per platform. | This design follows FR-015/016. The viewer window is deferred. |
| The Mac app has an icon | AppIcon.appiconset declares only platform ios 1024 images. | WP12 adds Mac slots (placeholder render). |
| lastScanDate means "the last full scan" | LaunchState.session is the newest session of any kind, including quick checks. totalItems of a quick check is small. | "We checked N photos" uses libraryItemCount: the store item count at launch, then progress.total after a full scan. |
| Settings can take new content freely | Project memory: adding a section above the existing ones made AccessibilityTests report clipped text; low content is reported as system-capped. | New Settings content sits on its own screens behind constant rows; systemCapped is matched by prefix. |
| Recent Scans is "the last few" | store.sessions() fetches all sessions with no limit and every foreground adds a quick check. | The view shows the latest 10. Collapsing quick checks is deferred. |

## 3. Principles (every screen follows these)

1. One answer per screen, in the person's words, with the numbers in the copy. Home: how much can be freed. Category: what is about to go. Confirm: how much, where it goes, that it can come back. Done: the honest figure and how to undo.
2. One filled control per state. The accent fill is reserved for the next step: Scan Library, Review N Items, Move N Photos to Recently Deleted, Done. Everything else is bordered, borderless or text.
3. The number and the button agree. The hero, the Review bar, the category bar and the Confirm sheet read the same selection. The hero is what the button will act on, never a sum of category totals (Large Videos is never preselected).
4. Verdicts are shape and words, never colour alone. A check means "stays" or "done". A trash mark on a slightly darkened photo means "goes". A "Kept" pill means "stays". Red is not used for the verdict.
5. Red only where deletion is truly irreversible: Delete All iclean Data and Delete Saved Data (system destructive role). Removing photos is recoverable for at least 30 days, so its button is the accent and its label names the destination.
6. Caveats recede. iCloud-only, limited access and store problems are footnotes at the bottom with a secondary icon. Reassurance that removes worry ("nothing is erased yet") is body-size and primary, beside the action.
7. Photos are the only saturated thing. Chrome is monochrome plus one accent. No photo is read to draw Home or the Mac sidebar.
8. System parts first: List and Form, ContentUnavailableView, NavigationSplitView, Settings scene, Table, confirmationDialog, safeAreaInset. Custom views only where there is no system equivalent (selection mark, photo chip, hero figure).
9. Same words and numbers on every platform; only the device noun changes. iPhone is a stack with a pinned bar. Mac is a sidebar and detail window, with toolbar, menus, hover, keyboard and context menus.
10. Defaults give value with zero configuration: Scan, glance at the number, Review, confirm. Four taps from launch to a finished cleanup.

Seven-lens check at a glance: density (default Home is hero, five rows, one bar; hints, caveats and history are one level down); hierarchy (hero, then bar, then rows, then footnotes); language (photos, copies, free, remove, Recently Deleted); periphery (scan status is a bar and a line; notices are footnotes); inputs (suggestions preselected; Large Videos not); framing (space first, destination beside every removal); defaults and disclosure (whole-group warning is a distinct callout that gates the button; Always Keep clearing sits behind a count and a confirmation; Delete All is alone in the last section).

## 4. Tokens and shared components

New files: iclean/Shared/Style.swift (tokens and small modifiers), iclean/Shared/Components.swift (views), iclean/Shared/Device.swift, iclean/Shared/ThumbnailCache.swift. After adding files run `xcodegen generate`.

### 4.1 Spacing, widths, radii
- Space: xs 4, s 8, m 12, l 16 (side gutter and text inset), xl 24 (between blocks), xxl 32. Photo grid gutter: 2 on iOS, 4 on Mac. Stray values (3, 5, 6, 40) are removed.
- Readable column: 560 for Home overview, Done and Mac Overview; 480 for Access; Mac sheets 440; Mac Settings window 480 wide. On iPhone readableColumn is a no-op.
- Radii (continuous): tile 8 (thumbnails, video thumbnails), card 12 (compare photos, callouts). Everything else is system (capsule buttons, circle marks, grouped lists).

### 4.2 Colour
- Accent (asset, set in WP1): light #0A66D6, dark #2F78EE, high contrast light #08489E, high contrast dark #2B6FE0. Used for the one prominent button, links ("Compare"), running progress and the Mac sidebar selection. Never a literal blue.
- Text: .primary for anything that decides something (sizes, counts, hero figure, reassurance on Confirm); .secondary for support text and caveats (system secondary is about 3.4:1; it is only used where it is peripheral or large/bold). Never .tertiary for words.
- Surfaces: system grouped backgrounds on List/Form screens; plain system background on Category and Group; pure black on the viewer only.
- On-photo controls: Color.black at 55% (70% with Increase Contrast) with white content, minimum 11 pt. White on that scrim over a pure white photo is 4.8:1. No materials over photos.
- Selected photo: a black 28% scrim on the thumbnail only (not on the marks or chips), so judging sharpness stays possible.
- Green only as the glyph beside "Suggested to keep" (words stay primary). Red only through the system destructive role on the two real deletes. No .tint(.red), no Color.red, no green text.
- Notices (info or caution): secondary glyph plus footnote text, never red, caution told apart by the triangle shape.

### 4.3 Type roles (text styles only; Dynamic Type is free)
| Role | iOS | macOS |
|---|---|---|
| hero figure | system size 48, semibold, rounded, monospaced digits, via @ScaledMetric(relativeTo: .largeTitle), capped at 88, lineLimit 1, minimumScaleFactor 0.5 | 40 |
| hero overline | .headline, secondary | same |
| hero caption | .callout, secondary | same |
| title | .title2.weight(.semibold) | same |
| row title | .body | same |
| row value | .body.weight(.semibold).monospacedDigit() | same |
| row detail and notes | .footnote, secondary | .subheadline (macOS footnote is 10 pt) |
| button label | .headline | same |
| on-photo chip | .caption2.weight(.semibold), capped at xLarge | .caption |
The only fixed-size font in the app is the hero figure inside Style.swift (scaled and capped). Decorative icons use @ScaledMetric.

### 4.4 Components (iclean/Shared/Components.swift)
- HeroFigure(overline, value, caption): leading VStack; one combined VoiceOver element with the header trait; id home.hero on Home. contentTransition(.numericText()) through calmAnimation.
- QuietLabelStyle (.labelStyle(.quiet)): icon secondary, title primary.
- QuietNote(text, systemImage): footnote secondary Label, no card, no fill. The only notice view.
- SelectionMark(selected, style: .overPhoto or .onSurface). overPhoto, unselected: 2 pt white ring (3 pt with Increase Contrast) over black 28% disc with a 1.5 pt shadow; selected: trash.circle.fill, palette (white glyph, scrim disc). onSurface, unselected: 1.5 pt secondary ring; selected: trash.circle.fill, palette (systemBackground glyph, primary 85% disc), so it inverts in dark mode. 24 pt visual (@ScaledMetric, capped at xLarge), hidden from VoiceOver.
- PhotoChip: one scrim capsule holding up to three parts: optional text "Kept" with checkmark.seal.fill (hidden while the keeper is itself selected), heart.fill, rectangle.stack, and a preview-only glyph. Identifiers are passed explicitly (category.keeperBadge, category.albumBadge, category.previewOnlyBadge); text is localized.
- pinnedBar(isPresented:) { content }: a ViewModifier that always applies the bottom inset and only conditionally shows its content, so the host list keeps identity and scroll position. iOS 26/macOS 26: safeAreaBar(edge: .bottom) under #available (verify the symbol in the installed SDK; if it is missing ship the fallback only). Earlier: safeAreaInset with .background(.bar).
- DelayedProgress(caption): shows nothing for 300 ms, then a centred ProgressView with an optional caption. The one loading idiom.
- Motion: calmAnimation(value:) returns .snappy(duration: 0.25), or nil under Reduce Motion. The only way animation enters the app.
- readableColumn(max): frame(maxWidth: max) centred inside a full-width container.
- Device.noun: "iPhone", "iPad" or "Mac"; Device.systemSettings: "Settings" or "System Settings". One localized key with an argument and a translator comment replaces every #if-duplicated sentence.
- ItemNoun: photos, videos or items from the categories present (all video categories: videos; none: photos; mixed: items).
- Buttons: primary = .borderedProminent .large capsule; secondary = .bordered; quiet = .borderless. A disabled primary becomes .bordered (never a faded slab). Because ButtonStyle types differ, switch with an if/else in a @ViewBuilder, not a ternary. Every Button inside a List or Form row gets an explicit .borderless or .plain style so macOS draws no bezel.

### 4.5 Format additions (iclean/Shared/Formatting.swift)
- Format.bytes stays (adds "about" when estimated); add Format.byteValue (no qualifier) for the hero.
- Format.duration: "5:00", "0:12", "1:02:03" via Duration.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1))) and .hourMinuteSecond(padHourToLength: 1). Format.durationSpoken uses Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide).
- Format.scanned(date, now): "Scanned just now" (under 60 s), "Scanned 3 minutes ago" (under 1 hour), "Scanned today at 2:14 PM", "Scanned yesterday at 2:14 PM", "Scanned Oct 20 at 2:14 PM". Rendered inside TimelineView(.everyMinute) so it never ticks per second.
- Counts of 1,000 or more use Text(value, format: .number) in interpolations.

## 5. Vocabulary (one meaning per word)

- Selected / Select for Removal: the state and action that mark a photo for removal. "Mark" and "ticked" are retired.
- Kept / Keep: the keeper. "Suggested to keep" is the VoiceOver and compare wording. "Keep This Copy" changes the keeper.
- Review N Items: Home, opens the summary. Remove N Photos: a category bar, opens the summary. Move N Photos to Recently Deleted: the one real commit, on the summary. N items removed: the receipt.
- Recently Deleted: always named, always with "at least 30 days" where recovery is stated.
- Always Keep (no quotes): the feature name. "Keep All" and "Select Suggested": the category toolbar.
- Clear = iclean rebuilds it, nothing lost. Reset = back to defaults. Delete = erase for good (only the full wipe).
- Curly apostrophes in new strings. Title Case for buttons and titles; sentence case for descriptions. Every counted string has one/other variants in Localizable.xcstrings.

## 6. Screens

### 6.1 Access (not determined and denied)

Layout: a ScrollView with one centred column (max 480). Order: symbol (photo.stack, tint, @ScaledMetric 56, hidden from VoiceOver and omitted at accessibility sizes), title (.largeTitle.bold, centred), one .body paragraph (centred), two quiet trust rows (.subheadline secondary, secondary glyphs, left aligned in one block). The material card is deleted. The only filled control is the full-width capsule: on iOS pinned with safeAreaInset(edge: .bottom) so it is never under the home indicator or off screen at large text; on Mac inline under the rows at a fixed width. Both buttons use .controlSize(.large).

Copy:
- Title: "Clean up your photos". Body: "iclean finds duplicate, blurry and similar photos, screenshots and big videos so you can free up space." (unchanged).
- Row 1: "Everything stays on this {device}. No account, no internet connection, nothing collected." Row 2: "You review every photo first. Removed photos stay in Recently Deleted so you can get them back." (DESIGN 9.2: onboarding states the safety nets.)
- Button: "Allow Access to Photos". While the request is in flight the button is disabled and shows a ProgressView.
- Denied: title "Photos access is off". Body (iOS): "iclean can’t see your photos, so nothing is scanned. Turn on access in Settings to start." Body (Mac): "iclean can’t see your photos, so nothing is scanned. Open System Settings, choose Privacy & Security, then Photos, and turn on iclean. macOS may ask you to reopen iclean." Button: "Open Settings" (Mac: "Open System Settings"). The pitch and rows are not repeated in the denied state.
States: not determined, denied (body is the message at body weight, not gray), request in flight, accessibility sizes (symbol hidden, content scrolls, the pinned button wraps to two lines). Limited access is not an Access state; it is a quiet note on Home.
Ids kept: access.allow, access.openSettings (Buttons).

### 6.2 Home: the state machine

Home is chosen by a small enum resolved in this order: (1) launchPhase opening or building: launching; (2) isScanning: list; (3) isBuildingResults: list; (4) results non-empty: list; (5) hasInterruptedScan: interrupted-empty; (6) lastScanDate == nil: first run; (7) libraryItemCount == 0: empty library; (8) hasRemovedThisSession: all cleaned; (9) otherwise: clean. The failed launch phase falls through to first run with the unreadable notice below.

The navigation title is the small inline "iclean" with the settings gear (iOS). The 230 pt empty large-title band is gone; the hero replaces it. Notices (limited access, store problems) always come last, as footnotes.

- Launching: DelayedProgress with "Getting ready…" (opening) or "Getting your results ready…" (building); id home.opening; the area has a minimum height so nothing jumps.
- First run (the "88% empty screen"): a ContentUnavailableView centred in the screen. Symbol photo.stack. Title "Find photos you can clean up". Description "iclean looks for duplicates, similar shots, blurry photos, screenshots and large videos. You review everything before anything is removed." Action: Button "Scan Library", .borderedProminent .large, id home.scan. The limited-access note sits below as a footnote.
- Interrupted, nothing found yet: ContentUnavailableView. Title "Your last scan stopped early". Description "Resuming picks up where it stopped. Nothing is lost." Action "Resume Scan" (prominent), id home.resume. Scan Again is not shown.
- Interrupted with results: the normal list plus a plain top row "Resume Scan" (id home.resume) with the line "Picks up where it stopped." Scan Again is hidden. There is never both.
- Clean (finished, library has items, nothing found): ContentUnavailableView, symbol checkmark.circle. Title "Nothing to clean up". Description "We checked {n} photos and videos and found no duplicates, similar shots, blurry photos, screenshots or large videos." (fallback without a count: "No duplicates, similar shots, blurry photos, screenshots or large videos found."). Below: the iCloud footnote when notScannedCount > 0 (id results.notScanned). Action: a quiet bordered "Scan Again" (id home.scan). Container id results.empty. Only when not scanning.
- All cleaned: same layout. Title "All cleaned up". Description "You’ve removed what iclean found. Removed photos stay in Recently Deleted for at least 30 days."
- Empty library (libraryItemCount == 0 after a finished scan): title "No photos to check". iOS: "iclean can’t find any photos or videos to check. Add some, then scan again." Mac: "iclean found no photos or videos to check. If your library is not empty, macOS may be sharing a different one: in Photos, choose Settings, General, then Use as System Photo Library, and scan again." Container id results.empty. This ends the false "looks clean" claim.
- Notices (always last): limited: "iclean can only see the photos you chose to share." (id home.limitedAccess). Volatile: "Your choices won’t be saved this time." with "iclean couldn’t open the place it keeps its data, so what you pick is forgotten when you quit. You can delete iclean’s data in Settings." (id home.storeVolatile). Unreadable: "Saved results couldn’t be read." with "Your photos are safe. To start over, delete iclean’s data in Settings." (id home.storeUnreadable). Store notices keep the triangle glyph in secondary.
- Error alert: title "Something went wrong"; message unchanged; one OK.

The Confirm sheet is presented from HomeView (not from the bar). Ids: home.scan is a Button in every state where a scan can be started (label "Scan Library" until a full scan has finished, "Scan Again" after) and is hidden only while hasInterruptedScan or while scanning.

### 6.3 Home: results (hero, rows, review bar, footers)

Order in the List (insetGrouped on iOS): hero, scan status (only while scanning), interrupted resume row, continue-reviewing row, "Show N new items" row, category section, iCloud footnote, the Scan Again line, notices. The review bar is pinned.

1. Hero (first row, clear background, no separator, no card): overline "You can free" (or "You can free about" while any selected size is estimated); figure "36 MB" (hero font); caption "from 12 selected items. You choose what goes." Id home.hero. While scanning the overline is "So far you can free" and the caption "from 12 items selected so far. You choose what goes." With nothing selected: title2 "Nothing selected yet" and "Open a category to choose what to remove." VoiceOver: "You can free about 36 megabytes from 12 selected items. You choose what goes."
2. Category rows, in fixed CleanupCategory order (rows never reshuffle). Row: neutral secondary icon, title (.body), detail (.footnote secondary) that states selection in words and reconciles with the hero: "All 3 selected", "2 of 4 selected", "None of 3 selected"; trailing the size in the row-value font (Format.bytes, "about" only when estimated); system chevron. No "Results" header while idle; while scanning the header is "Found so far" (id results.foundSoFar). At accessibility sizes the row stacks (existing AnyLayout branch kept). VoiceOver: "Duplicates, about 6.4 megabytes, all 3 selected". Id results.category.<name> stays on the NavigationLink.
3. Footnote (once, one phrasing everywhere): "1 item is only in iCloud, so it wasn’t checked. iclean never downloads photos." (id results.notScanned).
4. Scan Again line (hidden while scanning or interrupted): left "Scanned 3 minutes ago" (id home.lastScan, absent if lastScanDate is nil), right a borderless "Scan Again" (id home.scan; "Scan Library" if no full scan has finished yet). ViewThatFits stacks it at large sizes.
5. Review bar (only when the selection is non-empty; hidden, never disabled): full-width prominent capsule, two lines inside: "Review 12 Items" (.headline) and "about 36 MB" (.subheadline medium, full opacity). Directly under it, centred .footnote secondary: "Nothing is removed until you confirm. Removed items go to Recently Deleted in Photos." Id results.reviewAll stays on the Button. At accessibility sizes the footnote moves into the list as the last footer so the pinned area stays one button tall. It is the only filled control on screen.
6. "Show 3 new items" (arrow.down.circle, secondary; ids results.showNew) replaces "N new results. Show". While building: DelayedProgress "Updating results…" (id results.updating).
7. Continue reviewing (row directly under the hero): "Continue reviewing" (.headline) over "Duplicates, 3 selected" (.footnote secondary); a 44 pt borderless xmark button labelled "Dismiss" replaces the full-size "Not now" row. Ids home.continue and home.continueDismiss stay Buttons; both buttons have explicit styles.

### 6.4 Scan status (the card while scanning)

A background job shown as a quiet status. One list row: status headline (.headline, id scan.status); ProgressView (id scan.progress; tint secondary while paused so the periphery shows state); one count line "12,408 of 30,112 checked" (.subheadline secondary, one Text, id none; label must stay "<n> of <m> checked"); a control row; one footnote (id scan.whenYouLeave). The iCloud-only line and the second spinner row are gone; "N couldn’t be checked" appears only when above 0 (id scan.failed).
- Controls: Pause .bordered (id scan.pause); when paused Resume becomes .borderedProminent only if no review bar is on screen (id scan.resume); Stop is a quiet borderless secondary button without the destructive role (id scan.stop) because it keeps everything found. ViewThatFits(HStack, VStack) stacks them at large sizes. Text-only labels (no icon-column gap).
- Starting (no progress or total 0): headline "Starting…", an indeterminate ProgressView, no count, and the line "Results appear here as they’re found." The separate results.checking row is removed.
- Notes: continues: "Keeps scanning in the background. Progress shows on your Lock Screen." Pauses on leave: "Keep iclean open to finish. It picks up where it left off." Mac: "Keeps going if you close the window. Pauses while your Mac sleeps."
- Paused reasons: user "Paused"; thermal "Paused to let your {device} cool down"; background limit "Paused while you were away"; outside app "Stopped from outside iclean"; storage "Couldn’t save progress. Free up space, then resume the scan."
- Only ScanningView reads model.progress. It posts one VoiceOver announcement when the scan ends ("Scan finished. You can free about 36 MB."), never per tick.
- With nothing found yet there is no hero; the card is the top row and the results area stays silent (never a spinner, never a clean claim).

### 6.5 Category (photo grids and groups)

Inline title (category name; "Blurry" is "Blurry Photos"). Above the photos, two text lines at the 16 pt gutter: the caption stating the default, and one summary line (footnote secondary): "{g} groups · {size}" (singles: "{n} photos · {size}"; videos: "{n} videos · {size}"). Photos are edge to edge with a 2 pt gutter in both layouts (one left edge: text at 16, grids at 0). Columns adaptive, minimum 104 (150 at accessibility sizes and on Mac).

Captions:
- Duplicates: "Copies of the same photo. We keep one of each and select the rest for removal."
- Similar Shots: "Several shots of the same moment. We keep the best one and select the rest for removal."
- Blurry Photos: "Photos that look out of focus or shaken. All are selected for removal. Deselect any you want to keep."
- Screenshots: "All your screenshots, newest first. All are selected for removal. Deselect any you want to keep."
- Duplicate Videos: "Copies of the same video. We keep one of each and select the rest for removal."
- Large Videos: "Your biggest videos, largest first. Nothing is selected for you."

Cell grammar (the whole verdict language):
- Not selected: photo at full strength; white ring top-trailing.
- Selected for removal: the thumbnail only is darkened with a 28% black scrim; a neutral trash.circle.fill mark top-trailing. Marks and chips stay crisp because the scrim is applied before the overlays.
- Keeper: bottom-leading "Kept" pill with a seal; it hides while the keeper is itself selected (then the mark is the whole story). Favorite, albums and preview-only glyphs share the same capsule (max three).
- Expand control: top-leading, 24 pt visual, 44 pt hit area, white on scrim at 85%. Long press (0.4 s) and the VoiceOver action "View full screen" still open the viewer. No contextMenu on iOS (it would steal the long press that BlurryFlowTests uses).
- Overlays are capped with .dynamicTypeSize(...xLarge); thumbnails are never covered by large glyphs.
Check means stays or done; trash means goes. No red, no opacity on the whole cell.

Group header (a 44 pt row, whole row is the NavigationLink, id category.group.<id>): "3 copies" (.headline primary), "2 selected" (.subheadline secondary), trailing "Compare" (accent) and a secondary chevron. 24 pt between groups, 8 pt header to grid. "N similar shots" likewise.

Toolbar button (id category.selectAll): "Keep All" when every suggested item is selected (tapping deselects them), otherwise "Select Suggested", or "Select All Videos" on Large Videos. It never touches keepers.

Bottom bar (id category.removeSelected, always a Button, disabled at 0): prominent capsule with two lines, "Remove 3 Photos" (.headline) and "4.8 MB · goes to Recently Deleted" (.subheadline medium). Photos, Videos or Items by the category. At zero: the same Button disabled, .bordered, "Choose Items to Remove", no second line. At accessibility sizes the second line moves into the scroll content. The bar and the select-all button are their own subviews reading the summary, so CategoryView.body no longer re-runs on every toggle.

Other states: "Show 3 new items" button (id category.showNew); loading: DelayedProgress (id category.loading), never "Nothing here" before results exist; empty: ContentUnavailableView "All Clear" / "Nothing left to review here." (checkmark.circle, no seal). VoiceOver per cell: label is a description only ("Photo, Nov 14, 2023 at 5:13 PM. Suggested to keep. Favorite. In albums: Trip. Checked from a preview only."); value "Selected for removal" or "Staying in your library"; hint "Double tap to change"; traits button and isSelected kept; actions "View full screen" and "Always Keep".

Scale: LazyVStack for the whole content (it was a VStack that built every group); members are hoisted once per body; the restore scroll goes to the group section id first and then to the photo, because the cell lives in a nested lazy grid. Thumbnail pixels come from the grid width: columns from the available width, cell width, then ceil(cellWidth x displayScale / 128) x 128 clamped to 128...512 (768 on Mac), passed as maxPixels to every cell.

### 6.6 Category: Large Videos and Duplicate Videos (list layout)

The highest-regret category gets the richest row. Row (min height 72, 16 pt gutters, hairline separators inset to the text column): a 72 pt thumbnail (tile radius) with a small play glyph and the duration in a bottom-trailing scrim pill ("5:00"); a text column with the size as the headline ("900 MB") over a secondary line "Mar 3, 2024 · 5 min"; at the trailing edge a 28 pt SelectionMark(.onSurface), now visible in light mode (the old mark was a white ring on a white row). Tapping the row toggles; tapping the thumbnail (onTapGesture on the thumbnail, not a nested Button) opens the viewer so a person can look before removing; the thumbnail tap is disabled at accessibility sizes (the stacked row's centre could land on it). Id category.item.<id> stays on the combined row; traits button and isSelected; action "View full screen". VoiceOver: "Video, 5 minutes, 900 MB, Mar 3, 2024". Bottom bar and toolbar as above ("Remove 1 Video"; "Select All Videos").

### 6.7 Group compare

Inline title is the group name ("3 copies", "5 similar shots"), not the parent category. Pinned above the carousel, outside the scroller: one live summary line (.subheadline secondary): "Keeping 1 · removing 2 · about 4.8 MB" (id group.summary; numbers computed from the group's few members). Similar shots add one quiet line: "Turn off a photo’s Remove switch to keep it."

Cards: each about 60% of the width (containerRelativeFrame(.horizontal, count: 5, span: 3, spacing: 12)) so the next card visibly peeks; top aligned. The photo uses its real aspect ratio (clamped 0.75...1.33, taken from the group), tile radius, no gray letterbox bars; a card marked for removal gets the same 28% scrim and trash mark as the grid (the mark is decoration; the switch is the control). Tapping the photo opens the viewer (it used to toggle removal invisibly); selection lives on the switch.

Fixed row order so rows align across cards: (1) date, .subheadline medium; (2) "4,032 × 3,024 · 3.2 MB", .footnote secondary; (3) status slot, minHeight 36: keeper shows a green seal glyph with "Suggested to keep" in primary text, plus "Marked as a favorite" when it is one (id group.keeperReason.<id>); other duplicate copies show a small bordered "Keep This Copy" (id group.makeKeeper); similar-shot non-keepers leave the slot empty; (4) the switch row at the same y in every card: Toggle "Remove this copy" ("Remove this photo" for similar shots), tint accent so ON means selected, not good (id group.toggle.<id>, must stay a Toggle rendered as a switch on iOS); (5) quiet date notes with an info.circle in secondary (ids group.dateNote.<id>.<reason>), and the keeper line "Its date looks reliable." (id group.dateLikely.<id>). VoiceOver for the switch: "Remove copy 2 of 3, Nov 15, 2023".

Date note copy: placeholder "This date looks like a placeholder, not when it was taken."; inFuture "This date is in the future."; the other reasons are unchanged. At accessibility sizes the carousel becomes a vertical list of full-width cards. Group gone: ContentUnavailableView "Already Taken Care Of" / "These photos were removed or changed, so there is nothing to compare."; loading: DelayedProgress (id group.loading). Mac: see section 6.15.

### 6.8 Photo viewer

One black stage. Color.black is the only background (ignoring the safe area); the Thumbnail draws no placeholder slab for .fit. The NavigationStack is forced dark with black toolbar backgrounds, so Done and the actions read as white on one continuous black. Top: "Done" (leading, keyboardShortcut cancelAction; the label stays exactly "Done") and a two-line principal title: the capture date (.subheadline semibold) over "4,032 × 3,024 · 3.2 MB" (.caption secondary). Bottom (in content, via safeAreaInset, so it also works inside a Mac sheet): a state line (id viewer.state; footnote): "Selected for removal" or "Staying in your library"; then two labelled .bordered buttons with titleAndIcon: "Select for Removal" (trash) which becomes "Keep This Photo" (checkmark.circle) once selected (id viewer.toggleSelect), and "Always Keep" (checkmark.shield) (id viewer.alwaysKeep) with the footnote "Never suggest this photo again." Neither is filled; the viewer has no commit action. ViewThatFits stacks the two buttons at large sizes.

Zoom: scale and offset are @State with a stored base scale; MagnifyGesture sets scale = clamp(baseScale x magnification, 1...6) and stores it on end (no more snap-back to 1x on the second pinch); a drag pans only while scale > 1, clamped to the scaled image bounds; double-tap toggles 1x and 2.5x; the scale resets when the photo changes; accessibilityAdjustableAction zooms in and out. Pixel request 2048 (3072 on Mac). Loading: a small centred ProgressView on black.

### 6.9 Confirm sheet

A short summary instead of a table in a void. Inline title "Remove 3 Photos?" (Videos or Items by composition) with Cancel in every state, including "Checking your selection". iPhone detents [.medium, .large] with a visible drag indicator; large only for accessibility sizes, the whole-groups callout, an error, or after the receipt appears.

Content (top to bottom, in a ScrollView):
1. Strip of the photos about to leave: up to 7 tiles of 56 pt (tile radius 8, 4 pt gaps), the largest by bytes, chosen in one O(n) pass over plan.ids, plus a "+6" tile when there are more; accessibilityHidden; hidden at accessibility sizes; neutral tiles if a preview is unavailable (id confirm.strip). This is the one place photos are drawn for the sake of trust; it is shown only after the plan exists.
2. Hero: "about 4.8 MB" (hero font) with the caption "3 photos move to Recently Deleted." Id confirm.summary on this block.
3. Reassurance at reading size and primary colour (it is the main message): Label with arrow.uturn.backward (secondary): "Nothing is erased yet. For at least 30 days you can put them back from Photos." (id confirm.reassurance).
4. Category rows only when two or more categories are present: title with "{n} photos" over the size in a card. The header "You’re about to remove" and the duplicate "Total" card are deleted.
5. Whole-groups callout (only when it applies), directly under the reassurance, in its own secondary-fill card, not red: exclamationmark.triangle in secondary, heading "Nothing will be kept from 2 sets", body "You’ve selected every photo in 2 sets, so none of them will stay in your library.", Toggle "Remove them all anyway" (id confirm.removeAllWarning). While it is off the button is disabled and the caption under the button reads "Turn on “Remove them all anyway” to continue." (with an accessibility hint).
6. "2 items were left out because they changed since the scan (deleted, edited, favorited or no longer suggested). They stay in your library." (footnote, id confirm.dropped).
7. Error (QuietNote above the button, primary text, info.circle, announced to VoiceOver, id confirm.error): "Something went wrong, so nothing was removed. Your photos are untouched. You can try again." (the string moves into AppModel.remove).

Pinned bottom (always on screen, also in the medium detent; background .bar): one full-width accent capsule "Move 3 Photos to Recently Deleted" (id confirm.remove; no destructive role and no .tint(.red); accessibilityHint "Moves the items to Recently Deleted"), and a footnote under it: "You’ll be asked to confirm once more. The system message says “Delete”, but nothing is erased yet." (Mac: "Photos will ask you to confirm once more." until verified on a Mac that it always appears). While removing the label is a ProgressView plus "Moving…" (VoiceOver "Removing"), Cancel is disabled and swipe-down stays disabled. At accessibility sizes the footnote moves into the scroll content. The dead "Nothing was removed." section is deleted.

Why accent and not red: removal is recoverable for at least 30 days; the system dialog that follows is the alarm moment; red stays for the two real deletes. Fallback if the owner disagrees: a muted brick red asset colour (#B3261E light, #D92D20 dark, white label at 4.5:1 or better), never saturated system red.

Mac: .presentationSizing(.form), fixed width 440, height fits the content, Form(.grouped). The heading is real in-content text because a Mac sheet has no title bar. The pinned bar becomes a trailing button row: Cancel (cancelAction, so Esc cancels) and the regular-size prominent "Move 3 Photos to Recently Deleted" with no default-action shortcut. Return does nothing (FR-016).

### 6.10 Done (the receipt)

A quiet receipt in a ScrollView (so it scrolls at accessibility sizes). No "Done" title, no card, no green celebration. Centred column: checkmark.circle in secondary (hierarchical rendering, @ScaledMetric about 44; info.circle when anything failed), "3 items removed" (.title2.bold, header trait, exact string, id done.removed), the honest outcome line in .headline (id done.freed): "You’ll get about 4.8 MB back once Recently Deleted is emptied" (omitted when nothing was removed), then a body secondary paragraph with the escape hatch: iPhone: "They stay in Recently Deleted in Photos for at least 30 days, then are erased for good. To put them back, open Photos, then Albums, then Utilities, then Recently Deleted. To get the space sooner, empty it there." Mac: "...To put them back, open Photos and choose Recently Deleted in the sidebar..." On partial failure one calm line directly under the outcome (no second card, no "Not removed" header): "2 items could not be removed. They are still in your library." (id done.failures). The only control is a pinned prominent "Done" button (id done.close; the old top-right Close is gone). Do not combine children: tests read done.removed and done.failures as standalone texts. VoiceOver focus moves to the headline on appear. One .success haptic only when nothing failed. The sheet switches to the large detent when the receipt appears.

### 6.11 Settings

Form(.grouped), large title "Settings". Ordered by consequence:
1. Section: three navigation rows with quiet leading icons: "Recent Scans" (clock.arrow.circlepath, id settings.recentScans), "What iclean Remembers" (internaldrive, id settings.savedData), "Restore Removed Photos" (arrow.uturn.backward, id settings.restoreHelp). Its footer is the privacy line: "Everything stays on this {device}. No account, no internet connection, nothing collected."
2. A last, separate section containing only "Delete All iclean Data" (system destructive, the only red text on the screen, id settings.deleteAllData), with footer "Removes scan results, your selections and Always Keep photos. Your photos are not touched." In the store-problem state the footer gains the first sentence "iclean couldn’t read its saved data. Deleting it starts fresh."
3. Debug builds: "Baseline Library (Debug)" under a "Developer" header (id settings.baseline).
The dialog "Delete All iclean Data?" (title visible) has the message "This removes scan results, your selections and Always Keep photos. Your photos are not touched.", the destructive button "Delete All iclean Data" (id settings.confirmDelete) and an explicit Cancel. "Clear Always Keep Marks" leaves this screen (see 6.12).

### 6.12 What iclean Remembers (was "Saved on this iPhone")

Inline title. Section 1 (no header): "Scan results" (value: size via Format.bytes, or "None"; second line "Updated 2 hours ago"; id saved.results), "Your selections" (a trailing number, "0" when none; id saved.choices), "Always Keep" ("None" or "12 photos"; id saved.alwaysKeep). Footer: "iclean saves this so it can pick up where you left off. It notes which photos are grouped and what you chose, never the photos themselves, and none of it leaves this {device}." The rows carry their identifiers only once the inventory has loaded (until then the rows show a redacted placeholder without ids), so tests never read a placeholder.
Then one tool per section, each with its own footer: "Clear Scan Results" (id saved.clearResults; "iclean rebuilds these from your next scan. Nothing is lost."); "Reset Your Selections" (id saved.resetChoices, normal tint, not red; "Forgets what you selected and which copies you chose to keep. Your photos are not touched."; dialog "Reset Your Selections?" with message "iclean forgets what you selected and which copies you chose to keep. Your photos are not touched.", buttons Reset (id saved.confirmReset) and Cancel); "Remove Always Keep from All Photos" (id saved.clearAlwaysKeep; shown only when the count is above 0; dialog "Remove Always Keep from 12 photos?" with message "iclean may suggest them for removal again. Nothing is deleted from your library." and buttons "Remove Always Keep" (id saved.confirmClearAlwaysKeep) and Cancel; default tint, not red); and only with a store problem "Delete Saved Data" (destructive, id saved.erase; "iclean can’t read its saved data. Deleting it starts fresh. Your photos are not touched."; dialog buttons Delete (id saved.confirmErase) and Cancel).

### 6.13 Recent Scans

Inline title. Newest first, latest 10. Each row leads with when: "Today at 1:16 PM", "Yesterday at 9:02 AM", "Oct 21 at 1:16 PM" (year only if different). Detail (footnote secondary): "Full scan · Completed · 23 items", or "Full scan · Stopped · 4,200 of 30,214 items"; quick checks read "Check for new photos · Completed". A third quiet line "3 couldn’t be checked" only above 0. "Unfinished" becomes "Not finished". The aggregate footer is deleted (summed diagnostics, the interrupted counter and the slogan). Combined VoiceOver label begins with the outcome: "Completed. Full scan, today at 1:16 PM, 23 items checked." (id settings.session; tests require the capitalised word "Completed"). Empty: ContentUnavailableView "No Scans Yet" / "Scans you run will be listed here." (clock.arrow.circlepath, id recentScans.empty).

### 6.14 Restore Removed Photos

A tiny screen reached from Settings (id settings.restoreHelp) and, on the Mac, from the Help menu. Inline title "Restore Removed Photos". iPhone: "Removed photos stay in Recently Deleted in the Photos app for at least 30 days. To bring one back, open Photos, choose Albums, scroll to Utilities, then choose Recently Deleted (it may ask for Face ID or your passcode). Select the photos you want and tap Recover. To get the space back sooner, empty Recently Deleted there." Mac: "...open Photos, choose Recently Deleted in the sidebar, select the photos you want and click Recover..." This is the permanent restore path DESIGN 9.6 requires. The same string feeds the Done paragraph.

### 6.15 Mac

The Mac is a Mac app. Everything in 6.1 to 6.14 applies; this section adds the desktop layer. All of it is reasoned from code and Apple conventions (macOS blocks capture; verify with WindowSnapshot and by eye).

- Window: keep WindowGroup (a single Window scene may quit the app when closed and changes Dock-click reopening; this is unverified). Remove "New Window" with CommandGroup(replacing: .newItem) {}, so one scan and one confirmation hold by construction. defaultSize 1040x700, windowResizability(.contentMinSize), content minimum 820x540. The 560x780 size stays until the shell lands.
- Shell (SplitRootView, built so iPad regular width can reuse it): NavigationSplitView. Sidebar (min 220, ideal 250, max 300): "Overview" (square.grid.2x2), then a "Cleanup" section of category rows (neutral icon, title, size as a native .badge; ids results.category.<name>), and a footer that holds the quiet scan state ("Scanned 3 minutes ago" and a borderless Scan Again, or while scanning the thin bar, "12,408 of 30,112 checked" and the one-line note, or Resume Scan; and the Continue reviewing row). The sidebar is hidden (detail only) until the first results exist.
- Detail: Overview when nothing is selected: the Home list content in a centred 560 column (Form .grouped): hero at 40 pt, an inline prominent regular-size "Review 12 Items…" button directly under the hero (id results.reviewAll), the category rows (a click selects the sidebar item), the iCloud footnote. The first-run, clean, empty-library and interrupted states are the same ContentUnavailableViews centred in the detail pane, so the first thing on the Mac is one sentence and one big button. A category shows the grid or table with the window title and navigationSubtitle("3 groups · about 6.4 MB"); group compare pushes inside the detail NavigationStack. The overview is never blank.
- Route plumbing: the shell keeps `selection` and `groupPath`; a computed Binding<[Route]> (get: category.map { [.category($0)] + groupPath } ?? []; set: split the first element back out) feeds model.pathChanged and model.restoredRoute, so spec 007 restore and RouteValidator keep working. Route destinations are one shared view used by HomeView and the shell.
- Toolbar: primary action "Scan Library" / "Scan Again" (magnifyingglass, id toolbar.scan; "Resume Scan" after an interrupted scan, id toolbar.resume; .help("Scan the photo library (Command-R)")), offered exactly when the phone's Home would offer a scan (state order 0.2: never while the saved data is opening or being built, after it could not be read, or while a scan runs or finishes), replaced while scanning by Pause/Resume and Stop; a status item "12,408 of 30,112 checked"; on a category: the photo-size slider (90...260, @AppStorage gridCellSize) and Keep All / Select Suggested. No gear on Mac.
- Menus (CommandMenu and CommandGroup): Scan: Scan Library (Command-R), Pause/Resume Scan (Option-Command-P), Stop Scan (Command-period), enabled from model state. Edit (replacing the pasteboard group; verify placement): Select Suggested (Shift-Command-S, never marks a keeper), Keep All (Option-Command-K), Remove Selected… (Command-Delete, opens the Confirm sheet only, never removes). Help: "How Removal Works" opens a small in-app Window with the restore steps. About: "Everything stays on this Mac." Selection commands reach the visible screen through @FocusedValue, and act on the screen in front: the category, or, while a group's compare screen is on top of it, that group alone (Remove Selected… only opens the Confirm sheet, which lists what is selected in the category).
- Settings scene (Command-comma): Settings { MacSettingsView } with a TabView of two tabs in a fixed 480 pt window: General (privacy line, Restore Removed Photos steps inline) and Your Data (What iclean Remembers rows and tools inline, Recent Scans section, then the separate red Delete All iclean Data). The same section views as iPhone; no pushed pages.
- Grid pointer and keyboard layer (FR-015/016): cells are focusable with a 3 pt accent focus ring; click focuses (and updates nothing else); a click on the check mark ring toggles removal; Space toggles the focused photo; Return and double-click open the viewer; arrows move focus (column count derived from the container); Shift-Command-S selects suggested (Command-A stays the system's Select All), Delete and Command-Delete open the Confirm sheet only. A held Space toggles once: key repeats are ignored. The ring and the expand button appear on hover, on focus and while selected (the trash mark stays visible). Context menu on cells (macOS only): View Larger, Always Keep, Select for Removal / Keep This Photo, Select the Rest of This Group. .help tooltips on every on-photo control. Buttons inside cells are .plain.
- Remove bar: a 40 pt status bar, not a slab: "3 photos selected · about 4.8 MB" (secondary) on the left, a regular-size prominent "Remove 3 Photos…" on the right (no keyboard shortcut).
- Large Videos: a native Table (50 rows, lazy): checkbox, 56 pt preview, Size (default sort, descending), Length, Taken; context menu and double-click open the viewer; id category.item.<id> on the primary cell of each row.
- Group compare: no horizontal scroller. Up to 4 copies side by side (containerRelativeFrame count min(n, 4)); more wrap in an adaptive LazyVGrid (min 240, max 420). A shared Grid lines up Taken, Dimensions and Size across copies; Toggle uses .checkbox style ("Remove this copy"; Mac tests would query checkBoxes). Left and Right move between copies.
- Viewer: stays a sheet with the in-content bars (min 640x480, ideal 900x700); Command-plus, Command-minus, Command-0 zoom; double-click toggles fit and 100%; scrolling pans a zoomed photo; Escape closes; useless toolbar Spacer removed; .help on both actions. Its own window (FR-017) is deferred.
- Dock: a thin accent progress bar drawn over the app icon through dockTile.contentView (dimmed while paused, cleared at the end), replacing the red numeric badge (DESIGN 9.6: no red badges).
- Icon: add macOS slots (16, 32, 128, 256, 512 at 1x and 2x) to AppIcon.appiconset from a rounded-square tile with the standard margin rendered from the existing art; NSHumanReadableCopyright in Info-macOS.plist. The redrawn mark is an asset task.
- Wording: "System Settings" (Device.systemSettings), no "tap" in any Mac-visible string, no "iPhone" outside Device.noun.

### 6.16 iPad (later)

TARGETED_DEVICE_FAMILY stays 1. Blockers are removed on the way: no fixed 260x300 compare frames, no unbounded text width (readableColumn on Access, Home, Done, Settings), no fixed-size content. At regular width SplitRootView will be reused; compact width keeps the stack.

## 7. Motion and haptics

- Motion only says the app heard you. All animation goes through calmAnimation, which is nil under Reduce Motion (FR-017a is enforced by construction). Hero and counts use numericText; the selection scrim and mark fade over 0.25 s (no bounce); the review and remove bars appear with opacity and a small slide (opacity only under Reduce Motion); rows insert in place and never reorder under a finger; thumbnails fade in over 0.15 s only when they were not cached. Route restore keeps its disabled-animation transaction. No confetti, no animated checkmark, no count-up, no shimmer.
- Haptics (sensoryFeedback): .selection when the person toggles a photo, a row or Keep All (same feedback for select and deselect, so keeping carries the same weight as removing; triggered by a local counter that increments only in user tap handlers, not by model.selection changes); .success once on Done only when nothing failed. Nothing for scan progress, pause, resume, stop, Review, Cancel, errors or warnings. No sounds.

## 8. Accessibility

- Dynamic Type to AX5: text styles everywhere. The hero scales from 48 (Mac 40), capped at 88, one line with minimumScaleFactor 0.5; the "about" lives in the overline so the figure line is short ("36 MB", "12.4 GB"). Category rows stack; scan controls, viewer buttons, the Scan Again line and the continue row use ViewThatFits; pinned bars hold one button (footnotes move into the scroll content); Confirm opens at the large detent; on-photo glyphs, marks and chips are capped at xLarge and the grid minimum rises to 150; Access hides its symbol; compare cards become a vertical list. No lineLimit or fixedSize that can clip app-owned text (the audit now covers text that used to be system footers).
- VoiceOver: hero is one header ("You can free about 36 megabytes from 12 selected items. You choose what goes."); rows, cells, videos, switches and the Review bar have explicit labels; the Review button hint is "Opens a summary. Nothing is removed until you confirm."; cell state is the accessibilityValue; durations are spoken in words; the Confirm button has the hint "Moves the items to Recently Deleted"; the Confirm error and the scan-finished sentence are announced once; Done moves focus to its headline; viewer zoom is an adjustable action; decorative glyphs are hidden.
- Colour and contrast: accent 5.41:1 light and 4.16:1 dark with a white label (headline is large text); no green text; on-photo controls are white on 55% black; verdicts survive Differentiate Without Color (shape plus words); Increase Contrast thickens rings to 3 pt, raises the scrim to 70% and uses the high-contrast accents; bars use .bar and on-photo controls are solid so Reduce Transparency changes nothing.
- Input: every gesture has a button or action (long press: expand control and "View full screen"; pinch: zoom actions; double-tap and double-click: zoom toggle). 44 pt targets (expand, dismiss xmark, group header, video thumbnail). Mac: full keyboard access (Tab reaches every control, visible focus ring), menus expose every primary action, Esc closes sheets, Return never removes.

## 9. Scale and performance (30,000 photos)

- Home, the hero, the rows, the review bar and the Mac sidebar read only cached numbers. No photo file is read to draw Home or the sidebar. Previews on Home (mosaics) are rejected for this reason.
- Selection summary: CleanupKit gains ResultsIndex (one entry per listed asset: category, effective bytes, estimate flag, removable flag; plus per-category member/removable totals) built once per results change, and SelectionSummary.make(selection:index:) which loops only over the selection (O(selection)). AppModel.summary is recomputed in one coalesced main-actor task after results or selection change. A unit test proves it equals DefaultRemover.summary on random selections. DefaultRemover.totals uses the same index, which removes the selection x members cost from Confirm and from remove().
- Confirm computes its preview once when the plan loads (not in body).
- ResultsView no longer reads progress; ScanningView is the only reader, so progress ticks never re-evaluate the rows.
- Category: LazyVStack, members hoisted, subviews for the bar and select-all, restore scroll in two steps, Recent Scans limited to 10 rows.
- Thumbnails: pixel request from the rendered cell (bucketed to 128, cap 512, Mac 768), compare up to 1024, viewer 2048 (Mac 3072); still local-only, never downloads. A cost-limited NSCache (40 MB iOS, 120 MB Mac, keyed assetID@pixels) prevents a flash when a lazy cell is recreated; a count-based cache of 512 px images is rejected (about 200 MB).
- Check with the large30k demo scenario: toggling one photo updates the hero within one frame; opening Duplicates with thousands of groups shows the first screen immediately; memory stays flat while scrolling.

## 10. Tests affected

Identifiers kept on the same element type (verified against icleanUITests): home.scan (Button), home.resume (Button), home.continue, home.continueDismiss, home.settings, home.lastScan, home.limitedAccess (found with descendants(.any)), home.storeVolatile, home.storeUnreadable, home.opening, results.category.<name>, results.reviewAll (Button), results.empty (kept on the clean, all-cleaned and empty-library containers; absent while scanning), results.notScanned, results.foundSoFar (visible while scanning with results), results.showNew, results.updating, scan.status, scan.progress, scan.pause, scan.resume, scan.stop (Buttons), scan.failed, scan.whenYouLeave (visible Text), the count as one text "<n> of <m> checked", access.allow, access.openSettings, category.item.<id> (isSelected trait, 0.4 s long press, no iOS contextMenu), category.group.<id> (on the NavigationLink), category.selectAll, category.removeSelected (a disabled Button at 0), category.showNew, category.loading, category.keeperBadge, category.albumBadge, category.previewOnlyBadge, group.compare, group.makeKeeper, group.toggle.<id> (Toggle as a switch), group.dateNote.<id>.<reason>, group.dateLikely.<id>, group.loading, viewer.toggleSelect, viewer.alwaysKeep, the viewer button labelled "Done", confirm.summary, confirm.removeAllWarning, confirm.dropped, confirm.error, confirm.checking, confirm.remove, confirm.cancel, done.removed (text exactly "N item(s) removed"), done.freed, done.failures, done.close, settings.deleteAllData, settings.confirmDelete, settings.recentScans, settings.savedData, settings.baseline, settings.session (label contains "Completed"), saved.results (label contains "None" when empty), saved.choices (label ends with the numeral 0), saved.clearResults, saved.resetChoices, saved.confirmReset, saved.erase, saved.confirmErase, recentScans.empty, tripwire.count.

Added: home.hero, results.reviewNote, confirm.strip, confirm.reassurance, group.summary, group.keeperReason.<id>, viewer.state, settings.restoreHelp, saved.alwaysKeep, saved.clearAlwaysKeep, saved.confirmClearAlwaysKeep.
Removed (no test references): results.checking, settings.clearKeepMarks. Update specs/001-photo-cleanup/contracts/ui.md.

Required test edits (same commit as the UI change): AccessibilityTests: drop the "Remove All Selected" prefix allowance (add a temporary "Review" dynamicType allowance only if the audit reports it, and delete it after five clean runs); convert systemCapped to ids plus prefixes; remove "Removed items go to Recently Deleted in the Photos app."; add prefixes for the new Settings/Saved footers; add ids settings.restoreHelp and saved.clearAlwaysKeep. No change to PersistentSessionTests (the numeric saved.choices and the "None" label are preserved). ScreenshotTour: add large-text shots of Confirm, Done, Category, Group and Viewer, and the first-run, interrupted and clean Home states. New UI tests are listed per work package.

Strings the tests read and that must not change: "N item(s) removed", "<n> of 23 checked" as a single text (grouping separators appear only from 1,000), "Completed" inside the settings.session label, "None" in saved.results, a trailing "0" in saved.choices.

## 11. What we will not do

- No storage meter, ring, chart, percentage of storage, lifetime counter, streak, confetti, success sound, review prompt or upsell.
- No photo mosaics or previews on Home, the Mac Overview or the sidebar (reading photo files to draw the front screen). Owner sign-off would be required.
- No red for removal: no red button, badge, selection mark or error text. No saturated system red anywhere.
- No invented keeper reasons; no hero that sums categories; no re-sorting of rows by size.
- No custom fonts, custom navigation bars, hand-drawn buttons, shimmer, or matched-geometry tricks. No theme engine; Style.swift is small.
- No change to removal semantics: the whole-group gate, RemovalGate plan, the single system dialog, nothing removes without the Confirm sheet, Return never removes.
- No removal of any function: Pause, Stop, Resume, Compare, zoom, Select All, Always Keep clearing, Recent Scans, saved-data tools all remain, moved or renamed.
- No iPad build, no iOS 26-only visuals that break iOS 18, no new network, entitlement or web content.
- No new capabilities this pass: no Open Photos button, no Choose More Photos picker, no paging viewer, no standing rules.

## 12. Risks and owner decisions

1. Mac keys follow spec 005 FR-015/016 (Space toggles, Return opens). Mac habit (Finder, Quick Look) is Space = look. If the owner prefers that, change the spec and the menu in one place.
2. Confirm uses the accent, not red. Fallback colours are given in 6.9.
3. The trash mark on a darkened photo is the verdict grammar. If a wall of marks feels loud on Screenshots and Blurry, reduce the scrim or the mark size; it is one line in SelectionMark.
4. safeAreaBar needs the iOS/macOS 26 SDK; the fallback is safeAreaInset. Check both OS versions. Contrast numbers are computed; re-measure on device in both appearances and with Increase Contrast.
5. Copy accuracy: "at least 30 days" and the Albums > Utilities path follow current iOS; "Photos will ask you to confirm once more" on Mac needs a check on a real Mac; re-check each OS release.
6. ContentUnavailableView as the first screen must pass the accessibility audit (the first test audits it).
7. Mac is unverified visually: bezels on Buttons in cells, NavigationLink styling, Table, hover, focus rings, sheet sizing, menu placement of Select Suggested, Dock-click reopening.
8. The photo-size slider stores a UserDefaults preference; nothing else is persisted.
9. Libraries whose photos are all iCloud-only: the clean copy falls back to the generic sentence when checked is 0.
10. Pure logic lives in CleanupKit (tested). Formatting helpers that live in the app (Format) are tested by `icleanTests`, a unit-test target hosted in the app.

Judges' conditions applied: hero at accessibility sizes (6.3, 8); no invented keeper reasons (6.7); lighter dimming (4.2); digest proved and fixed at the root (9); scope ordered with the Mac shell last (13); category bar says Remove, Home says Review (6.3, 6.5); dark accent contrast (4.2); reassurance primary (6.9); Mac keys per spec (6.15); sheet lifetime (6.2); Stop has no Resume state (2, 6.2); saved rows carry ids only once loaded (6.12); scroll restore in two steps (6.5); WindowGroup kept (6.15); Settings audit by prefix (10); Confirm and Done at the large detent (6.9, 6.10); one glyph grammar (4.4, 6.5).

## 13. Build order

WP0 harness and spec; WP1 accent; WP2 style kit; WP3 formatting, copy, thumbnails; WP4 selection summary; WP5 Home results; WP6 Home states and scan status; WP7 Category; WP8 Group compare and Viewer; WP9 Confirm and Done; WP10 Access and Settings; WP11 localization and docs hygiene; WP12 Mac niceties (Settings scene, menus, Dock, icon); WP13 Mac review layer; WP14 Mac shell. Each is buildable and testable alone. Build the iOS simulator and the macOS target after every package; after any change under Packages/CleanupKit also build for the simulator or device, because the macOS package build skips iOS-only files.

## Appendix A: counted strings (one/other variants in Localizable.xcstrings)

Review %lld Items; Remove %lld Photos / Videos / Items; Remove %lld Photos? / Videos? / Items?; Move %lld Photos / Videos / Items to Recently Deleted; %lld photos / videos / items move to Recently Deleted.; from %lld selected items. You choose what goes.; from %lld items selected so far. You choose what goes.; Show %lld new items; %lld items are only in iCloud, so they weren’t checked. iclean never downloads photos.; Remove Always Keep from %lld photos?; %lld photos (Always Keep value); %lld items were left out because they changed since the scan (deleted, edited, favorited or no longer suggested). They stay in your library.; Nothing will be kept from %lld sets; You’ve selected every photo in %lld sets, so none of them will stay in your library.; %lld items removed (existing); %lld items could not be removed. They are still in your library. (existing). Single-number strings with no inflection in English: All %lld selected; %lld of %lld selected; None of %lld selected; %@ of %@ checked; Keeping %lld · removing %lld · %@.
