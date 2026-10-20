# Research: Persistent Review Session

The design was produced by a research workflow: five independent briefs (cleaner apps and Apple's
own tools; offline-first architecture; crash-safe storage on iOS; restoring the person's place;
tracking Photos library changes), a synthesis, and a hostile review of the synthesis that read the
code and ran probes. This file keeps the decisions and the evidence behind them.

**How to read the evidence tags**

- **[experiment]** a probe was run by the researchers and the result is as they reported it. They ran
  on macOS 26 and the iOS 26.0 or 27.0 simulator, never on a physical iPhone unless stated. The probe
  sources lived in the research session's scratch directory and are not in this repository. They were
  not repeated while writing this spec.
- **[documentation]** Apple, SQLite or vendor documentation that was read (URLs below), or an SDK
  header in the iPhoneOS 27.1 SDK.
- **[code]** read from this repository at the time of writing.
- **[folklore]** secondary sources (forums, reviews, aggregator pages, a single report) or the
  researchers' own inference. Treated as a hint, never as the reason for a decision.

SDK header base path: `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.1.sdk/System/Library/Frameworks/`.

## Industry standard for an offline app like this

No photo cleaner publishes how it saves progress, so the standard comes from offline-first engineering
and Apple's guidance, not from a cleaner convention. Six points hold across the sources.

