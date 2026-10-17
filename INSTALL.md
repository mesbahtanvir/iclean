# Installing iClean on your iPhone

There is no way around a Mac for this: iOS apps must be built and signed by
Xcode. Once it builds, getting it onto your phone takes about ten minutes.

## What you need

- A Mac with **Xcode 15.4 or newer** (App Store → Xcode)
- Your iPhone + a cable (or same-network Wi-Fi after the first wired install)
- An Apple ID. A **free** Apple ID works for personal installs, with the
  caveats in [Free Apple ID limitations](#free-apple-id-limitations) below.
  The paid Apple Developer Program ($99/yr) removes them and enables TestFlight.

## Steps

```bash
git clone https://github.com/mesbahtanvir/iclean.git
cd iclean
git checkout claude/iclean-photo-dedup-coh8ax   # until the PR merges

brew install xcodegen
xcodegen generate
open iClean.xcodeproj
```

Then in Xcode:

1. Select the **iClean** target → **Signing & Capabilities**.
2. Check **Automatically manage signing** and pick your **Team**
   (with a free Apple ID: Xcode → Settings → Accounts → add your Apple ID,
   then select the "(Personal Team)" entry).
3. Change the **Bundle Identifier** to something globally unique to you,
   e.g. `com.mesbahtanvir.iclean` (two apps can't share an id; `com.iclean.*`
   may already be taken).
4. Plug in your iPhone, unlock it, tap **Trust This Computer**.
5. Pick your phone in the device selector (next to the scheme name) and hit
   **Run** (⌘R).
6. First launch on device: iOS blocks apps from unknown developers once —
   on the phone, go to **Settings → General → VPN & Device Management**,
   tap your Apple ID, tap **Trust**. Launch again.

## Free Apple ID limitations

- **The app expires after 7 days** — just hit Run again to re-install.
  (Paid accounts: 1 year, plus TestFlight for cable-free installs.)
- **Max 3 sideloaded apps** at a time.
- **App Groups are not available to personal teams.** This project declares
  one (`group.com.iclean.shared`, used for the future widget). If signing
  fails on it: open `project.yml`, delete the whole `entitlements:` block
  under the iClean target, re-run `xcodegen generate`. The app handles the
  missing group automatically — the database falls back to the app's own
  Application Support directory (`AppDatabase.open()`); you only lose the
  v1.x widget, which doesn't exist yet anyway.

## Expectations for this first build

This codebase was written in a Linux environment with no Apple toolchain, so
**it has not been compiled yet** (see the README status note). The first
`xcodegen generate` + build on a Mac is the shake-out pass: expect some
compiler errors (API signature details, strict-concurrency annotations).
They should be mechanical to fix — paste the build log into a Claude session
on this repo and work through them.

Also worth knowing on first run:

- The paywall is inert until a StoreKit product
  (`com.iclean.unlock.lifetime`) exists in App Store Connect — the free
  allowance (your whole first cleanup session, ~100 items) works regardless,
  so you can exercise the full scan → swipe → commit loop.
- Run it against a test library first if you're nervous: everything it
  deletes goes to Photos → Recently Deleted (recoverable for ≥30 days), and
  nothing deletes without the system confirmation dialog — but this is
  pre-shake-out software touching your photo library; treat it accordingly.
- Useful smoke checks before installing on your phone:
  `cd Packages/iCleanCore && swift test`, then
  `cd Packages/iCleanData && swift test`.
