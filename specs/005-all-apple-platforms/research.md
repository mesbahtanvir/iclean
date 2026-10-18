# Research: iclean on Every Apple Platform with iCloud Photos

Three research agents read the SDK headers for iOS, macOS, visionOS, tvOS, and watchOS, built
copies of the package and app for each platform in a scratch directory (the repository was not
modified), and inspected the installed sandboxed apps on the author's Mac. **Header-verified**
means read in an SDK header or a compile result. **Not verified** means documentation or
inference, to be checked on hardware (R6).

## R1. Platform verdicts

| Platform | Photos library API | Verified by build | Verdict |
|---|---|---|---|
| iPhone | Yes | Package builds for iOS | Supported today |
| iPad | Same SDK and APIs as iPhone | Same | Native; project and layout work only |
| macOS | Yes, availability identical to iOS for the used calls (macOS 10.13 to 10.15 and later), `NSImage` where iOS gives `UIImage` | Package builds universal for macOS 15; app fails with 7 errors in 5 files, all in UI code | Native |
| visionOS | Same as iOS, `UIImage`, availability identical | Package and app build for visionOS once the continued-task file is stubbed | Run as the iPad app now; native later |
| tvOS | Present (tvOS 10), same headers | Package builds | Out of scope on judgement |
| watchOS | No Photos framework in the SDK | The unmodified package fails: "Unable to resolve module dependency: 'Photos'" | Out of scope, proven by the SDK |

Why tvOS is out (reasons are documentation and inference, not header facts): the Apple TV photo
library is a view of the iCloud library over the network, so with the network off every preview
would be a degraded cloud preview; there is no durable app storage, and the 30,000-item store is
about 160 MB; the continued-processing task is unavailable; and there is no sensible way to review
and remove on a remote.

## R2. Minimum versions

The floor comes from the Vision Swift requests: `GenerateImageFeaturePrintRequest`,
`CalculateImageAestheticsScoresRequest`, and `DetectFaceCaptureQualityRequest` are available from
macOS 15, iOS 18, tvOS 18, and visionOS 2. SwiftData needs macOS 14 and iOS 17; PhotoKit needs far
less. The package today declares macOS 26, which no code requires: a scratch copy with macOS 15
built as a universal arm64 and x86_64 library. The new floors are iOS 18, macOS 15, visionOS 2.
The persistent-change observer is new in the 27 SDKs only (`PHPhotoLibraryPersistentChangesObserver`);
`fetchPersistentChanges` (iOS 16, macOS 13) is enough for incremental checks and works at the floor.

## R3. Staying alive on each platform

| API | iOS, iPadOS | macOS | visionOS |
|---|---|---|---|
| `BGContinuedProcessingTask` (iOS 26) | Yes | Unavailable | Unavailable (compile-verified) |
| `BGProcessingTask`, `BGAppRefreshTask` | Yes | Unavailable (the framework is) | Present, not verified to run |
| ActivityKit (Live Activities) | Yes | Unavailable | Not in the SDK |
| `ProcessInfo.beginActivity` | Not needed | The substitute (not header-checked) | |

On Mac the real interruptions are App Nap (a hidden or occluded window slows timers and I/O
severalfold), system sleep, closing the last window, and Command-Q. Chunked checkpoints make a
pause lossless, but a Vision or Photos request that straddles a sleep can hit the 20 s item limit
and be counted as a failure, so the scan must pause on the will-sleep notification and let 003
retry anything that failed around the wake.

The research proposed `ProcessInfo.beginActivity` with user-initiated and automatic and sudden
termination disabled, held only while scanning; observers for will-sleep and did-wake and for the
power state; the application delegate's `applicationShouldTerminateAfterLastWindowClosed` returning
false while scanning, and `applicationShouldTerminate` pausing the scanner; and the Dock tile for
progress. These are from documentation knowledge, not headers, and are covered by tests with
injected providers (plan D6).

## R4. Mac sandbox and the network

The Photos library entitlement `com.apple.security.personal-information.photos-library` is
confirmed present on installed sandboxed apps (read with `codesign -d --entitlements`). The same
apps carry `com.apple.security.network.client` as a separate key. **Decision**: the Mac app has
the sandbox and the Photos permission and nothing else. Without a network entitlement the sandbox
blocks the app's own sockets, so the constitution's "no network" rule is enforced by the system.
Photo downloads from iCloud are done by system services, not by the app, and the app keeps
`isNetworkAccessAllowed` false anyway. Not verified: that PhotoKit never needs the entitlement for
anything the app does; a Mac test with the entitlement absent proves it (task T041).

## R5. Portability map

About 93% of the non-test source is platform-neutral already: all 3,264 lines of `CleanupKit`
(`PhotoKitLibrary` needs about 10 lines), about 1,680 of 2,044 app lines, and every test line.
Platform-specific today: `ScanContinuation` (312 lines, iOS only) and the 51-line app shell.
UIKit appears only there and in one constant in the access screen. The macOS errors were all in
shared UI code that uses iOS-only toolbar placements, `fullScreenCover`, the navigation-bar title
mode, and `UIApplication.openSettingsURLString`. After the work, 88 to 90% is shared, about 650
lines platform-specific: iOS continuation 312, Mac keep-alive about 150, Mac shell about 100,
visionOS about 60, small helpers about 80. Layout stays in shared SwiftUI.

## R6. What only hardware can answer

1. Delete confirmation and Recently Deleted on a Mac and on a Vision Pro (headers are silent).
2. Whether `isNetworkAccessAllowed = false` holds on macOS, and what Optimize Mac Storage returns.
3. Behaviour under limited access on macOS and visionOS (asset counts, whether a limited-library
   picker exists).
4. Whether `requestAVAsset` file URLs are readable under the Mac sandbox (decides exact sizes for
   Large Videos).
5. Whether the compatible iPad app on Vision Pro reaches the continued-task code and falls back.
6. `UIDevice` battery state on Vision Pro; IOKit power source on every Mac model.
7. Vision feature-print revision and preview decoding differences against the iPhone, through the
   baseline library on each platform.
8. Whether the iPad shows Live Activities (the header cannot say).

## R7. Not adopted

- **Mac Catalyst**: would use `UIImage`, but the continued task and ActivityKit are unavailable on
  Catalyst and the Mac experience is worse than native.
- **"Designed for iPad" on Mac as the Mac app**: the zero-work fallback, but the continuation code
  would take the iOS path against APIs marked unavailable on macOS, and there would be no sandbox
  entitlement or Mac behaviours. Turned off in the project so it is never offered.
- **Intel Macs**: they compile (x86_64 slices exist) but have no Neural Engine; Vision is much
  slower and the item limit would be too tight. Excluded by `ARCHS`.
- **tvOS and watchOS**: R1.
- **Cross-device result sharing**: `PHAsset.localIdentifier` is device-local, and mapping
  identifiers across devices needs the network, which the constitution forbids.