1. A local transactional database is the single source of truth and the screens read only from it
   (Android's offline-first guide; Ink and Switch).
2. Expensive derived results are a disposable materialized view: stamped with a format version and the
   revision of their inputs, checksummed, and rebuilt on any mismatch (Azure's Materialized View
   pattern; Kleppmann; Build Systems a la Carte). Lightroom's preview cache and Obsidian's metadata
   cache are product precedents.
3. Human decisions live apart from derived data, keyed by a stable identity, and are re-applied to every
   rebuild.
4. State is saved in small transactional writes plus lifecycle flushes. SQLite commits survive process
   death; SwiftUI scene storage and UIKit restoration are best effort and dropped on a force-quit.
5. A platform change cursor is committed together with its effects, with a full diff as the fallback.
6. Destructive actions are re-checked at commit time, and crash safety is tested by killing a child
   process at random moments.

iclean had point 1 and the resume half of point 6 (003). This feature adds points 2 to 4 and the
commit-time check; point 5 is deferred (R13).

## R1. What cleaner apps, Apple's own tools and the HIG do

- **Evidence**
  - The public record is thin. No cleaner vendor has published an engineering write-up of persistence
    or resume. Several "complaint" pages are templated or promotional. [folklore, high confidence that
    the record is thin]
  - Gemini Photos: the first launch scans the whole library and later launches analyse only recent
    changes; photos or whole Similar sets can be put on an Ignore List that persists and can be
    undone; removals go to Recently Deleted and nothing is deleted automatically; the FAQ says nothing
    about resuming an interrupted scan. [documentation, vendor FAQ, high]
  - Timing: a first scan of about 38,000 photos took roughly 17 minutes on one reviewer's library and
    older phone; one App Store review says a scan ran for weeks and kept restarting. [folklore, medium
    and low]
  - Swipe-style cleaners advertise saved progress and "pick up where you left off" (store listings,
    developer statements); one review says progress survived leaving the app, and its app could not
    be identified. [folklore, medium]
  - Bugs in these apps cluster around bulk deletion and cloud-only photos, not scanning. Reviews say
    deleting more than 100 items in one batch froze the app but the deletions went through (aggregator
    page). [folklore, medium and low]
  - Apple's own Duplicates (iOS 16 and later) is an OS-owned background index that runs only while the
    phone is locked and charging and can take days; how it refreshes after changes is undocumented.
    [documentation, Apple Support, high]
  - HIG: restore the previous state at launch including scroll position; prefer determinate progress
    and explain a stall; show something at once while loading; make undo predictable. [documentation,
    high]
  - Photos has no public Duplicates API and no Recently Deleted collection or trashed flag (header
    search; Apple DTS says there is by design no API). [documentation, medium]
- **Decision**: take Apple's HIG and general offline-first practice as the standard, not a competitor
  convention. Table stakes for this feature: scan progress survives a kill (003), results and choices
  survive a kill, removed photos never reappear, every removal is confirmed and goes to Recently
  Deleted. Later, not here: per-month progress, streaks, widgets, reviewed badges, undo of ticks,
  deep links into the viewer, and a screen to review the Always keep list (today Settings can only
  clear all keep marks).
- **Alternatives**: copy a competitor flow (none is documented well enough to copy).
- **Sources**: https://cms-static.macpaw.com/support/gemini-photos/faq ,
  https://www.macstories.net/reviews/gemini-photos-declutters-your-photo-library/ ,
  https://apps.apple.com/us/app/gemini-photos-gallery-cleaner/id1277110040 ,
  https://apps.apple.com/us/app/slidebox-photo-manager/id984305203 ,
  https://support.apple.com/en-us/102260 ,
  https://www.macrumors.com/2022/09/28/apple-explains-why-photos-duplicates-no-show/ ,
  https://developer.apple.com/design/human-interface-guidelines/launching ,
  https://developer.apple.com/design/human-interface-guidelines/progress-indicators ,
  https://developer.apple.com/design/human-interface-guidelines/loading ,
  https://developer.apple.com/design/human-interface-guidelines/undo-and-redo ,
  https://developer.apple.com/forums/thread/816828 (Recently Deleted).

## R2. The store is created on the main thread (the root cause of the frozen screen)

- **Decision**: a `DeferredStore` creates the `SwiftDataStore` (not only the `ModelContainer`) off the
  main thread, including the in-memory fallback and the DEBUG launch paths, and every store method
  asserts it is not on the main thread (a test hook). No new blocking store call ships before it
  (stage S1).
- **Evidence**
  - `icleanApp` builds `AppModel(environment: .live())` in a `@State` initializer on the main thread and
    `live()` calls `SwiftDataStore.onDisk()`. [code]
  - An `@ModelActor` created on the main thread runs all of its methods on the main thread; created
    inside `Task.detached` it runs off main. Held on macOS 26 and the iOS 26.0 simulator; not run on an
    iOS 18 runtime. [experiment, hostile review]
  - So today `store.items()` (1.2 to 1.7 s at 30,000 items on a Mac, Release), every scan checkpoint and
    every upsert block the UI. Spec 003 review finding 21 (a launch watchdog termination, `0x8BADF00D`,
    four crash reports on the phone) fixed only the results build, not the load. [experiment and code]
  - Apple lists "triggering lightweight migration for a large Core Data store synchronously" among
    main-thread causes of watchdog terminations, and gives no fixed launch limit (the 10 s in a code
    comment is a conservative budget). [documentation]
  - App prewarming runs no app code, so opening the store in `init` has no prewarm hazard; the problem is
    only the main thread. [documentation]
- **Alternatives**: open only the `ModelContainer` in the background and keep the actor on main (the
  probe shows nothing moves off main); a detached task per call (loses ordering).
- **Sources**: https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations ,
  https://developer.apple.com/documentation/uikit/about-the-app-launch-sequence ,
  specs/003-durable-chunked-scan/review-findings.md.

## R3. What SwiftData and SQLite guarantee when the app dies

- **Decision**: rely on a committed `save()` surviving process death (crash, jetsam, force-quit,
  SIGKILL). Do not fight power-loss rollback: every saved layer lives in one SQLite file, so a
  rollback returns them together to an earlier commit. All writes go through the existing explicit
  transaction helper. No raw `wal_checkpoint` flush (R15).
- **Evidence**
  - SwiftData exposes no durability knobs (`ModelConfiguration` takes name, schema, url, allowsSave,
    groupContainer, cloudKitDatabase). [documentation, high]
  - It opens the store in WAL mode with incremental auto-vacuum and issues no synchronous pragma; it
    turns persistent history on by default (one change row of about 33 bytes per changed object;
    167,100 rows were 5.4 MB of 894 MB, about 0.65%). [experiment, macOS 26 and iOS 26.0 simulator]
  - Apple's system SQLite (3.51.0) is compiled with a default synchronous of FULL but a WAL default of
    NORMAL; a WAL store opened by Core Data or SwiftData therefore runs at NORMAL. Both runtimes printed
    synchronous=1. The simulator shares the macOS kernel, so a phone is not verified. [experiment,
    medium on device]
  - A steady-state `save()` issues no fsync at all (three single-record saves: zero sync calls). Syncs
    happen at a checkpoint (after 1,000 pages, about 4 MB): a barrier sync on the `-wal`, an fsync of the
    directory, a barrier sync on the database. [experiment, interposer, macOS and simulator]
  - A committed save survived SIGKILL: 50 saves committed one by one all survived, 30 inserts never
    saved were lost, a 3.5 MB WAL was recovered on the next open; 25 SIGKILLs at random times during a
    loop of 100-row saves lost no committed transaction, every total was a multiple of 100, and the
    integrity check passed on an 894 MB store. [experiment]
  - SQLite documents the same: commits are durable across application crashes regardless of journal
    mode or synchronous setting, and a WAL commit at NORMAL might roll back after a power loss or system
    crash. [documentation, high]
  - The `-wal` file is part of the database state: a store copied without it had 0 rows where 100 were
    committed, with no error. [experiment]
  - A plain `ModelContext` reports autosave on; an insert followed by SIGKILL left a count of 0. So every
    write goes through the transaction helper. [experiment]
  - A second raw `sqlite3` connection ran `wal_checkpoint(FULL)` against the open store (279 of 279
    frames in 7 ms) and SwiftData kept working. [experiment, macOS only]
  - The default data protection class for app files is complete-until-first-user-authentication
    (readable after the first unlock, even while the phone is locked later). `SQLITE_IOERR_SHMOPEN`
    (4618) is attributed by an Apple engineer to complete protection touched in the background, or a
    background launch before first unlock. [documentation, high]
  - `Data.write(options: .atomic)` writes a temporary file in the same directory, calls plain `fsync` and
    renames it over the target (no `F_FULLFSYNC`, no directory sync). [experiment, macOS and simulator]
  - `PRAGMA quick_check` is O(store size): 1.6 s cold on a 150 MB store, 0.15 s warm. [experiment, noisy,
    Mac]
- **Alternatives**: raw checkpoint flushes at background (unsupported against a SwiftData-owned file,
  verified on macOS only, protects only power loss); a side file with `Data.write(.atomic)` (no
  transaction spanning the file and the database).
- **Sources**: https://www.sqlite.org/wal.html , https://www.sqlite.org/pragma.html ,
  https://www.sqlite.org/atomiccommit.html ,
  https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication ,
  https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files ,
  https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web ,
  https://developer.apple.com/forums/thread/756604 ,
  `SwiftData.framework/Modules/SwiftData.swiftmodule/arm64e-apple-ios.swiftinterface`,
  `CoreData.framework/Headers/NSPersistentStoreCoordinator.h`, `NSData.h`, `sys/fcntl.h`,
  https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html .

## R4. One file, and one generic keyed entity for saved state

- **Decision**: results, choices and place are three rows (`results`, `decisions`, `position`) of one
  generic `StateRecord` entity in the existing store, with the payload inline (no external storage, no
  side file). New kinds later become new keys, not new tables.
- **Evidence**
  - SQLite cannot commit atomically across attached databases, and a side file can disagree with the
    database after a power loss because no transaction spans both. [documentation, high]
  - Saving a decision set as one blob row is about 100 times cheaper than one row per photo for bulk
    changes, and per-photo rows are cheap for single toggles. 5,000 ids: rows insert 237 ms, fetch 36 ms,
    one toggle median 0.26 ms; one blob of 234 KB writes in 1 ms and reads and decodes in 1 ms. 20,000
    ids: rows insert 1,028 ms, fetch 151 ms; blob of 937 KB writes in 2 ms, reads and decodes in 5 ms.
    [experiment, M4 Max, Release, plain context; a phone will be slower]
  - The store is unversioned, and every schema change is paid for at launch on a large store (R12), so
    a generic keyed row avoids a migration per new kind. [code and reasoning]
  - Expensive-to-recompute data belongs in Application Support excluded from backup; Caches may be
    purged by the system and would sit outside the Delete All Data logic. [documentation]
  - Image feature embeddings can be approximately inverted to a picture, so thumbprints and feature
    prints count as sensitive derived data; the snapshot therefore carries none. [documentation,
    medium; not tested on Vision's feature print]
- **Alternatives**: one table per kind (more migrations); per-photo rows (100 times worse for Select
  All); JSON side files (no shared commit domain); Caches (purged).
- **Sources**: https://www.sqlite.org/wal.html ,
  https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup ,
  https://arxiv.org/abs/1506.02753 , https://gdpr-info.eu/art-5-gdpr/ (as a norm, not a legal duty).

## R5. The results snapshot and the revision rule

- **Decision**: the snapshot is a disposable cache with a header and a checksum, shown only when it
  matches (plan, layer C). The store carries a counter that moves in the same transaction as any write
  that changes what results are built from, including a measured size replacing a missing or estimated
  one. The revision is read together with the items in one actor call, and the snapshot is saved by
  compare-and-set on it.
- **Evidence**
  - The builder has hidden inputs besides items and keep marks: the Pro detector set, byte sizes, the
    current time and the calendar. `DateContext` defaults to `now` and `Calendar.current` with a 24 h
    future slack; `LargeVideosCategory` sorts by effective size; the duplicate-video detector exists only
    with video analysis; `SizeMeasurer` upserts sizes after every build. [code]
  - Bumping on every item write makes a snapshot permanently stale, because the measurer writes after
    each build. [code and reasoning]
  - But measured size is a keeper input: equal-pixel copies tie on the estimate (`pixelCount * 0.35`) and
    the measured size flips the keeper (estimated keepers {a}, measured keepers {b}). So a size going from
    no value or an estimate to a measured value bumps, once per batch. The measurer skips items that
    already have a size, so it does not cause permanent staleness. [experiment, hostile review]
  - Reading items and keep marks in two awaits can interleave with a checkpoint, so one actor call returns
    both and the revision. [code and reasoning]
  - Invalidation by timestamps fails: deletes leave none, same-tick writes look unchanged, clocks move
    backwards; a counter plus a content check is the pattern. [documentation: Build Systems a la Carte,
    racy-git, Salsa]
  - The library access level is added to the key because a Full to Limited change while the app is closed
    would show photos outside the new selection. Time zone and calendar are in the key because midnight and
    placeholder checks depend on them (006). [hostile review, code]
  - The 7-day age limit bounds time-dependent inputs and any missed bump. [judgment]
  - A restored snapshot can predate sizes already in the store: a size going from none to an estimate does
    not move the revision (the rules use the same estimate either way), and a kill during measurement
    would restart it from zero. So the stored sizes are overlaid onto the restored items by id, and the
    measurer skips items that already have one. The read is of the size columns only; whether a
    property-limited fetch avoids loading the blob columns is unverified (R14). [hostile review, code]
  - Size is an estimate: under 3 MB at 30,000 photos for the slim members, against under 1 MB for the group
    structure alone in 004. Slim items also drop the roughly 5 to 6 KB of blobs per record, about 150 MB
    at 30,000. [estimate; measure in Release]
  - Build time and item load on an M4 Max are 0.67 s and 1.25 s at 30,000 photos; a phone is unmeasured.
    [experiment, from 004 R5]
- **Alternatives**: show a stale snapshot as "provisional" (rejected: shown only when it matches); one
  global revision bumped by any write (stale forever); store only group structure and load members by id
  (004 spike S1, later).
- **Sources**: https://learn.microsoft.com/en-us/azure/architecture/patterns/materialized-view ,
  https://martin.kleppmann.com/2015/03/04/turning-the-database-inside-out.html ,
  https://www.microsoft.com/en-us/research/uploads/prod/2018/03/build-systems.pdf ,
  https://salsa-rs.github.io/salsa/reference/algorithm.html , https://git-scm.com/docs/racy-git ,
  specs/004-phased-cleaning/research.md R5.

## R6. No patch-forward after a removal

- **Decision**: a removal or Always keep moves the revision and writes no snapshot. The lists update in
  place (through the applier, so defaults are recomputed), a normal off-main rebuild follows, and its
  result is applied at the next Home visit and saved by compare-and-set.
- **Evidence**
  - Similar shots are grouped by union-find, which is transitive. With a group {B, A, C} and keeper B,
    `results.removing(["B"])` leaves {A, C} with keeper C, but a fresh build from [A, C] forms no similar
    group at all, and Similar preselects, so an unrelated photo would be ticked. [experiment, hostile
    review probe `removingABridgeLeavesAGroupARebuildWouldNotForm`]
  - `removing()` re-picks keepers with an empty date context while the builder uses a library-wide one for
    shared-timestamp counts, so keepers can differ too. [code and experiment]
  - `removing()` leaves the re-picked keeper in the default selection. [experiment, probe
    `removingDoesNotRecomputeDefaultSelection`]
  - Today every relaunch rebuilds and heals this. A patched snapshot would cement it for up to 7 days
    and contradict 004 SC-008 (final results equal a one-shot scan). A test that "removing on restored
    equals removing on built" proves only that both drift the same way. [reasoning]
- **Alternatives**: patch in the removal transaction (rejected). The cost of not patching is one 0.7 to 2 s
  background build after a removal session (estimate from Mac numbers).

## R7. Review choices are event-sourced overrides keyed by photo

- **Decision**: save only the differences from the suggestions, as `forcedOn`, `forcedOff` and
  `keeperChoices`, each with a time; normalize after every change; replay with one pure applier on every
  publish (plan, layer D). A "remove" choice is trusted only while fresh and valid; a "keep" choice is
  always honored.
- **Evidence**
  - `apply()` assigns `selection = new.defaultSelection` on every rebuild, and `onForeground` calls
    `reloadResults()` on every `.active`, including after a system alert or Notification Center, so
    choices are lost on every foreground, not only after a crash. `makeKeeper()` changes memory only.
    [code, high]
  - `ResultGroup.id` is a hash of the type and the sorted members, so any membership change gives a group
    a new id and orphans anything keyed by it. [code, high]
  - A cold launch probably builds twice (`onLaunch` and the `.active` handler); the initial inactive to
    active change was seen to fire in a probe. [code and experiment, medium]
  - Replay order matters. In a group {K, R}: tick K, Keep This One on R, Keep This One on K. On screen K
    is kept; a stored "remove K" would survive and K would be a keeper that is also ticked after a
    relaunch. If overrides were derived by diffing the selection, the re-picked keeper left in the
    default selection by `removing()` would become a phantom "remove" decision nobody made. Hence:
    overrides are recorded as events, normalized (a keeper choice clears the photo's "remove" and sets its
    "keep"), and every `removing()` call goes through the applier. [code and experiment, hostile review]
  - Keeping is always safe; a stale "remove" is the only path to deleting something the person no longer
    meant to delete. The repo's own staging rule says to drop missing items or items modified after the
    decision. [reasoning; code: docs/SCAN_PIPELINE.md]
  - In a simulator probe, favoriting bumped the modification date, as did a date edit and a content edit;
    album membership did not; hiding was reported as an update and the photo could no longer be fetched;
    a PhotoKit delete was reported as a delete. So the favorite flag is compared as well as the date.
    [experiment, medium; one run each]
  - Seven days for "remove" (not 30) matches the snapshot, is closer to "mid-session", and keeps a large
    forgotten selection out of the Home "Remove All Selected" total. [hostile review]
  - Gemini's persistent Ignore List is the one verified competitor precedent for stored keep decisions.
    [documentation, vendor FAQ]
  - Write costs are in R4. Select All on 20,000 photos is one write of roughly 1 to 2 MB before
    compression (estimate). [estimate]
- **Alternatives**: save the whole selection set (loses meaning when defaults change); per-photo rows
  (R4); key by group (orphaned by any removal).

## R8. Save points

- **Decision**: debounced writes (500 ms trailing, 2 s maximum wait) after every toggle, bulk select,
  keeper change and path change; an awaited flush at `.inactive` and `.background` with
  `UIApplication.beginBackgroundTask` started synchronously in the handler; a flush when the confirm
  sheet opens and before removal. A writer generation counter makes Delete All Data safe.
- **Evidence**
  - Apple says to save user data on deactivation; system alerts (including the delete dialog) also
    deactivate the app; on `.background` expect termination soon; the background callback has five
    seconds; `beginBackgroundTask` extends it and must be ended promptly. The amount of extra time is not
    documented (about 30 s is folklore). [documentation, high; the number is folklore, low]
  - `applicationWillTerminate` is generally not called for background-capable apps and not on jetsam or a
    force-quit of a suspended app. [documentation for the first; Apple-engineer forum replies for the
    rest, medium]
  - A `Task { }` started inside `onChange(of: scenePhase)` may not run before suspension unless the
    background task is requested synchronously first. [documentation-derived reasoning]
  - A committed save survives process death (R3), so the loss window is the debounce, not the session.
  - UIDocument's autosave (periodic, safe-save, no Save button) is Apple's own precedent. [documentation]
  - Memory makes OS kills a main path: 570 MB resident at 30,000 photos; Apple says to discard large
    reloadable objects when entering the background. Dropping results at `.background` is not adopted;
    slim results and the snapshot make a kill cheap instead. [documentation and experiment, medium]
  - Delete All Data today only stops the scan, deletes the store and applies empty results. With a pending
    debounce, held choices and a background flush it could write choices back. A generation counter,
    cancel, clear and refusal of older flushes closes this; `setSizes` must only update existing rows.
    [code and reasoning, hostile review]
- **Alternatives**: `applicationWillTerminate` (not delivered); `SceneStorage` (R9); writing on every tap
  (churn, more writes than needed).
- **Sources**: https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background ,
  https://developer.apple.com/documentation/swiftui/scenephase ,
  https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time ,
  https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationwillterminate(_:) ,
  https://developer.apple.com/forums/thread/126418 , https://developer.apple.com/forums/thread/778656 ,
  https://developer.apple.com/documentation/uikit/uidocument ,
  https://developer.apple.com/documentation/xcode/responding-to-low-memory-warnings ,
  https://wwdcnotes.com/documentation/wwdc20-10078-why-is-my-app-getting-killed/ .

## R9. Restoring the screen

- **Decision**: the screen is saved in iclean's own store as a typed `Route` stack with a
  `restoreAttempts` counter; restored on its own within 24 hours; later, or after the counter reaches 2,
  Home shows "Continue reviewing". The live path is scene-local state mirrored into the breadcrumb.
  Never `SceneStorage`, `NSUserActivity` or `UserDefaults` for this.
- **Evidence**
  - `SceneStorage` makes no guarantee when or how often data is persisted and is destroyed when the scene
    is destroyed; Apple deletes preserved UI state on a force-quit "as a safety precaution" and when the
    app crashes at launch; UIKit state preservation "isn't a substitute for saving your app's data".
    [documentation, high]
  - In a probe app on the iOS 27.0 simulator: the OS-restored state was the snapshot from the last
    background transition, so a foreground kill lost everything since (counter 13 and 4 routes came back
    as 6 and 2); swiping away wiped it; reinstalling over kept it; a shutdown within about 1 s of
    backgrounding restored the older snapshot (2 of 2, and once a wiped state) while 10 s or more
    restored the newest (2 of 2). Device reboot is not verified. [experiment, medium]
  - So the OS cannot deliver "survive a crash"; it must live in iclean's own store. A Codable route as
    `Data` in `SceneStorage` is possible (143 bytes for two routes), but would be a second source of truth
    and is wiped on a force-quit. [documentation and experiment]
  - The type-erased `NavigationPath.CodableRepresentation` had forum reports of a decode failure that
    crashes when the view appears (iOS 16 betas; iOS 18 status unknown). `NavigationStack(path:)` accepts
    any random-access, range-replaceable collection of hashable values, so a typed `[Route]` keeps decode
    errors in code the app controls. [documentation, forum reports medium; interface high]
  - WWDC22 shows IDs (not models) in a Codable navigation model, restored in `.task` after the first
    frame, so a Home flash is possible; the OS shows its snapshot of the old screen first, so a restored UI
    that differs visibly jumps. The fix is to build the restored stack for the first content frame.
    Unverified on a device. [documentation, high; first-frame behavior open]
  - `NSUserActivity` advertises to nearby devices through Handoff (against Constitution I and II);
    `UserDefaults` is unencrypted, backed up, and not for identifier lists. [documentation, high]
  - `CategoryView` and `GroupDetailView` say "Nothing here" or "Group removed" whenever a result is
    missing, which is the state while the first build runs; `GroupDetailView` is keyed by `ResultGroup.id`.
    So routes are resolved by anchor photos and the screens get a loading state. [code, high]
  - The OS guards UIKit restoration crash loops itself; how that applies to SwiftUI is undocumented, so
    the app keeps its own guard. [documentation, header, medium]
  - Android's three tiers (in-memory, small saved state lost on user dismissal, local persistence) match
    what the probe showed. [documentation, high]
  - The first design used a timed sentinel (set before restoring, cleared after about 3 s). It misfires
    both ways: a jetsam inside 3 s leaves it set, and a deterministic crash after 3 s is not caught. A
    counter incremented before restoring and cleared by a clean flush (or after 30 s) is safer; auto-
    restore stops at 2. [hostile review]
  - A single global path would mirror navigation between windows on iPad and Mac (005 FR-017, FR-018), so
    the live path is scene-local. [hostile review]
  - One brief recommended a Continue row only, because Apple drops UI state on a force-quit on purpose.
    The owner asked to start from where they were, so this feature restores within a window and falls
    back to the row; the window is one constant. [decision]
- **Alternatives**: `SceneStorage` as the carrier (R9 evidence), the Continue row only, a timed sentinel.
- **Sources**: https://developer.apple.com/documentation/swiftui/scenestorage ,
  https://developer.apple.com/documentation/swiftui/restoring-your-app-s-state-with-swiftui ,
  https://developer.apple.com/documentation/uikit/preserving-your-app-s-ui-across-launches ,
  https://developer.apple.com/documentation/uikit/restoring-your-app-s-state ,
  https://developer.apple.com/videos/play/wwdc2022/10054/ ,
  https://developer.apple.com/forums/thread/710295 , https://developer.apple.com/forums/thread/708770 ,
  https://developer.apple.com/forums/thread/68675 ,
  https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/Handoff/AdoptingHandoff/AdoptingHandoff.html ,
  https://developer.apple.com/documentation/foundation/userdefaults ,
  https://developer.android.com/topic/libraries/architecture/saving-states ,
  `SwiftUI.framework/.../arm64e-apple-ios.swiftinterface` (`SceneStorage`, `NavigationStack`),
  `UIKit.framework/Headers/UIApplication.h`, `UISceneEnhancedStateRestoration.h`.

## R10. Removal safety: a commit-time gate, an immutable plan, no journal

- **Decision**: when the confirm sheet opens, build an immutable `RemovalPlan` after a commit-time
  freshness gate, show "Checking selection" until it returns, and execute exactly the plan (plan,
  Removal safety). There is no write-ahead removal journal.
- **Evidence**
  - `DefaultRemover.remove` filters the selection by `results.items` and calls the library with no re-check
    for existence or modification; `ConfirmSheet` recomputes its preview from live model state, and
    `removeSelected` re-reads selection and results at tap time. A rebuild applied while the sheet is open
    can change the button under the finger. [code, high]
  - A snapshot widens how old the view can be, so the confirm step needs a freshness gate; this is the
    Saga "reread values before you commit" countermeasure. [documentation, medium; mapping is judgment]
  - By-id stamps cost about 10 ms per 500 ids. [experiment, simulator, medium]
  - By-id fetches use no options today while the enumeration uses `includeAllBurstAssets = true`,
    `includeAssetSourceTypes = [.typeUserLibrary]`, hidden excluded. The header says by-id fetches include
    hidden assets by default and that `includeAllBurstAssets` defaults to NO; a simulator hide probe
    returned the hidden photo from neither by-id variant. If by-id fetches omit non-key burst frames, the
    existing chunk run already drops them as "gone", and the gate and visible-set check would too. One
    options factory is used everywhere and a device check gates the rollout. [documentation, experiment
    medium, inference medium]
  - Recently Deleted cannot be fetched by an app, so "not fetchable" covers deleted, hidden, trashed and
    out-of-selection photos alike. All mean "leave the lists"; iclean never deletes from the library
    because of it. [documentation, Apple DTS, medium]
  - The journal was dropped. After a kill during the system dialog, absent photos are already dropped by
    the visible-set check and removed from the store by the quick check; present photos keep their ticks
    from the flush at sheet open; nothing is retried. What happens to an in-flight delete when the process
    dies is undocumented, so a journal would have to treat Photos as the truth anyway. It also adds a row,
    a lifetime, a reconcile step, and a possibly wrong "removed" note when ids were only hidden.
    [reasoning, hostile review]
- **Alternatives**: write-ahead journal with pending, done and aborted states (rejected); split a removal
  into several PhotoKit calls (each shows its own system confirmation).
- **Sources**: `Photos.framework/Headers/PHFetchOptions.h`, `PHAsset.h` (line about hidden assets),
  https://learn.microsoft.com/en-us/azure/architecture/patterns/saga ,
  https://developer.apple.com/forums/thread/816828 , docs/APP_PLATFORM.md section 2.1 (the superseded
  commit journal).

## R11. Failure handling: open, read, write

- **Decision**: open off the main thread through the `DeferredStore`; classify failures; an open failure
  is a visible volatile state, never "empty" or "clean"; read errors are load failures; three scan write
  failures in a row pause the scan; no automatic quarantine in v1; "Delete saved data" is an explicit,
  confirmed action that removes the store, `-wal` and `-shm` together.
- **Evidence**
  - A damaged header makes the open throw (`NSCocoaError` 259 or `NSSQLiteErrorDomain` 26); a truncated
    file throws `NSSQLiteErrorDomain` 11 at `addPersistentStore`; a damaged interior page does not fail at
    open or at a count, and a later full fetch throws 11 (a thrown error, not a crash) while
    `quick_check` reports it. [experiment, macOS 26]
  - A required attribute with no default makes the container throw `loadIssueModelContainer` (real cause
    134110 only in the console log). [experiment]
  - Today `(try? await store.items()) ?? []` shows "nothing to clean" on a corrupt read, and
    `(try? SwiftDataStore.onDisk()) ?? inMemory()` hides an open failure and loses persistence with no
    message. [code, high]
  - Data protection can make a background launch before first unlock fail with `SQLITE_IOERR_SHMOPEN`
    4618. iclean has no system-initiated launch path (the continued task is submitted from the
    foreground), so this should not occur, but it is waited out, not treated as damage. [documentation;
    "cannot occur" is medium and untested on a locked phone]
  - Quarantine was dropped (a hostile-review objection): code 26 is not documented to be separable from
    data-protection or partial-write cases on a locked phone; a wrong quarantine loses Always keep marks,
    which have no copy, and forces a rescan of 30,000 photos (about 40 minutes at the 004 reference rate);
    copies would grow about 150 MB each. [reasoning, medium]
  - The pipeline swallows store errors with `try?` and keeps results in memory; one failure is safe, a
    persistent one (disk full) makes progress non-durable while the UI shows it as saved, so a streak of 3
    pauses it. [code; the number is a judgment]
  - `PRAGMA quick_check` or `integrity_check` at every launch costs O(store size), 1.6 s cold on 150 MB,
    so checksummed payloads plus classified read errors are used instead. [experiment]
- **Alternatives**: automatic quarantine of the three files and a fresh store (a destructive path driven by
  error-code folklore); a JSON mirror of keep marks (R15).
- **Sources**: https://developer.apple.com/forums/thread/756604 ,
  https://www.sqlite.org/pragma.html , specs/003-durable-chunked-scan/review-findings.md.

## R12. Schema evolution: additive only, no `VersionedSchema` now

- **Decision**: add exactly two entities and change no existing one, so lightweight migration applies and
  an existing store (including the owner's phone store) opens unchanged. `StoreMeta.formatVersion` exists
  for the first non-additive change. A fixture written by the current build (`shipped-store`) joins
  `previous-store`.
- **Evidence**
  - An additive optional attribute plus a new entity migrates with rows kept; a non-optional attribute
    without a default fails (134110); a property type change fails (134140 or 134190); adopting
    `VersionedSchema` over a store written without one works only if V1 equals the shipped model exactly,
    otherwise 134504. [experiment]
  - A downgrade is silent and destructive: a store written by a newer schema and opened and written by an
    older build loses the newer columns, with nothing thrown. [experiment]
  - Migration cost on a Mac: adding two entities to a 143 MB, 30,000-item store took 0.08 to 0.18 s
    (Release); a separate measurement of a column migration took 2.03 s against 0.31 s for the next open.
    The two are not reconciled (possibly a table copy versus only new tables; unverified). A phone is
    unmeasured. [experiment, two sources]
  - 40 SIGKILLs at random 20 to 350 ms offsets during open all reopened with 30,000 items and a passing
    integrity check. [experiment, hostile review, macOS]
  - The shape has drifted across 001 to 006, so freezing a `V1` now would need verification against the
    owner's real store. [code]
- **Alternatives**: adopt `VersionedSchema` now (risk of 134504 and forum-reported crashes); freeze later,
  at the first non-additive change, with a verified fixture.
- **Sources**: https://developer.apple.com/documentation/swiftdata/migrationstage ,
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreDataVersioning/Articles/vmLightweightMigration.html ,
  https://developer.apple.com/forums/thread/769923 , https://developer.apple.com/forums/thread/738125 .

## R13. The photo library change cursor (recorded, deferred)

- **Decision**: not built in this feature. Build it only if the foreground reconcile costs more than about
  1.5 s or 300 MB at 30,000 photos on the phone. If built, the contract is below.
- **Design to keep**
  - Capture `currentChangeToken` **before** a full enumeration and commit it with the effects in one
    transaction (replays are then safe because the planner is idempotent). Read only asset changes (skip
    asset collections and collection lists, which carry about 30 smart-album ids of noise per change).
    Stop reading at a time budget.
  - Map 3105 (expired), 3210 (details unavailable) and an undecodable token to "drop the token and run
    the full diff"; map 3311 (access denied) to "keep the token, show the Access screen"; any other error
    to one full diff per launch. Never persist a token read while access is denied.
  - Use the full diff for Limited access and drop the token when the access level changes. Keep a count
    audit (library count with the same options equals the store count, only when no job is active) and a
    weekly full diff.
  - Treat "updated" as a hint only: refetch and compare against the stored row before scheduling work.
- **Evidence**
  - `currentChangeToken` and `fetchPersistentChanges(since:)` exist from iOS 16; the token is
    `NSSecureCoding` (620 bytes in a probe and it decoded in a fresh process); each details object holds
    inserted, updated and deleted local ids and nothing else. [documentation and experiment]
  - Expiry is 3105 or 3210; the retention window is not documented anywhere found. [documentation, high]
  - Costs on the simulator: a zero-change fetch 0.5 to 0.7 ms; about 1.5 ms per change; 197 changes with
    20,000 ids 1.4 to 1.8 s; 7,000 inserted ids 1.0 s, against 0.15 to 0.26 s to enumerate 10,000 assets.
    The delta wins by orders of magnitude when little changed and loses when more than roughly 10 to 20%
    of the library changed. [experiment, medium; not a device]
  - The token does not identify a library: after erasing the simulator an old token threw 3105 until the
    new library's counter passed it, then returned 272 changes of the unrelated new library with no error.
    A third-party team reached the same conclusion and reconciles periodically. [experiment, medium]
  - "Updated" is a superset of what the person did: 40 new assets were all reported updated within 20 s;
    untouched assets appeared as updated at random. [experiment, medium]
  - Album membership changes do not change the modification date (and all members were reported updated);
    favorites do. [experiment, medium]
  - Under Limited access only changes to user-selected objects are returned; how editing the selection
    appears is not stated. [documentation, medium]
  - Open-source photo backup code follows the same pattern: full bootstrap, then a persisted token,
    committed with the work queue in one transaction, with a full scan on expiry and periodic
    reconciliation. [folklore, medium; PRs read]
- **Sources**: `Photos.framework/Headers/PHPhotoLibrary.h` (lines about persistent changes),
  `PHPersistentChangeToken.h`, `PHPersistentObjectChangeDetails.h`, `PHError.h`,
  https://developer.apple.com/videos/play/wwdc2022/10132/ ,
  https://developer.apple.com/forums/thread/739451 ,
  https://github.com/FawenYo/YAIIU/pull/84 , https://github.com/hawkeye-xb/P-Pass/pull/905 ,
  https://github.com/hawkeye-xb/P-Pass/issues/904 , https://github.com/hawkeye-xb/P-Pass/issues/335 ,
  https://github.com/LyeMuk/photovault/issues/11 .

## R14. Reading cost (why the quick check is still heavy, and what was measured)

- **Decision**: this feature does not slim the planner's input. The quick check still reads every stored
  photo (recorded as a risk in plan.md). The slim snapshot lowers in-session memory only.
- **Evidence**
  - Loading 30,000 stored items: 1.25 s and 569 MB resident; the launch pipeline 2.15 s and 853 MB; Debug
    builds are about 142 times slower, so launch numbers come from Release. [experiment, M4 Max, from
    004 R5]
  - A `ModelContext` retains every fetched row: one full fetch of 30,000 rows of about 5 KB peaks near
    390 MB; `propertiesToFetch` and `enumerate(batchSize:)` did not lower the peak in the probe;
    keyset paging with a fresh context per 1,000 rows and `SortDescriptor(.lexical)` read everything in
    0.49 s at 37 MB; `fetchOffset` paging took 31 s; the default string sort is localized and disagrees
    with a `>` predicate, which truncated pages to 1,010 of 30,000 rows. [experiment, macOS 26]
  - The launch-time quick check loads every item before diffing (about 1.9 GB at 100,000 if linear),
    which breaks 004 FR-025 and SC-005 on every launch. [code and estimate; hostile review]
- **Alternatives**: a slim planner input with keyset paging (004 slim loading); the token delta (R13).
  Both are the follow-ups if the phone measurement says so.

## R15. Looked at and not adopted

| Option | Why not |
|---|---|
| `SceneStorage`, `NSUserActivity`, `UserDefaults` for choices or place | best effort, wiped on force-quit; Handoff advertises; unencrypted and backed up (R9) |
| `applicationWillTerminate` as a save point | not delivered on jetsam or force-quit (R8) |
| Raw `wal_checkpoint(FULL)` flush, PRAGMA tuning, `F_FULLFSYNC` | unsupported against a SwiftData-owned file, macOS only, protects only power loss, where all layers already roll back together (R3) |
| Adopt `VersionedSchema` now | works only if V1 equals the shipped hash; this change is additive (R12) |
| JSON mirror of keep marks, salvaging a damaged store | two copies of a grow-only set and internal table names add paths for a rare corruption; the damaged files are left alone (R11) |
| Show a revision-stale snapshot as "provisional" | only a matching snapshot is shown; the cold path shows placeholders for about 2 s |
| `PHCloudIdentifier` | the store is excluded from backup and never synced, so a new device correctly rescans; mapping costs 2.6 to 3.0 ms per photo (about 80 s for 30,000, against about 0.5 s to enumerate) with an ambiguity fallback [experiment, simulator without iCloud] |
| The change token as the correctness mechanism | the visible-set check and the commit-time gate give correctness; the token would only be a speed-up (R13) |
| Incremental results engine (004 S5), reviewed badges, per-month progress, streaks, widgets, undo of ticks | outside persistence |
| Thumbnails on disk, `.externalStorage`, side files | thumbnails come from Photos on demand; one SQLite file is one commit domain |
| `integrity_check` at launch | O(store size) (R3) |
| Pruning SwiftData persistent history, GRDB, an App Group store, sync | low value or against the constitution; a suspended app holding a SQLite lock in a shared container can be killed (`0xdead10cc`) [folklore, medium] |
| Dropping results at `.background` and rebuilding at `.active` | the snapshot makes a kill cheap, so this is unnecessary (R8) |
| Patching a snapshot forward after a removal | produces groups a rebuild would not form (R6) |
| An app build stamp in the builder key | not adopted; see the review table and the risk in plan.md |

## R16. Test strategy

- **Decision**: follow SQLite's own method and test the "never trust the cache" paths that normal use
  never hits.
  - A child process writes checkpoints and decisions and is SIGKILLed at seeded random offsets; the parent
    then checks the integrity of a copy of the store, that decisions equal the previous or the next
    generation, that the snapshot is absent or passes its gate, and that the 003 chunk invariants hold.
    The shape worked in probes (25 and 40 random SIGKILLs). [experiment]
  - Fault injection on a copy of the store trio: zero the header, truncate, flip an interior byte, delete
    the `-wal`, open a newer-format store. [experiment shapes]
  - A table over every mutating store method stating bump or no bump; applier tables; snapshot round trip
    and corruption cases; a main-thread assertion hook.
  - XCUITest kill and relaunch through `xcodebuild`: `XCUIApplication.terminate()` sends SIGKILL, but halts
    through the debug connection when Xcode is attached, so these run without a debugger. [documentation:
    `XCUIApplication.h`]
  - The simulator shares the host kernel, does not enforce data protection and cannot show power loss; all
    launch benchmarks run in Release; the device soak (quickstart) covers the rest.
- **Sources**: https://www.sqlite.org/testing.html ,
  `XCUIAutomation.framework/Headers/XCUIApplication.h` (lines 80 to 84).

## R17. Not measured yet (the phone)

| Question | Why it matters | Where it gets answered |
|---|---|---|
| Container open time, with and without the two-table migration, on a copy of the owner's 30,000-item store | the "Preparing your library" threshold and whether the migration is a one-time wait | S0 (signposts) |
| Time to first content frame and to results, Release, 30,000 and 100,000 photos | SC-004 | S5, S6 |
| Snapshot bytes, decode time, resident MB at 30,000 and 100,000 | SC-013 and the 3 MB estimate | S5 |
| Effective `synchronous` setting and sync behavior on a phone; `protectionKey` of `-wal` and `-shm` | R3 (device kernel not verified) | S0 probe |
| Bursts and hidden photos by id on a phone | the gate and visible-set check must not drop burst frames | S0 probe, before S4 ships |
| Whether the modification date changes for every edit that should drop a "remove" choice | R7 (one run each, simulator) | S9 soak |
| Cost of the launch-time quick check on the phone | decides the slim planner or the token (R13, R14) | S6 |
| No Home flash and no push animation on restore | FR-007 | S7, S9 |
| Time available after `.background` | sizing the flush budget (assumed under 5 s of work) | S9 |
| What an in-flight system delete does if the process dies | crash-point table row | S9 (observed, not controllable) |
| Limited access and the change token; token retention | only if R13 is built | later |

## What the hostile review changed

A review of the first design read the code and ran probes in a scratch copy of the package. It found
17 objections. The skeleton (revision-stamped disposable snapshot, photo-keyed choices, one commit
domain, commit-time gate, visible-set check) held. Results:

| # | Objection (severity) | Result |
|---|---|---|
| 1 | Every store call runs on the main thread; the open moves off-main too late (blocker) | **Adopted.** `DeferredStore` creates the `SwiftDataStore` off-main as stage S1, with an assertion hook (R2) |
| 2 | Patch-forward persists groups a rebuild would not form (blocker) | **Adopted.** Deleted; a removal bumps the revision and a normal rebuild follows (R6) |
| 3 | Measured size is a keeper input but did not bump the revision (major) | **Adopted.** `setSizes` bumps once per batch, only for none or estimate to measured (R5) |
| 4 | Removal executes live state, not what the sheet showed (major) | **Adopted.** Immutable `RemovalPlan`; no swap of results while a sheet is open (R10) |
| 5 | Delete All Data misses the pending writer and in-memory copies (major) | **Adopted.** Writer generation counter, cancel, clear, then delete, `setSizes` never inserts (R8) |
| 6 | Intent replay is under-specified; `removing()` leaves a phantom keeper selected (major) | **Adopted.** Event-sourced, normalized overrides; every `removing()` goes through the applier (R7) |
| 7 | The quick check still loads all 30,000 items at every launch (major) | **Not adopted here.** A slim planner input stays with 004 slim loading; recorded as a risk and in R14 |
| 8 | Builder invalidation relies on a human-bumped integer; add an app build stamp (major) | **Not adopted.** The human-bumped constant and golden test stay, with detector set, Pro flags, access level, time zone, calendar and the 7-day age limit; the build stamp is left as an owner option (plan, Risks) |
| 9 | The removal journal is redundant (minor) | **Adopted.** Dropped (R10) |
| 10 | The timed restore sentinel misfires both ways (minor) | **Adopted.** `restoreAttempts` counter (R9) |
| 11 | The snapshot header has no library access level (minor) | **Adopted.** Access level is part of the builder key; a Limited-access test |
| 12 | One global path conflicts with several windows (005) (minor) | **Adopted.** Scene-local path mirrored into the breadcrumb (R9) |
| 13 | A 60 s reconcile throttle conflicts with 001 FR-005a (minor) | **Adopted by omission.** Single-flight only, no throttle in v1 |
| 14 | Auto-quarantine is a destructive path driven by error-code folklore (minor) | **Adopted, stronger.** No quarantine in v1; volatile notice; explicit "Delete saved data" (R11) |
| 15 | A restored snapshot has stale sizes, so a kill restarts measurement (minor) | **Adopted.** Sizes overlaid from the store by id at restore (R5) |
| 16 | A 30-day "remove" expiry is longer than "mid-session" (minor) | **Adopted.** 7 days; the Continue row shows the restored count. The per-batch `decidedAt` suggestion was not adopted (per-photo times keep ordering exact) |
| 17 | The background flush needs `beginBackgroundTask` synchronously; privacy manifest reasons; export temp file; burst options (minor) | **Adopted.** Background time requested synchronously; the Saved screen reads sizes and times from the saved rows, not file attributes, so no new required-reason API is expected (to be confirmed in S8); no export is built here; one fetch-options factory with a device check (R10) |

Findings that held up and were kept as written: adding two entities migrates a 143 MB store in about
0.1 s on a Mac, 40 SIGKILLs during open were safe, `ResultGroup.id` changes with membership, the
selection resets on every foreground, and a cold launch likely builds twice.
