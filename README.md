# iClean

An iOS photo-cleanup app: turn the photo cleanup you've put off for years into a few 15-minute swipe sessions. All detection on-device, every proposal explained, nothing deleted without your commit — $2.99 once, no subscription.

## Design documents

| Doc | Covers |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Product & UX design: action taxonomy, card grammar, the two-level swipe deck, trust & safety design, IA, business model, competitive landscape, decision log, MVP scope |
| [docs/SCAN_PIPELINE.md](docs/SCAN_PIPELINE.md) | Scan pipeline (the read path): staged architecture S0–S7, data model, clustering & scoring algorithms, scheduling & governors, incrementality, performance budgets, build order |
| [docs/APP_PLATFORM.md](docs/APP_PLATFORM.md) | App platform (the write path): commit engine, photo-library authorization, StoreKit 2 entitlements, on-device telemetry, module architecture, release & privacy checklist |

## Code layout

Module map per APP_PLATFORM.md §1 — one-way dependencies, `import Photos` appears in exactly one module:

```
Packages/
  iCleanCore/        PhotoGateway (the PhotoKit boundary + PhotosGateway impl)
                     ScanEngine  (S0–S7 pipeline: hashing, clustering, scoring,
                                  sessionizer, detectors, orchestrator — UIKit-free)
                     FixtureKit  (mock gateway + synthetic pixel fixtures)
  iCleanData/        ProposalStore (GRDB schema, pipeline store, deck store)
                     CommitEngine  (allowance gate → re-validation → chunked
                                    atomic commits → journal → receipts)
                     Entitlements  (StoreKit 2 + Keychain allowance counter)
  iCleanUIKit/       iCleanUI    (SwiftUI: home, deck, cluster grid, commit, summary)
App/                 App target sources (composition root, auth gate, BG task)
project.yml          XcodeGen spec for the iClean app target
```

## Building

Requires a Mac with Xcode 15.4+ (iOS 16.0 deployment target).

```bash
brew install xcodegen
xcodegen generate      # produces iClean.xcodeproj
open iClean.xcodeproj  # select the iClean scheme, run on device/simulator
```

Package tests (no app target needed):

```bash
cd Packages/iCleanCore && swift test    # pure-logic tests: hashing, band index,
                                        # sessionizer, kernel, calibration, clusterers
cd Packages/iCleanData && swift test    # store: migrations, CAS verdicts, undo,
                                        # suppression, retry schedule, allowance gate
```

Before shipping, complete the release checklist in APP_PLATFORM.md §7 (privacy manifest, App Group identifier, StoreKit product setup).

> **Status / honesty note:** this codebase was authored in a Linux environment
> with no Apple toolchain available, so it has **not yet been compiled**.
> The architecture, algorithms, and data model follow the design docs exactly,
> and the pure-logic modules carry a test suite — but expect a shake-out pass
> of compiler fixes (API signatures, concurrency annotations) on first build.
> Treat `swift test` in both packages as the first task on a Mac.
