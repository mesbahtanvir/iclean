# Installing iclean on your iPhone

There is no way around a Mac for this: iOS apps must be built and signed by
Xcode. Once set up, getting it onto your phone takes about ten minutes.

## What you need

- A Mac with **Xcode 27** (App Store → Xcode)
- An iPhone running **iOS 26 or newer** (the app's deployment target) + a cable
  (or same-network Wi-Fi after the first wired install)
- An Apple ID. A **free** Apple ID is enough — the app uses no App Groups,
  no push, no in-app purchases, nothing beyond photo-library access, so it
  signs cleanly with a free "Personal Team." The free-account caveats:
  the install **expires after 7 days** (just hit Run again) and you can have
  at most 3 sideloaded apps at a time. The paid Apple Developer Program
  ($99/yr) removes both and enables TestFlight.

## Steps

```bash
git clone https://github.com/mesbahtanvir/iclean.git
cd iclean
brew install xcodegen
xcodegen generate
open iclean.xcodeproj
```

Then in Xcode:

1. Select the **iclean** target → **Signing & Capabilities**.
2. Check **Automatically manage signing** and pick your **Team**. (With a
   free Apple ID: Xcode → Settings → Accounts → add your Apple ID, then
   select the "(Personal Team)" entry. `project.yml` deliberately leaves
   `DEVELOPMENT_TEAM` empty so this stays a local choice.)
3. The bundle identifier is `com.mesbahtanvir.iclean`. If you're not
   @mesbahtanvir, change it to something unique to you — two apps can't
   share an id.
4. Plug in your iPhone, unlock it, tap **Trust This Computer**.
5. Pick your phone in the device selector (next to the `iclean` scheme) and
   hit **Run** (⌘R).
6. First launch on device: iOS blocks apps from unknown developers once —
   on the phone, go to **Settings → General → VPN & Device Management**,
   tap your Apple ID, tap **Trust**. Launch again.

## Try it in a simulator first (optional, recommended)

You can exercise the whole app against seeded test photos without touching
your real library:

```bash
scripts/seed-simulator.sh "iPhone 17 Pro"
xcodebuild build -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Then run the `iclean` scheme on that simulator from Xcode.

## Before trusting it with your library

- Quick smoke check (same tests CI runs):
  `swift test --package-path Packages/CleanupKit`
- Everything the app removes goes to **Photos → Recently Deleted** and is
  recoverable there for at least 30 days; nothing is removed without the
  system confirmation dialog. Still, on a first install, review what it
  proposes before confirming large batches.
- The app never uses the network (enforced by `scripts/check-no-network.sh`
  in CI and the constitution's Principle V), so nothing about your library
  leaves the phone.
