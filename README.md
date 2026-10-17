# iclean

An iPhone app that cleans up your photo library: duplicate photos, similar shots,
blurry photos, screenshots, duplicate videos and large videos. Free up iCloud space and
declutter the Photos app.

## Privacy

Everything stays on your iPhone. iclean never connects to the internet, needs no
account, and collects nothing. It reads only previews already on the phone and never
downloads photos from iCloud. Removed items go to **Recently Deleted** in the Photos app,
where you can restore them. See the [constitution](.specify/memory/constitution.md).

## Build

Requirements: macOS with Xcode 27 and an iOS 26+ simulator.
To put the app on your own iPhone, see [INSTALL.md](INSTALL.md).

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

Open `iclean.xcodeproj` and run the `iclean` scheme, or build from the command line:

```bash
xcodebuild build -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Test

Core logic (no simulator needed):

```bash
swift test --package-path Packages/CleanupKit
```

UI tests (run against a built-in demo library, no real photos needed):

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

No-network checks (constitution Principle V):

```bash
scripts/check-no-network.sh
```

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -testPlan NoNetwork
```

To try the app with test photos in a simulator's Photos library:

```bash
scripts/seed-simulator.sh "iPhone 17 Pro"
```

## Layout

- `iclean/` — SwiftUI app (screens and wiring)
- `Packages/CleanupKit/` — all logic: library access, analysis, grouping, removal
- `icleanUITests/` — UI tests
- `Fixtures/` — labeled test photos (see `Fixtures/README.md`)
- `specs/001-photo-cleanup/` — spec, plan, research and tasks (Spec Kit)

## Earlier design documents

`docs/` holds the design documents from an earlier iClean implementation (merged in
PR #1, replaced by this app). They are kept for reference only; where they differ from
`specs/001-photo-cleanup/` and the [constitution](.specify/memory/constitution.md)
(for example a paid unlock or third-party libraries), the specs and constitution win.
