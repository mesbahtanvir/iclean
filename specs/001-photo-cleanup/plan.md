# Implementation Plan: Blurry & Duplicate Photo Cleanup

**Branch**: `001-photo-cleanup` | **Date**: 2026-10-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-photo-cleanup/spec.md`

## Summary

An iPhone app that scans the Photos library on the device and offers six cleanup
categories: duplicate photos, similar shots, blurry photos, screenshots, duplicate videos,
and large videos. Removal always goes through one summary sheet and then to Recently
Deleted. Built natively in Swift/SwiftUI. Analysis uses only Apple's on-device frameworks:
PhotoKit for library access with network access always off, Vision feature prints for
duplicates and similarity, and Laplacian sharpness plus Vision aesthetics for blur.
Results are cached in a local SwiftData store that is excluded from backup. There are no
third-party runtime dependencies and no network code (see [research.md](research.md)).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK

**Primary Dependencies**: Apple frameworks only: SwiftUI, PhotoKit (Photos), Vision,
Accelerate (vImage), Core Image, SwiftData. Development-time only: XcodeGen.

**Storage**: SwiftData store in Application Support; excluded from backup; file
protection `completeUntilFirstUserAuthentication`; no CloudKit (research R9)

**Testing**: Swift Testing (unit and accuracy tests in `CleanupKit`), XCUITest (UI and
no-network flows), static no-network script (research R12)

**Target Platform**: iOS 26.0+, iPhone only

**Project Type**: mobile-app (single iOS app + one local Swift package)

**Performance Goals**: ≥ 20 items/s analysis → 10,000 photos in < 10 min on an
iPhone 12-class device; repeat scan with no changes < 30 s; review grids scroll at 60 fps

**Constraints**: zero network access (app and PhotoKit requests); previews only, never
download originals; foreground-only scanning; resumable; pause on serious thermal state;
peak memory < 300 MB during scan

**Scale/Scope**: libraries up to 100,000 items; 10 screens (contracts/ui.md); 6 categories

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Gate | Pre-research | Post-design |
|-----------|------|:------------:|:-----------:|
| I. Local-Only Data | All data and analysis stay on device; no accounts; store excluded from backup and sync | ✅ | ✅ R9, data-model |
| II. No Outbound Network | No app networking; PhotoKit requests with network off; no telemetry or cloud AI | ✅ | ✅ R2, services contract guarantee |
| III. Offline-Safe Dependencies | No third-party runtime dependencies; dev tools only | ✅ | ✅ R13 (XcodeGen is dev-time only) |
| IV. User Owns Their Data | Explicit confirmation; Recently Deleted only; delete-all-data; documented storage | ✅ | ✅ R8, ui contract (Confirm, Settings) |
| V. Verifiable Privacy | Automated no-network checks; no network entitlements | ✅ | ✅ R12, quickstart Scenario 1 |
| Data Handling Constraints | Local protection, on-device logs, temp cleanup, opt out of cloud backup | ✅ | ✅ R9; logs use `os.Logger` on device only, no file contents logged |
| Workflow gate | Spec/plan has a "Data & Network" statement | ✅ | ✅ section below |

**Result**: PASS. No violations; Complexity Tracking not needed.

### Data & Network statement (required by constitution workflow)

- **Data touched**: Photos library metadata and ~512 px previews (read), removal requests
  (write via PhotoKit). Stored: fingerprints, scores, sizes, keep marks, scan progress.
- **Where stored**: the app's Application Support folder, excluded from backup, never
  synced.
- **Network**: none. No networking APIs in the code (enforced by
  `scripts/check-no-network.sh`); every PhotoKit request sets
  `isNetworkAccessAllowed = false`.
- **Note**: removing items from the Photos library makes iCloud Photos (if enabled) sync
  that removal. That is the user's own iCloud sync, run by iOS. iclean sends nothing.

## Project Structure

### Documentation (this feature)

```text
specs/001-photo-cleanup/
├── plan.md              # This file
├── research.md          # Phase 0: decisions R1–R14
├── data-model.md        # Phase 1: entities, rules, state machine
├── quickstart.md        # Phase 1: validation scenarios
├── contracts/
│   ├── services.md      # CleanupKit protocols and guarantees
│   └── ui.md            # Screens, states, accessibility ids
└── tasks.md             # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
project.yml                     # XcodeGen project definition
iclean/                         # App target (SwiftUI)
├── App/                        # App entry, dependency wiring
├── Features/
│   ├── Access/
│   ├── Home/
│   ├── Scanning/
│   ├── Results/
│   ├── Category/               # grid, group detail, photo viewer
│   ├── Confirm/                # summary sheet, done screen
│   └── Settings/
├── Resources/                  # Assets, Localizable strings (English)
└── PrivacyInfo.xcprivacy

Packages/CleanupKit/            # All logic; no UI
├── Package.swift
├── Sources/CleanupKit/
│   ├── Library/                # PhotoLibrary protocol + PhotoKit implementation
│   ├── Analysis/               # dHash, sharpness, feature print, aesthetics
│   ├── Grouping/               # duplicates, similar, duplicate videos
│   ├── Results/                # categories, keepers, default selection
│   ├── Scanning/               # scan pipeline, sessions, resume
│   ├── Removal/                # summary + removal
│   └── Store/                  # SwiftData models + Store
└── Tests/CleanupKitTests/
    ├── Unit/
    ├── Accuracy/               # SC-002, SC-003 against Fixtures/
    └── Fakes/                  # in-memory PhotoLibrary, Store

icleanUITests/                  # XCUITest flows, NoNetwork test plan
Fixtures/                       # Labeled test images and videos (R14)
scripts/
├── check-no-network.sh         # Static no-network check (R12)
└── seed-simulator.sh           # Import Fixtures/ into a simulator
```

**Structure Decision**: One iOS app target plus one local Swift package. The package
holds all logic behind the protocols in [contracts/services.md](contracts/services.md),
so it can be tested without a simulator. The app target contains only SwiftUI screens and
wiring. No backend exists or is allowed (Principle II).

## Risks & open items

- **Long-exposure detection (R5)**: no documented PhotoKit flag; verify on device early.
- **Blur accuracy on cloud-only previews**: may miss SC-003 for libraries that mostly use
  "Optimize Storage". Mitigation: label these results lower confidence; report accuracy
  separately for local vs preview-only fixtures.
- **Double confirmation**: iOS always shows its own delete prompt after our summary sheet.
  This can't be avoided, and it is acceptable under FR-012.
- **Size accuracy (R7)**: cloud-only sizes are estimates and shown as "about".

## Complexity Tracking

No constitution violations to justify.
