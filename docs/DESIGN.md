# iClean — Product & UX Design Document

**Status:** Draft v1 (brainstorm consolidation)
**Date:** 2026-08-12
**Scope:** Product vision, action taxonomy, swipe-UI interaction architecture, trust design, information architecture, business model, MVP scope.

---

## Table of Contents

1. [Product Vision & Positioning](#1-product-vision--positioning)
2. [Business Model](#2-business-model)
3. [Platform & Technical Foundation](#3-platform--technical-foundation)
4. [The Action Taxonomy](#4-the-action-taxonomy)
5. [Cross-Cutting Principles](#5-cross-cutting-principles)
6. [Card Grammar — Four Shapes](#6-card-grammar--four-shapes)
7. [Interaction Architecture — The Two-Level Deck](#7-interaction-architecture--the-two-level-deck)
8. [Gesture Vocabulary](#8-gesture-vocabulary)
9. [Trust & Safety Design](#9-trust--safety-design)
10. [Information Architecture & Screens](#10-information-architecture--screens)
11. [Session Design & Maintenance Mode](#11-session-design--maintenance-mode)
12. [Competitive Landscape](#12-competitive-landscape)
13. [Decision Log](#13-decision-log)
14. [Open Questions](#14-open-questions)
15. [MVP Scope & Roadmap](#15-mvp-scope--roadmap)
16. [Non-Goals](#16-non-goals)

---

## 1. Product Vision & Positioning

**iClean turns the photo cleanup people put off for years — a lost afternoon in the Photos app — into a few 15-minute swipe sessions.** The compression is structural: a 3,000-item backlog collapses into ~350 swipe decisions across 6–8 short decks (§11), because cluster and batch proposals let one decision cover many photos.

The pain is not detection — since iOS 16, Apple Photos has a Duplicates album, and Google Photos has cleanup suggestions. The pain is **triage**: reviewing thousands of flagged photos in Apple's UI is miserable, Apple only catches exact/near-exact duplicates, and neither platform touches blurry shots, similar-shot clusters, screenshots, or expired ephemera (boarding passes, dead QR codes, old parking receipts).

iClean's value proposition:

- **Detection intelligence** Apple and Google don't offer (similar clusters, blur, OCR-dated ephemera).
- **A fast, safe decision workflow** — the swipe deck — that makes reviewing thousands of proposals feel like a game rather than a chore.
- **Radical trust**: everything on-device, every proposal explained, nothing deleted without the user's explicit commit, four stacked safety nets.
- **Anti-subscription pricing**: one cheap, one-time purchase in a category notorious for $8/week subscription traps.

Positioning line: *"Photos found your 214 duplicates. iClean found 3,900 more — and you approve every single action."*

### The four seed scenarios

The founder's original examples anchor the design and are referenced throughout as seeds (a)–(d):

- **(a)** Show a cluster of similar images with the best-quality shot pre-selected to keep — one yes/no on the whole proposal.
- **(b)** Delete all screenshots as a single category action.
- **(c)** Delete old boarding passes and similar expired ephemeral documents.
- **(d)** "Merge" a group of near-identical photos into one — keep one representative, delete the rest.

## 2. Business Model

**Free download → free full scan → one-time ~$2.99 unlock to delete without limits.**

- **Free forever:** full scan with real numbers, full-resolution preview of every proposal, every reason string, full swipe/triage (decisions can be staged for free), and a **real free deletion allowance: the entire first cleanup session** (the training-wheels session of §9.5, up to ~100 items). The allowance is deliberately sized to cover session 1 completely, so the trust loop finishes before the gate ever appears.
- **Paid ($2.99, once):** unlimited deletion execution. Optional garnish (never gates): cleanup report export, standing rules, scheduled re-scans.

Why the free allowance is critical: the user must experience the *entire* loop — swipe → stage → delete → verify in Recently Deleted → restore one to test — before spending a cent. A paywall before the first delete asks for money before trust exists; the category's reviews name paywall-after-scan-before-delete as "hostage-taking" when combined with subscriptions. A one-time price plus a real allowance defuses it.

Paywall framing (anti-ransom): *"You've staged 1,204 photos (9.7 GB). Everything you've seen and decided is yours. Unlock unlimited deletion for $2.99 — once, forever. No subscription, no upsells, and your first cleanup session was on us."*

Rules:

- The price is visible from the first session's footer ("Free: preview everything + your whole first cleanup. $2.99 unlocks the rest."). No ambush after invested effort.
- If the user declines the paywall, **their staged decisions persist**. Punishing non-payment by discarding triage work is hostage-taking.
- No countdown timers, no fake discounts. *"$2.99 once. That's the whole business model."* is itself the copy.
- Implementation (StoreKit 2 machinery, restore, Family Sharing, allowance integrity): APP_PLATFORM.md §4.

*As of 2026-10-24 iclean is free, with no paid features (specs/016-free-photos-only/spec.md). This section's paywall, and the 2026-10-18 idea of a $2 Pro purchase that unlocks video analysis, are not built and will not be.*

## 3. Platform & Technical Foundation

*Implementation detail: the scan/read path lives in [SCAN_PIPELINE.md](SCAN_PIPELINE.md); the commit/write path, photo-library authorization, entitlements, module architecture, and release checklist live in [APP_PLATFORM.md](APP_PLATFORM.md). Minimum deployment target: **iOS 16.0** (required by persistent change history; aligned with the Face ID-locked Recently Deleted flow).*

**iOS-first, fully on-device.** The photo mess lives on the phone; iOS users pay for apps; on-device processing means zero server cost (which is what makes a one-time price viable) and a privacy story subscription competitors can't match: *"your photos never leave your phone."*

### Detection signals available on-device

| Signal | Source & availability |
|---|---|
| Exact file hash | Original bytes — **only for assets whose originals are on device** (constraint 1). For iCloud-evicted assets, exact-dupe detection falls back to resource-metadata equality (original filename, pixel dimensions, creation date, resource file size) + thumbnail perceptual hash. |
| Perceptual hash (dHash/pHash) | thumbnail math |
| Similarity embeddings | Vision `VNGenerateImageFeaturePrintRequest` on thumbnails |
| Blur score | Laplacian variance on thumbnails |
| Screenshot flag | `PHAssetMediaSubtype.photoScreenshot` (free at fetch time) |
| OCR / text, barcodes, QR | Vision text recognition + barcode detection on thumbnails |
| Faces, landmarks, capture quality, saliency | Vision. **"Eyes open" is not an Apple output** — it is derived from eye-landmark geometry (custom, tunable, with its own error rate). |
| Timestamps, location, pixel dimensions, duration | `PHAsset` metadata (free at fetch time) |
| Camera model / exposure / lens EXIF | **Original bytes only — not on `PHAsset`.** Gate on locally-available originals; substitute free signals where possible (`smartAlbumSelfPortraits` for front-camera detection, `PHAssetResource.originalFilename` patterns + UTI for "no camera" heuristics). |
| Burst / Live Photo / panorama / favorite flags, album membership | PhotoKit (free at fetch time) |
| Edited flag | Derived from `PHAssetResource` lists (adjustment data present) — cheap but a per-asset call; belongs in the thumbnail-math tier, not the instant tier. |
| File size | **No public API.** The undocumented `PHAssetResource` `"fileSize"` KVC key works without downloading but is unsupported — keep a dimensions×format fallback estimate and validate totals against Settings → Storage. The reported size is the full original's size even when only a thumbnail is local — the right number for iCloud-quota savings, not device-space savings (§13 #7). |

### Hard technical constraints (design around these from day one)

1. **Thumbnail-only pipeline.** "Optimize iPhone Storage" users — the core audience, they're the ones out of space — do not have full-res originals on device. All photo detection runs on ~500 px thumbnails. Full-screen inspection requests the best *locally available* image (`isNetworkAccessAllowed = false`), with an explicit "load sharper version" tap that may use the network — never the full original. Scanning must never trigger mass iCloud downloads on exactly the users with no space left. **The app does not analyze videos** (decision of 2026-10-18, photos only; video analysis is not in the app, and there is no paid version; see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md): no video frame is opened for analysis, hashed, fingerprinted or compared, so there is no poster-frame pass, no multi-frame detector and no frame sampling for videos. A poster frame or preview shown to the user for display is not analysis. Analysis reads only a video's metadata (size, duration, dates, filename), and the video is marked "metadata only", which is not the "needs connection" tail bucket (that is for photos that only iCloud has). **Audio is invisible** to the pipeline everywhere (see taxonomy notes). Transcode/compression offers require locally-available originals and are gated on charging + Wi-Fi.
2. **Recently Deleted is a ≥30-day buffer.** Deletion via `PHAssetChangeRequest.deleteAssets` moves assets to Recently Deleted; space is not freed until it purges (Apple says 30 days; actual purge can take up to ~40 and isn't queryable), and the app cannot enumerate, empty, or restore it programmatically. There is also **no supported deep link** into that album — post-commit guidance opens the Photos app with illustrated steps (Albums → Utilities → Recently Deleted, which is Face ID-locked since iOS 16) for "empty it now to free space immediately."
3. **One system dialog per batch.** iOS shows one confirmation per `deleteAssets` request. Accumulate all approvals across the session into a single commit — this both minimizes dialog fatigue and makes "silent deletion" structurally impossible (a trust asset: the OS proves the app can't delete behind the user's back). Very large commits chunk at 500–1,000 assets for reliability (APP_PLATFORM.md §2); when more than one chunk is needed, the review screen says so up front ("iOS will ask you to confirm N times") — the one-dialog promise is per-chunk, stated honestly. Chunk-size validation: §14.5.
4. **Incremental, tiered scanning.** Free `PHAsset` metadata (subtypes, dates, dimensions, flags) powers instant first results; cheap thumbnail math (hashes, Laplacian, luminance) follows within seconds; expensive Vision passes (OCR, embeddings, faces) stream in progressively. The UI grows as analysis deepens — buckets unlock on the hub as they finish; the user starts swiping ~10 seconds after install. Every swipe is persisted immediately; the app is fully resumable mid-scan and mid-deck.
5. **No view counts.** PhotoKit exposes no "last viewed" data. "Photos you never look at" can only be *proxied* (not favorited + not edited + not in any album) and must be labeled honestly as such.

## 4. The Action Taxonomy

Every action below is a *proposal type* the app can generate. Columns:

- **Unit** — the decision granularity: `photo` (one swipe per item), `cluster` (one yes/no on a proposed group outcome), `batch` (one yes/no on a whole category), `rule` (a standing policy).
- **Regret** — how likely a user later wishes they hadn't (drives presentation; see §9).

### 4.1 Exact & Redundant Duplicates

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Exact Duplicate Collapse | Byte/pixel-identical copies (re-imports, AirDrop re-receives). File hash when the original is local; for iCloud-evicted assets, resource-metadata equality + thumbnail pHash. | cluster | low | Near-zero false positives — the trust-building opener. Card copy says "identical copy" only when byte-verified; metadata-matched pairs say "near-certain copy." Keep the copy with richest metadata / album membership so links don't break. |
| Near-Duplicate Copy Collapse | Re-saved, re-compressed, resized copies (WhatsApp re-compression, "Save Image" of your own upload). pHash distance ≤2 with differing size/format; keep highest resolution. | cluster | low | Show *why* the keeper wins (resolution badge). Trap: intentional crops/filters can hash near-identically — check dimension ratios + edited flag. |
| Original + Edited Pair Collapse | Separate original & edited assets (third-party editor exports). Edited flag / adjustment data + pHash + identical capture EXIF. | cluster | medium | Default: keep the edit; one-tap reverse (some users keep originals as negatives). iOS's built-in editor stores the original inside the same asset — no savings there. |
| RAW+JPEG Pair Cleanup | RAW files with a JPEG/HEIC sibling. PHAssetResource types; timestamp matching for separate assets. | batch | medium | 25–75 MB per RAW. Photographers will scream — batch with exception grid; smart default: "keep RAW only for Favorites." Two storage shapes: separate assets (straightforward delete) vs. RAW embedded as an `.alternatePhoto` resource / ProRAW DNG — PhotoKit cannot strip a resource from an asset, so embedded pairs require recreate-and-delete (§4.8 mechanics) and are out of MVP. |
| Duplicate Video Collapse | Identical / re-compressed videos. File hash + frame sampling for locally-available videos; evicted videos matched via duration ±0.5 s + poster-frame pHash + resource metadata. | cluster | low | The largest per-decision GB wins in the app. Multi-frame confirmation was designed to be local-only. **Not in the app since 2026-10-18:** the app does not analyze videos, so it has no Duplicate Videos category; video analysis is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |
| Re-received Chat Copy Dedup | Same image saved 3+ times from different chats. pHash clusters among no-camera-EXIF assets, dates spread across days. | cluster | low | All members are received copies — easy yes. |
| Frame-Grab Dedup | Stills exported from a video that still exists (poster frames, "save frame"). pHash match against sampled frames of kept videos. | cluster | low | Show the source video on the card. **Not in the app since 2026-10-18:** it needs frame analysis of videos, which the app does not do; video analysis is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |

### 4.2 Similar Shots, Bursts & Series

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Similar Cluster Keep-Best | 5–30 shots of the same scene within minutes (seed example a). Feature-print clustering gated by time (<10 min) + location; keeper scored by sharpness + face quality (eyes open) + saliency + resolution. | cluster | medium | **The core product.** Card must support "swap the keeper" and "keep 2" without leaving the card. Trap: narrative sequences (kid opening a present) — time-spread and pose-variance lower confidence. |
| Burst Collapse | Burst stacks; keep best frame. Burst flag + burstIdentifier; Apple's own pick as a prior. | cluster | low | Lower regret than generic clusters. Exception: action/sports bursts — motion peak beats sharpness; offer a filmstrip scrubber. |
| Selfie Spree Trim | Runs of 5–50 near-identical selfies. Selfies smart album (`smartAlbumSelfPortraits`) + same face + similar framing + tight time window. | cluster | medium | Aesthetics are personal — propose keeping top 2–3, never 1; never auto-batch. |
| Exposure Bracket / HDR Cleanup | 3–5 shot brackets where one good exposure exists. Sub-2-second timestamp runs with identical framing by pHash; exposure-bias EXIF confirmation only when originals are local. | cluster | low | Niche (third-party camera apps, imports) but pure junk when present. |
| Failed Panorama Cleanup | Aborted panoramas; overlapping stills shot "to stitch later." Panorama subtype + extreme aspect ratios; overlap detection near a kept pano. | cluster | low | Tiny-width aborted panos are near-certain junk; overlapping stills only proposed when a successful pano from the same minute exists. |

### 4.3 Quality Failures & Accidental Shots

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Blurry Photo Purge | Motion-blur / out-of-focus with no sharp sibling. Laplacian variance tiers. | photo | medium | Traps: bokeh, long-exposure art, fog. Severe blur + no face + no saliency may present as a pre-checked batch; borderline stays swipe-per-photo. If a sharp near-dupe exists, route to Keep-Best instead. |
| Dark / Underexposed Purge | Near-black shots. Mean luminance + histogram; faces/saliency still detectable ⇒ legit night shot. | photo | medium | Night mode, concerts, candles are dark on purpose — require multiple agreeing signals. |
| Pocket Shot Purge | Pocket linings, floors, ceilings. Compound: very dark OR very blurry + no faces + near-zero saliency + odd orientation. | batch | low | With 4+ agreeing signals, one-tap batch with exception grid. A delight category ("it found my 92 pocket photos"). |
| Blank Frame Purge | Solid black/white/grey frames. Pixel variance ≈ 0. | batch | low | Essentially zero false positives; fold into pocket-shot batch. |
| Corrupt / Zero-Byte File Purge | Unreadable, truncated, or zero-byte assets. Thumbnail generation fails / resource size ≈ 0. | batch | low | Essentially free to detect, zero regret — belongs in the trust-building opener class alongside blank frames. |
| Finger-Over-Lens Purge | Partially occluded shots. Uniform corner-anchored low-frequency blob + confined saliency. | photo | medium | May be the only photo of a moment — check for an unoccluded sibling first. |
| Eyes-Closed Dud Removal | Blink shots when an eyes-open sibling exists in the cluster. Face landmarks compared across temporal cluster. | cluster | low | Only propose when a better take exists. Surface the reason ("eyes closed here, open here"). |

### 4.4 Screenshots & Digital Ephemera

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Screenshot Category Sweep | All screenshots by age bucket (seed example b). Screenshot subtype + age. | batch | medium | Never a blind "delete all" — screenshots hide keepers (payment confirmations, IDs). Age-bucketed with exception grid; better: route recognized sub-types to the actions below, sweep the remainder. **Review-only until OCR ships (v1.x):** the chat-screenshot exclusion below is OCR-dependent, so the MVP Screenshots Plan card starts a drill-in review instead of offering queue-all (§15). |
| Expired Boarding Pass & Ticket Purge | Passes/tickets whose date passed (seed example c). Barcode detection (PDF417/Aztec/QR) + OCR patterns (airline codes, flight numbers) + extracted date < today. | rule | low | **Poster child for standing rules** — regret decays to zero with time. Trap: locale date parsing; unparseable dates fall back to screenshot age. First proposal is a batch; graduates to a rule after repeat acceptance. Competitor research found *no* app doing this. |
| OTP, QR & Verification Code Purge | 2FA codes, one-time QR codes, wifi passwords, delivery codes. OCR patterns ("verification code", 6-digit blocks) + QR detection. | batch | low | Value expires in minutes-to-days. Exception: OCR for "recovery/backup codes" and exclude with a warning. |
| Expired Receipt, Coupon & Parking Purge | Parking sessions, expired promos, delivered-order tracking. OCR keywords + past dates. | batch | low | Split "expiring things" (safe) from "proof-of-purchase" (offer album filing instead). |
| Map & Directions Screenshot Purge | Map/navigation screenshots. OCR + map-tile texture. | batch | low | Very safe once >30 days old. |
| Meme Triage | Saved/screenshotted memes. Caption-style OCR blocks, app-generated filenames/UTIs, social-app chrome. | photo | medium | Some users curate memes — age-bucketed swipe deck (oldest first) with a "file into Memes album" alternative; capped at photo level per §5.7; never a rule. |
| Chat Screenshot Triage | Conversation screenshots. OCR + message-bubble layout detection. | photo | **high** | The highest-regret screenshot type (evidence, sentiment, legal). Swipe-per-photo only; never batched, never ruled; **excluded from all sweeps by default**. Detection is OCR-dependent (v1.x) — which is why MVP screenshot sweeps are review-only (§15). |
| Shopping Screenshot Triage | Product pages, carts, order confirmations. OCR of prices/store chrome. | photo | medium | Order confirmations may be needed for returns; >90 days moves most to safe. |
| Dev/Test Screenshot Spree Collapse | Rapid near-identical UI screenshots. Screenshot subtype + tight window + high pHash similarity. | cluster | low | Treat like a burst: keep the last ("final state"). |

### 4.5 Captured Documents & Text

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Document Re-shoot Collapse | Multiple shots of the same page. OCR density + rectangle detection + similarity within a window; keep sharpest **on text regions**. | cluster | medium | Show a zoomed text crop on the card so the user confirms legibility. |
| Whiteboard & Slide Session Collapse | Re-shoots of the same board/slide. Rectangle + OCR + bright quadrilateral; cluster within event window. | cluster | medium | Within-session dedupe is safe; deleting whole sessions is not (work notes). Pair with "file to Work album." |
| Old Receipt Photo Purge | Camera photos of paper receipts. OCR (totals, merchant headers) + tall narrow aspect. | photo | **high** | Tax/warranty danger zone — capped at per-photo review per §5.7. Default threshold >2 years, explicit opt-in, filing primary / deletion secondary. |
| Screenshot → PDF Consolidation | Multi-page document screenshots merged into one PDF in Files, then deleted. Sequential same-app screenshots + OCR continuity. | cluster | medium | The "organize" sibling for documents; reclaims space *and* improves the document. |
| Document Filing *(non-delete)* | IDs, insurance cards, business cards, contracts → topical albums. OCR density + layout heuristics. | cluster | low | Zero-regret palate cleanser between destructive decks. |

### 4.6 Saved & App-Generated Media

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Messenger Auto-Saved Media Sweep | WhatsApp/Telegram auto-saved media flooding the library. App-generated filenames (`PHAssetResource.originalFilename`) + missing location + recompression signatures + creation-time bursts matching chat activity. | batch | medium | Silently 30%+ of some libraries. Lower real regret — copies remain in the chat app; **say so on the card**. Age-bucket + exception grid. |
| Web-Saved Image Sweep | Browser/social saves (tried wallpapers, reference pics). Non-camera filenames/UTIs (PNG/WebP), odd dimensions, no location. | photo | medium | Too heterogeneous to batch — oldest-first swipe deck. |
| Third-Party App Export Cleanup | Collages, filtered exports, sticker outputs whose source photos survive. EXIF software tag + pHash link to source. | photo | medium | The collage may be the keepsake — show source linkage on the card. |
| GIF / Animated Sticker Purge | Saved GIFs from keyboards/messengers. Format + loop flags. | batch | low | Pure junk for most users. |

### 4.7 Video Cleanup

*Family note: the app does not analyze videos (video analysis is not in the app, and there is no paid version; see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md): no poster frame or other frame is opened for analysis, hashed or compared, so only actions that need metadata alone (size, duration, filename) are in the free app, and the rows below that sample frames are marked "not in the app". iCloud-evicted videos still appear in the Largest Files queue, because metadata is enough to review them (§3 constraint 1).*

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Screen Recording Sweep | Screen recordings (bug reports, how-tos). Primary signal: `originalFilename` patterns (`RPReplay_Final*`, `ScreenRecording_*`); dimensions = device resolution as corroboration (no screen-recording media subtype exists). | batch | medium | Excellent GB-per-decision. >90 days pre-checked. Trap: recorded video calls with family — a face pass on sampled frames (local videos) demotes those to per-item. **Not in the app since 2026-10-18:** the face pass, because it needs video analysis, which is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |
| Accidental Pocket Video Purge | Videos of pockets/floors — dark, long. All sampled frames dark/low-variance + no faces. | photo | low | A 20-minute pocket video can be 2 GB — hero moment for the meter. Show a frame strip; **audio can't be checked** — never fully batch. **Not in the app since 2026-10-18:** it needs video analysis, which is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |
| Micro-Video Purge | Sub-2-second accidental videos. Duration threshold. | batch | low | Very safe. Duration alone is the filter — but beware genuine keepers (exported Live Photo clips, sticker videos). |
| Shaky / Unwatchable Video Review | Concert floors, walking footage. Frame-to-frame pHash instability + low sharpness on all samples. | photo | medium | **Audio may be the point** (concerts) and is invisible to detection — card must say "check the sound before deleting." **Not in the app since 2026-10-18:** it needs video analysis, which is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |
| Video Trim Proposal | Videos with dead air / pocket footage at the ends. Frame variance profile across sampled frames. | photo | medium | Trim beats delete — a partial-asset action. Requires local original; gate accordingly. **Not in the app since 2026-10-18:** it needs video analysis, which is not in the app, and there is no paid version (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md). |
| Long Video Review Queue | Top-N largest/longest videos. Size/duration sort. | photo | **high** | Not detection — prioritization. ~40% of reclaimable GB often lives in a dozen files. Rich per-item presentation, never batched. |

### 4.8 Space Reclaim Without Deletion

*Mechanics note: PhotoKit cannot replace an asset's bytes in place, and the Photos edit pipeline keeps originals inside the asset (no savings). Every conversion below is really **recreate-and-delete**: storage temporarily increases, savings are deferred until Recently Deleted purges (~30 days), the new asset gets a new identity (albums, favorite, hidden state must be re-applied in the same transaction; edit history and shared links are lost), and iCloud re-uploads it. The UI must disclose the deferred savings, and conversions run in small charged/Wi-Fi batches — the temporary space increase is a real constraint for exactly the full-disk users who want this.*

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Live Photo → Still Conversion | Live Photos where motion adds nothing (documents, static scenes). Live flag + low motion across paired video frames; exclude faces. | batch | medium | Video component ≈ 2× the still's size across thousands of photos. Motion is irrecoverable after the 30-day window — be honest about that. |
| Slo-mo / Time-lapse / Cinematic Conversion | 240 fps slo-mo and cinematic (depth data) among the largest per-asset files. Media subtype + codec metadata. | batch | medium | "Convert to normal video / strip depth" — big loss-free reclaim nobody offers. Requires local original. |
| JPEG/PNG → HEIC Recompression | Old large JPEGs, PNG screenshots (40–60% smaller as HEIC). Format + size vs estimate. | batch | medium | Must copy EXIF across. Opt-in, quality note, never touch Favorites/edited by default. |
| H.264 → HEVC Transcode | Old H.264 videos (~½ size in HEVC). Codec metadata + bitrate. | batch | medium | Needs full originals — conflicts with thumbnail-only constraint; gate on locally-available + charging. Background queue, not a swipe. |
| Oversize Screenshot Downscale | Full-retina screenshots that only get glanced at. Subtype + native dimensions + size. | rule | medium | Downscaling kills small text — only for non-document screenshots. Marginal; candidate to cut. |

### 4.9 Time, Place & Event Sweeps

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Event Cluster Review Session | One event (wedding, trip day) as a guided mini-session combining keep-best + duds. Time + location density clustering. | cluster | medium | A *packaging* action — re-frames existing proposals under a memorable header ("Sarah's wedding: 214 photos, keep 60?"). Context lowers regret. |
| Location Dump Review | Dense dumps at one location (conference, museum placards). Location cluster + photos/hour + low face count. | batch | medium | Placard photos are never-look-again content; exclude the shots with faces (companions). |
| Cold Archive Review | Old (3+ yr) photos with no engagement signals. Age + NOT favorited/edited/in-album. | photo | **high** | A router, not a sweep — the riskiest family: old + unengaged is what irreplaceable memories look like. Never a one-tap batch; feed old *junk-classified* items through their own actions with age as a confidence booster, and review any remainder per-photo. Label honestly ("not in any album, never favorited") — never "never viewed" (unknowable). |
| Largest Files First Queue | Top-N largest assets regardless of type. Size sort + detector annotations. | photo | medium | The efficient frontier of GB-per-swipe. Entry mode for the "free up space NOW" goal. |
| Post-Event Cleanup Prompt | Fresh dumps 24–72 h old ("you took 300 photos yesterday"). Detection stack over the new event cluster. | cluster | low | Timing inverts regret: memory is fresh, judgment is sharpest. **The retention hook** that turns a one-time purge into a habit. |

### 4.10 Organization & Curation (Non-Delete)

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Auto-Favorite the Best | The standout shot of each event/cluster → iOS Favorite. Keep-best scoring at event level. | cluster | low | Fully reversible, pure delight — and favorites become a protection signal for every destructive action. |
| Similar-Photo Stacking | Clusters kept whole but viewed as one (non-destructive variant of seed d). Same clustering as Keep-Best. | cluster | low | iOS has no stack primitive — app-managed album + in-app collapsed gallery. Set expectations: collapsed only inside iClean. |
| Album Filing Suggestions | Keep-worthy screenshots/documents/memes → topical albums. Same classifiers as deletion actions. | batch | low | Turns keep/delete binary into keep/file/delete — filing absorbs the anxious middle and raises completion. |
| Duplicate-in-Album Reconciliation | Deleting a dupe would remove it from an album — swap the keeper in first. Album membership diff across cluster. | cluster | low | Deleting an asset removes it from every *user-created* album — swap the keeper in automatically where possible. Scope: PhotoKit can only modify user-created albums (`canPerform(.addContent)`); shared, smart, and synced albums are read-only to apps, and iCloud Shared Albums hold independent re-encoded copies that library deletion never touches (worth an FAQ entry). |
| Archive-Offload | Export to Files / zip / Mac, then delete. User-directed. | cluster | low | The escape hatch for high-anxiety items (long videos, old documents): *out of Photos but not gone.* No competitor offers it. |
| Sensitive-Photo Vaulting | Detected IDs, credit cards, intimate content → suggest iOS Hidden album (Face ID-locked). OCR + classifier. | photo | low | Suggestion only — never auto-move. IDs/cards via OCR + document heuristics is uncontroversial; nudity detection needs a custom on-device classifier (Apple's SensitiveContentAnalysis detects nudity only and requires a case-by-case managed entitlement). All detection on-device and reflected in the privacy nutrition label. |
| Stale Album Cleanup | Empty/duplicate/stale user albums. Album metadata. | batch | low | Organization-side hygiene. |

### 4.11 Standing Rules (Set-and-Forget Policies)

| Action | Targets & detection | Unit | Regret | Notes |
|---|---|---|---|---|
| Ephemera Aging Rules | Per-subtype policies: boarding passes 7 days after flight, OTP/QR after 1 day, parking 30 days, maps 30 days, screen recordings 90 days. | rule | low | **Earned, never defaulted**: offered only after the user approves the same batch 2–3 times. Rules pre-flag into the next deck — they never delete on their own (see Decision Log #6). |
| New-Duplicate Auto-Flag | Dupes/bursts in newly added photos, queued automatically. `PHPhotoLibraryChangeObserver` while running; `PHPhotoLibrary.fetchPersistentChanges(since:)` (iOS 16+) across launches. | rule | low | Keeps the app relevant post-purge; feeds the post-event prompt. |
| Protection Rules (the anti-action) | Standing exclusions: never propose Favorites, marked faces, chosen albums, chat screenshots. | rule | — | Enumerating what the app will *not* do is itself proposable. We expect surfacing protections early to increase batch approval — instrument and validate. |

## 5. Cross-Cutting Principles

1. **Two properties determine presentation.** Decision unit × regret risk collapses the whole taxonomy into four card templates (§6). The "25+ actions" problem is really "design four templates well."
2. **Confidence moves an action up the ladder** (photo → cluster → batch → rule), **and user trust gates each promotion.** The same detector ships at multiple rungs: severe blur + no face = pre-checked batch; borderline blur = swipe deck. Rules are earned after 2–3 equivalent batch approvals.
3. **Age cuts both ways.** For ephemera (passes, OTPs, maps, parking, recordings), regret decays with time — age is the universal confidence booster and the one knob users get ("older than: 30/90/365 days"). For camera photos, age *increases* regret — old + unengaged is what irreplaceable memories look like.
4. **GB and decisions are inversely distributed.** ~40% of reclaimable GB is a dozen large videos (high regret, review one-by-one); thousands of screenshots/dupes provide the decision-count wins. Offer two entry modes: **"Free up space"** (largest-first) and **"Tidy up"** (clusters/batches) — surfaced as ordering presets on the Home storage header (§10).
5. **Every destructive family has a non-destructive sibling** (file / favorite / stack / archive-offload). "File it" absorbs the anxious middle that otherwise stalls sessions.
6. **Approval and commit are decoupled** — everything accumulates into one staged cart, committed once per session through one system dialog.
7. **False-positive traps concentrate in semantically ambiguous categories** (chat screenshots, receipts, memes, bokeh, night shots, concert videos, recorded video calls). These are capped at photo/cluster level *regardless of classifier confidence*; chat screenshots are excluded from sweeps entirely. (Chat-screenshot detection is OCR-gated — until OCR ships, screenshot sweeps stay review-only; §15.)
8. **The keep-best quality kernel is shared infrastructure** (sharpness + face quality + saliency + resolution) powering at least seven actions. Build and tune it once. The "eyes open" component is derived from eye-landmark geometry — custom thresholds with their own error rate, part of the kernel's tuning scope, not an Apple-provided fact. Every card using it shows *why* the keeper won — explained proposals get approved at much higher rates.
9. **Scan in tiers, stream results.** Metadata → thumbnail math → Vision passes. Never block the user on a full scan.
10. **Trust is minted by ordering.** Open with provably-lossless actions; show safety nets constantly; surface protections early; degrade toward *more user control* (never more automation) when proposals get rejected.
11. **The endgame is maintenance, not the purge.** Post-event prompts + earned rules convert a 15-minute app into a habit — the strongest justification for one-time pricing.

## 6. Card Grammar — Four Shapes

Every action, no matter how exotic, renders as one of exactly four card templates. **New detectors add content, never vocabulary** — a user who learns these in session 1 handles detector #26 with zero new learning.

| Card | Interaction | Examples |
|---|---|---|
| **Single** | One photo, keep/clean verdict | blurry shot, pocket shot, web-save |
| **Cluster** | "Keep this one, clean the other N" — keeper pre-crowned with reason chips; tap any thumbnail to rescue it; swipe up to open the edit grid | similar shots, bursts, duplicate groups, keep-best (seeds a & d) |
| **Batch** | One verdict on a whole set; 6 sample thumbnails + count + GB; tap to expand to full exception grid | "214 screenshots older than 6 months" (seed b), pocket shots, screen recordings |
| **Rule** | Visually distinct (different tint, gear icon); approving creates a standing policy that pre-flags future decks | "Always flag boarding passes 7+ days after the flight?" (seed c, evolved) |

Users browse ~7 *families* (piles), never a flat menu of 50 actions: **Duplicates · Similar · Junk & low quality · Screenshots & recordings · Documents · Storage hogs · Hygiene (non-destructive)** — plus a Rules management surface.

## 7. Interaction Architecture — The Two-Level Deck

### The core tension

Swiping is a *rhythm*, and rhythm requires homogeneous decision cost. A single blurry photo costs ~1 second of judgment; a 214-item batch costs 10–30 seconds; a standing rule deserves real deliberation. Mix them in one deck and the user either rubber-stamps the heavy card (dangerous — **swipe momentum is a bias engine**, and pointing it at "delete 214 items" is how the category generates its "it deleted my stuff" one-star reviews) or stops dead (kills momentum).

**The governing rule: a swipe's physical cost must match its decision's weight. Never let momentum built on 1-second decisions spend itself on 214-item ones.**

### Considered architectures

- **A — Unified proposal inbox** (one deck, all card types mixed): one mental model, zero navigation, but decision-cost whiplash and rubber-stamping. Great demo, bad product. **Rejected** as the sole model.
- **B — Hub + homogeneous decks** (mode per category): rhythm preserved — inside the Screenshots deck the brain caches one question and answers at 1–2/sec (the entire reason Tinder-style triage is fast). But the hub adds navigation and offers no "just tell me what to do" path. Right bones, needs a guided layer.
- **C — Two-level: Plan deck above, drill-in decks below.** ⭐ **Chosen.**

### Architecture C

**Level 1 — the Plan deck.** The hub is itself a *short, finite* deck of 5–10 **Plan cards** — the batch/rule-sized decisions:

> 🖼 **214 screenshots, 0.8 GB** — older than 6 months.
> *Swipe right to queue all · Swipe up to review one-by-one · Swipe left to skip.*

Each Plan card carries a 3×3 sample grid (worst offenders first) so the summary is trustworthy. A confident user clears every Tier 0–2 bucket in a handful of swipes; the deck being finite ("6 cards") makes cleanup feel *conquerable* — the emotional core of the value prop.

**Tier-3 buckets get a modified Plan card.** For never-batch families (Similar, selfies — §9.1), the queue-all affordance does not exist: swipe right *starts the review* ("Review 38 groups") instead of queueing. The tier rules outrank deck mechanics, always.

**Level 2 — drill-in decks.** Swiping up on a Plan card opens a homogeneous deck of Single or Cluster cards for that bucket, where rhythm is safe. Fine-grained review only ever happens here.

Decision cost is *bounded* per level: the Plan deck is all heavy cards; drill-ins are light-to-medium, with the interleaving rule (§10) smoothing the residual variance between cluster cards and singles. The app learns which buckets the user trusts (accept-all on Duplicates twice → offer the rule) and which they inspect.

### Edge cases

- **Videos:** muted auto-looping 3-second preview from mid-file (locally-available videos; evicted videos show poster frame + metadata); tap for scrubbing + audio; duration and size printed large (size *is* the argument). The preview and poster frame are shown to the user for display, which is not analysis: the free app opens no video frame for analysis (§3 constraint 1).
- **Live Photos:** badged; long-press plays motion (matches the OS gesture). Delete-the-photo and convert-to-still are separate proposals, never conflated.
- **Very large clusters (60 similar):** never one card. Pre-split into sub-clusters of ≤12 ("Beach — group 1 of 5"); above ~20, fall back to a pick-the-keepers grid. Twelve is the most a filmstrip can actually be audited at card size.
- **Slow thumbnails:** never deal a card whose images aren't ready — prefetch a 5-card buffer (`PHCachingImageManager`); reorder ready cards forward (deck order is app-chosen; use the freedom). **A verdict on an unseen image is a trust bug, not a perf bug.**
- **Offline/remote thumbnails:** skip into a "needs connection" tail bucket rather than blocking the deck.

## 8. Gesture Vocabulary

Four swipes plus three inspection touches (tap, long-press, pinch), sharing one directional grammar at both levels: **left = safe, right = clean, up = look closer, down = take it back.** Everything else is a tap target, not a gesture. Taught with a 4-card interactive tutorial on first run.

| Gesture | Plan deck | Drill-in deck |
|---|---|---|
| **Swipe right** | Queue whole batch to staging (Tier 0–2 buckets; on Tier-3 buckets right = start review, §7) | Approve proposal (queue) |
| **Swipe left** | Not this session (bucket stays on the hub) | Keep, permanently ("won't suggest again") |
| **Swipe up** | Drill in to review one-by-one | **Edit the proposal** (opens cluster grid) |
| **Swipe down** | **Undo last swipe** (un-queues the batch) | **Undo last swipe** |
| **Tap** | Expand sample grid | Full-screen the hero image |
| **Long-press** | — | Peek loupe: magnify under finger (sharpness check without leaving flow) |
| **Pinch** | — | Zoom within full-screen view |

Design rules:

- **Left = safe is sacrosanct and never varies.** In a deletion app the safe direction must be muscle-memory-stable. Left's *persistence* differs by level, stated on the card: on a Plan card left defers ("not this session" — bucket decisions are revisitable, nothing nags); on a drill-in card left keeps permanently — item verdicts are final so the library actually gets cleaner.
- **Down = undo, not a fourth verdict.** The most-needed gesture after a mis-swipe is *take it back*; pulling downward reads as retrieving the card. A small ↩ button also exists — gesture-only undo fails discoverability.
- **Cluster override ("keep 2 of 12"):** swipe up flips the card to a grid — the app's pick badged ★KEEP, others check-marked for cleaning. Tap any photo to toggle; long-press to full-screen. Buttons: **Apply** / **Keep all**. Override is two taps beyond the swipe and introduces no new gestures.
- Full-screen inspection shows the best locally-available image (`isNetworkAccessAllowed = false`), with an explicit "load sharper version" tap that may use the network — never the full original (§3 constraint 1).
- **Accessibility floor:** every gesture has full button parity (VoiceOver, Switch Control); verdicts are never encoded by color alone. (See Open Questions for RTL semantics.)

## 9. Trust & Safety Design

Trust is the entire product — a $3 app that deletes photos lives or dies on "I never felt scared."

### 9.1 Regret tiers drive presentation

Regret risk = P(algorithm wrong) × irreplaceability × opacity, where opacity means how inscrutable the detector's judgment is *before* any card design mitigates it. Presentation scales with the product:

- **Tier 0 — provably lossless** (exact dupes): batch-approvable with one swipe. *"Deleting a copy loses nothing — the original stays."* Never force per-item review of provably-safe items — that teaches users the app can't tell safe from unsafe. (When originals are iCloud-evicted, "exact" rests on metadata + thumbnail identity — near-certain, not byte-proven; the card claims "identical" only when byte-verified, per §4.1.)
- **Tier 1 — objectively derivable** (old no-face screenshots, burst leftovers, blank frames, severe blur with no faces): batch allowed, contact-sheet grid one tap away.
- **Tier 2 — heuristic but explainable** (expired ephemera, blurry-with-faces): per-item or small batch, with the *evidence rendered on the card*: "Boarding pass · flight date Mar 3, 2025 · 17 months ago." The evidence does the persuading.
- **Tier 3 — judgment calls** (similar-cluster keep-best — the "grandma's only smile" tier): **never batch-approved.** One cluster per card; the *deletions* get the big thumbnails, tappable to full screen with pinch-zoom (the scary part is what leaves — make it inspectable); every candidate individually rescuable; keeper chips explain the win ("sharpest · everyone's eyes open"). If expressions differ across faces in the cluster, banner it ("Expressions differ — worth a closer look") and require a deliberate long-swipe.
- **Tier 4 — never auto-proposed** (protected classes, below).

The deck slows down when it matters — users unconsciously read that as competence.

### 9.2 Four stacked safety nets

1. **Undo stack** — unlimited depth, swipe-down or ↩; popping a batch un-queues all its items.
2. **Staging bin** — nothing touches PhotoKit during swiping. The word "delete" never appears in the deck; use "Clean"/"Queue." Staging persists across sessions until emptied, and the bin is a browsable screen at any time (tap the GB ticker or the bin icon): everything queued, grouped by reason, with per-item and per-group restore — undo is never only sequential.
3. **Review-before-commit screen** — total GB, grouped thumbnails, **riskiest items surfaced first** (faces, badged album members, near-protected items get a ⚠ row demanding a glance), per-item restore. One button: *"Move 1,204 items to Recently Deleted (recoverable for at least 30 days)"* — name the real destination; never "Delete forever." Also set the expectation that the system's own dialog will say "Delete" in Apple's blunter wording.
4. **iOS Recently Deleted** — ≥30-day recovery, one system dialog per session (proves the app can't delete silently). Post-commit receipt: *"Done. 1,204 items (9.7 GB) queued for reclaim — recoverable in Photos → Recently Deleted for at least 30 days (until about Sep 11)."* There is no supported deep link into that album, so the receipt opens the Photos app with illustrated steps (Albums → Utilities → Recently Deleted — Face ID-locked since iOS 16), including the "empty it now to free space immediately" path; the same instructions live permanently in Settings. Showing the escape hatch after the fact is the cheapest trust builder available.

Onboarding states all four nets explicitly.

### 9.3 Protected classes (Tier 4)

Hard exclusion list, on by default, each a visible toggle in Settings:

- ❤️ Favorites · ✏️ Edited photos · 🧒 Faces the user marks in a one-time "protect these people" flow · 📅 Significant dates (user-entered + inferred event spikes) · 🕰 Camera-captured photos older than X years (default 5 — scoped to camera photos only: for ephemera and junk classes, age *lowers* regret per §5.3) · 📁 Photos in named albums are protected from **batches** specifically; they may still appear in drill-in cluster cards, badged 📁 (Decision Log #5).
- Enumerated exceptions to the hard exclusions, each preserving "nothing unique is lost": **exact duplicates** of a protected photo (the protected copy is always the keeper); the **original** in an original+edited pair (default keep-the-edit, §4.1); **album-member cluster candidates**, where the keeper inherits first.
- Where a deleted cluster member was in a user-created album or favorited, **the keeper inherits** the album membership / favorite flag before the delete (Apple-Merge-style metadata preservation — no third party does this). Scope: PhotoKit can only modify user-created albums; shared/smart/synced albums are read-only to apps (§4.10).

Session summaries show the badge: *"1,847 photos are protected and were never considered."* This sentence does more for trust than any feature.

### 9.4 Explainability bar

Every card carries its one-line evidence ("Blurry — sharpness 3/100", "Exact copy — identical file", "Best of 12 — sharpest, eyes open in all 3 faces"). **If the app can't state a reason in one line, it doesn't propose the action** — also the internal shipping bar for detectors.

### 9.5 The trust ladder (session arc)

1. **First 60 seconds:** the safest possible win — *"96 exact duplicate copies (720 MB). Deleting them loses nothing."* The user's first-ever swipe should be on something where being wrong is *impossible*. (Session-1 examples deliberately fit inside the ~100-item cap — and the free allowance covers the whole session by design, §2.)
2. **Session 1:** Tier 0 + Tier 1 only, capped at ~100 items, staging review mandatory (no express path). A one-time "show me" proof: one dupe pair side-by-side with a diff overlay — byte-verified pairs only, so "identical, pixel for pixel" stays literally true.
3. **Session 2 / after first successful commit:** introduce Tier 2. In the MVP that means blurry-with-faces alongside the Similar unlock; from v1.x it's the boarding-pass deck — the charming "wow, it read my boarding pass" moment; expired travel docs are emotionally weightless.
4. **Unlock Tier 3 (similar clusters)** after ≥1 completed commit, starting with the most defensible clusters (keeper wins on *every* metric; shot within 3 s of each other).
5. **Adaptive thresholds:** track per-type rejection rates. Rejecting >30% of blur proposals raises that user's blur threshold; approving 98% of screenshot batches triggers the rule offer. Restores from staging are ground truth of over-aggression — quietly deprioritize restored types. Trust is granted *by the user, per category, explicitly* — never assumed.
6. **Never punish rejection.** A "no" swipe gets the same haptic weight, marked "Kept — won't suggest again." Apps that make keeping feel like failure train users to over-delete, then churn in regret.
7. **Fatigue caps:** Tier 3 sessions cap at ~20 clusters. Decision fatigue → careless swipes → regret → churn.

### 9.6 Anti-patterns (banned — the honesty extension of anti-subscription)

- No inflated GB claims: the paywall number = `sum(file sizes of proposed deletions)`, and the receipt shows *actual* reclaimed space. If iCloud Optimize Storage makes local ≠ cloud savings, say so plainly.
- No fake scanning theater (pulsing radar, 90-second fake progress). Real counts, incrementing.
- No panic banners, red badges, or storage doom-mongering. Tone: calm professional organizer, not smoke alarm.
- No silent queueing outside the current card; no "are you sure you want to keep this?" guilt prompts.
- No countdown timers on the purchase; no notification nagging; review prompts a week *after* a cleanup ("still happy?" timing signals confidence), never during the dopamine hit.
- No burying the restore path: the Recently Deleted instructions live on the receipt screen **and** permanently in Settings.

### 9.7 "Merge" framing (seed example d)

Destructive merge is framed as **selection, not deletion** — but never euphemistically:

- The verb is **"Keep Best"** — not "Merge" (implies pixels get combined), not "Stack" (Apple/Google use it for non-destructive grouping; borrowing it for deletion is a lie by connotation).
- Card copy leads with the keep and footnotes the delete *in full weight, not fine print*:
  > **"Keep the best of these 12?"**
  > Keeper chips: *sharpest · eyes open · largest*
  > *The other 11 move to Recently Deleted.*
  > Swipe labels: **← Keep all 12 | Keep best →**
- The rejection label is "Keep all 12," never "Skip" — rejecting is also a keep-action, so saying no feels safe and the rhythm stays positive-positive.
- After per-thumbnail rescues, the button states both numbers: **"Keep 3, remove 9."**
- Medium confidence flips the layout to humility: *"These 4 are nearly identical — pick your favorite."* Confidence-dependent humility beats fake certainty.
- If a deletion candidate is the only shot from that morning with a detected face, or the only photo at that location, the app volunteers it: *"This is the only other shot from that morning."* The app talking users *out* of deletions is the strongest possible signal it's on their side — and the story they tell friends.

## 10. Information Architecture & Screens

**Six surfaces, three levels of depth, never more:**

**Home → Deck → Cluster-edit grid → Commit → Summary**, plus **Rules**. Pile tiles on Home deep-link into the same Deck screen, filtered — not a seventh surface.

### First-run flow

Permission ask, framed with the four safety nets → a 3-screen onboarding (on-device privacy · Recently Deleted safety · "first cleanup free, $2.99 once") that plays *over* the already-running scan → the progress surface morphs into Home as buckets come online (~10 s to the first swipeable bucket; scale validation pending, §14.3) → the 4-card gesture tutorial (§8) → session 1.

### Home ("Today")

1. **Storage header** — reclaimable GB + lifetime progress ring, with the two entry-mode presets (§5.4): **Free up space** (largest-first) / **Tidy up** (clusters & batches), which re-order the Plan deck.
2. **The Plan deck** (dominant visual element, ~70% weight) — the 5–10 Plan cards of §7. This is the only decision most users ever make here.
3. **Piles row** — max 7 family tiles with GB badges ("Screenshots — 214 items, 0.8 GB"), sorted by GB descending; undiscovered families greyed ("Documents — scanning…"). Tapping a tile = the same drill-in deck, entered laterally.
4. **Rules strip** (once ≥1 rule exists) — "4 rules active · flagged 9 items this week."
5. **Trust footer** — "Everything goes to Recently Deleted. 30 days to undo. Nothing leaves your phone." + the price, visible from day one.

### Plan-deck ordering (the smart queue)

```
score = (expected_GB_freed × confidence) / decision_cost − regret_penalty
```

Pacing layer, treated like game level design:

1. **Warm-up:** open every session with 3–5 near-certain wins (exact dupes) — teaches the gesture at zero risk.
2. **Early jackpot:** one big-GB card in the first 90 seconds so the ticker visibly jumps (post-session-1; see trust ladder).
3. **Interleaving:** in drill-ins, never more than ~5 consecutive heavy (cluster) cards; alternate with light singles.
4. **Batch metering:** 1–2 batch cards per session early, so users calibrate instead of blanket-approving. Early Plan decks are therefore short, growing toward the steady-state 5–10 cards as the trust ladder unlocks families — the "whole library in a handful of swipes" framing describes the steady state, not session 1.
5. **Peak-end:** close each deck with a run of high-confidence cards so the final memory is fluency.
6. **Dynamic difficulty:** low-confidence/high-regret proposals deferred until the user's approval history proves calibration.

### Progressive disclosure

- **Session 1 exposes exactly four families** (Duplicates, Blurry & junk, Screenshots†, Similar* — *greyed until first commit per the trust ladder; †the session-1 Screenshots slice is Tier 1 only: old, no faces, count-capped — the full sweep card arrives in session 2+ per Decision Log #2). Everything else visible-but-greyed: visible so the roadmap builds anticipation, greyed so it demands nothing.
- **Unlocks are framed as discovery, not gamification:** e.g. end of a v1.x session — "We found 620 MB of expired documents — boarding passes, receipts, old QR codes. Want them in your next deck?" (In the MVP the same mechanic reveals the Similar family after the first commit.) The app *finding new stuff* is ongoing value; "you unlocked a feature" is withheld value.
- **Rules are proposed in-flow, managed in settings — never the reverse.** Trigger: ~3 same-shaped approvals → a Rule card enters the deck. The Rules screen is purely management (list, per-rule stats, pause, threshold edit); nobody ever *discovers* a rule there.
- **Confidence ladder per family:** approval rate >95% over ≥50 decisions → offer promotion from card-by-card to batch-by-default. **Tier 1–2 families only: Tier-3 families and §5.7 trap categories are permanently capped at cluster/photo level regardless of approval rate** (Decision Log #11).

## 11. Session Design & Maintenance Mode

- **The unit is a deck of ~40–60 decisions ≈ 10–15 minutes.** Instrument real per-card decision times and recalibrate per user.
- **Reframe the backlog:** 3,000 items is *not* 3,000 decisions — clusters and batches compress it to ~350 decisions ≈ 6–8 decks. Always express backlog as sessions or time ("about 5 sessions left"), never raw item counts ("2,847 items remaining" is a despair number).
- **The GB ticker is the hero metric** — a persistent pill ("2.7 GB queued") ticking per swipe with a micro-animation. Honest by construction: sum of file sizes queued. Global "X of N proposals" counters are meaningless across card weights — per-bucket progress bars only.
- **Chunking:** long buckets deal in rounds of ~50 with interstitials ("Round complete — 0.3 GB queued — keep going / next bucket"): exit ramps and completion hits without the user inventing a stopping point. End decks on family boundaries where possible. (Swipewipe's loved month-by-month / "On This Day" piles are a deliberate non-adoption: family decks beat calendar decks for cleanup because the decision question stays cached — a nostalgia lens could return as a v2 event-sweep skin.)
- **Deck-empty moments:** drill-in empty → light celebration + auto-return to the Plan deck (card now ✓). Plan deck empty → "Library clean. 6.4 GB ready to free" → straight into Review & Commit → before/after storage bar (the screenshot people share).
- **Mid-session bailout is safe:** every swipe persists; next open resumes at "18 decisions left in this deck."
- **Maintenance mode:** once the backlog clears, Home flips — piles collapse to checkmarks, the hero becomes the **weekly mini-deck** ("Weekly tidy: 12 new items, ~400 MB, 2 min"), the Rules strip moves up ("your rules did most of the sorting"). The week-4 journey: notification → deck in one tap (Home skipped) → 90 seconds of swiping → commit → done.
- **Notifications are threshold-gated, never schedule-gated:** fire only when `newly_flagged_GB ≥ user threshold` OR (7+ days AND ≥10 items pending). One onboarding question sets the threshold ("Nudge me when I can free up: 100 MB / 500 MB / 1 GB / never"). Copy always contains the numbers; never "we miss you." Silence when there's nothing worth saying — this *is* the anti-subscription brand in notification form.
- **Widget:** reclaimable gauge + item count, deep-linking straight into the mini-deck. App-icon badge default **off** (badges manufacture anxiety). Optional monthly digest ("In March, iClean freed 3.2 GB") — goodwill and word-of-mouth fuel.
- **No daily streaks / guilt mechanics.** Cadence framing only ("3 weekly tidies in a row"). Completion, not compulsion.

## 12. Competitive Landscape

*(Web-researched Aug 2026; per-app details from App Store pages, reviews, and help docs.)*

| App | Model of note | Key takeaway |
|---|---|---|
| **Swipewipe** | Pure manual swipe, month-by-month piles + "On This Day," zero intelligence; ~$5–10/**week** | 4.7★ on 84k ratings built on *stats-as-game* (GB counters, streaks, session recaps, haptics) — proof the triage UX alone is worth paying for, and counter-evidence weighed in Decision Log #9's streak stance; pricing is the #1 complaint. |
| **CleanMyPhone** (MacPaw) | Duplicates/similar/blurry/screenshots + video compress + Live→still; ~$20–25/yr | The polished category-first benchmark; won a UX award for "cleaning with care." |
| **Gemini Photos** (discontinued) | Cluster review with best-shot pre-crowned | Origin of the keeper pattern — and of its failure mode: users who rubber-stamped a wrong best-pick lost the shot they wanted. |
| **Slidebox** | Swipe up=trash / down=favorite / tap=album; in-app staging trash | Loved for multi-outcome gestures and two-stage commit; killed by pricing bait-and-switch + ads — its user base is actively seeking a replacement (target "Slidebox alternative" ASO). |
| **Clever Cleaner** | Genuinely free, accurate similars/heavies/Live-conversion | Sets the free-tier quality bar; iClean can't beat free on price — must win on intelligence + UX. |
| **Cleanup / Hyper Cleaner** clones | $7.99/wk; mass pre-selection dark pattern | Review-mined ammo: "deleted all my photos," silent trial conversion, hostage paywalls. |
| **Google Photos** | Stacks with "Keep This, Delete Rest"; storage-saver | Closest to seed (d), but buried 3 levels deep and joyless. |
| **Apple Photos Duplicates** | Exact dupes only; **Merge preserves metadata** | Apple's metadata-preserving merge is the gold standard nobody else matches — iClean's keeper-inherits design adopts it. Weakness: misses "similar," indexing takes days. |

**Table stakes** (ship or look broken): category dashboard with counts + GB; cluster card with pre-crowned keeper and tap-to-swap; nothing deletes without explicit confirm + Recently Deleted messaging; last-swipe undo; free scan with real numbers; GB-freed session feedback.

**Unoccupied territory iClean claims:**

1. **OCR-dated ephemera detection** (expired boarding passes, dead QR codes, old parking receipts) — no app found doing this.
2. **Explained proposals** — no competitor states why it picked a keeper or flagged a photo; opacity is what generates the category's "deleted wrong photos" one-star reviews.
3. **Metadata-preserving keep-best** (keeper inherits albums/favorites) — only Apple does this, and only for exact dupes.
4. **A typed-proposal architecture** — every competitor is category-first grind; nobody runs Plan-level batch proposals over an intelligence layer.
5. **Loss-free reclaim in a non-subscription app** (compression, Live→still, slo-mo conversion).

## 13. Decision Log

Contradictions surfaced during the design brainstorm, and their resolutions:

| # | Question | Decision |
|---|---|---|
| 1 | Mixed smart queue vs. segregated decks? | **Two-level Architecture C** (§7). Batch and item decisions never share a deck. The smart-queue scoring formula survives as the *ordering* function within each level. |
| 2 | Session-1 scope: jackpot batch vs. training wheels? | **Training wheels win.** Session 1 = Tier 0/1 only, ~100-item cap, mandatory staging review. The screenshot "jackpot" lands in session 2+. Slower first session, durable trust. |
| 3 | Gesture semantics (three lenses assigned up/down different meanings) | **Up = inspect/edit, down = undo**, left = safe (immutable direction), right = clean. Within drill-ins, filing/deferring lives as tap targets inside the cluster-edit and exception grids, not as a fifth swipe direction. On the Plan deck, left *is* a defer ("not this session") by design — bucket decisions are revisitable, item verdicts are final (§8). |
| 4 | Pre-checked batches — dark pattern or convenience? | Pre-checking is allowed **only within the card the user is actively deciding on** (e.g., >1 yr screenshots pre-checked in the exception grid), always with the grid one tap away. Nothing outside the current card is ever silently queued. Mass pre-selection across categories (the Hyper Cleaner pattern) is banned. |
| 5 | Protected classes vs. actions that target them | Per class: **Favorites** — never deleted; exact-dupe copies of them may be (favorite copy always kept). **Edited photos** — never deleted; the *original* in an original+edited pair may be proposed (default keep-the-edit). **Album members** — never in batches; may appear in drill-ins badged 📁; keeper inherits membership. **Old photos** — age boosts confidence for ephemera/junk classes, raises protection for camera photos; no blind old-photo sweeps. |
| 6 | Rule firing: delete-unless-vetoed digest vs. pre-flag? | **Pre-flag only.** Rules flag items into the next deck pre-checked; deletion always passes through the user's swipe + commit. Delete-unless-vetoed is dead — it breaks the trust contract. |
| 7 | GB ticker vs. honesty (Optimize Storage + 30-day purge) | The ticker means **"queued to clean"** (sum of file sizes) and is labeled as such. The receipt screen tells the truth per account type: iCloud-quota vs. device-space savings, and the 30-day Recently Deleted purge, with the "empty now" deep link. |
| 8 | Paywall: free allowance or hard gate at first commit? | **Free allowance sized to the whole first session** (~100 items), so the trust loop completes before payment by construction. Price visible from session 1. |
| 9 | Streaks and gamification ceiling | GB ticker, session recaps, completion states: yes. Daily streaks, guilt mechanics, badges-by-default: no. Cadence framing ("3 weekly tidies") only. |
| 10 | The founder's "merge" naming | **"Keep Best"** as the user-facing verb; honest deletion statement in full weight; Apple-style metadata inheritance underneath. "Merge"/"Stack" reserved for genuinely non-destructive operations. |
| 11 | Can Tier-3 buckets ever be batch-approved? | **No, permanently.** Their Plan cards replace queue-all with "start review" (§7), and the §10 confidence ladder can never promote a Tier-3 / §5.7 trap family to batch — approval history notwithstanding. |

## 14. Open Questions

Surfaced by the critique pass; each needs a designed answer before or during MVP build:

1. **Limited Library access.** ~~Undesigned~~ → designed in APP_PLATFORM.md §3 (auth state machine, honesty scoping, upgrade-ask timing); remaining work is copy and UX polish on the limited-mode screens.
2. **iCloud Shared Photo Library.** In the Photos app, any member's delete removes assets *for everyone*, and shared assets count against the owner's quota — but PhotoKit (through iOS 17/18) does not appear to expose shared-library assets to third-party apps at all, which would make exclusion automatic and badging impossible. Verify visibility on the target SDK; if invisible, this becomes an FAQ entry ("iClean cannot see or manage your Shared Library") rather than a proposal rule.
3. **Scale: 50k–200k-photo libraries.** Embedding index size/persistence, scan duration, thermal/battery gating, `BGProcessingTask` budgets, memory ceilings on clustering, re-scan cost after library mutations. The "first swipeable bucket in ~10 s" claim needs validation at scale.
4. **Concurrent library mutation.** Photo deleted/edited elsewhere while staged here: stale asset IDs at commit, changed totals — staging bin must reconcile via `PHPhotoLibraryChangeObserver` (live) and `fetchPersistentChanges(since:)` (across launches).
5. **Commit failure paths and commit-time scale.** User cancels the system dialog after a 15-minute session (preserve staging, no guilt); partial `deleteAssets` failures; assets mid-iCloud-sync. A single `deleteAssets` call with 1k–10k assets needs testing/chunking — Slidebox's staging-trash freeze above ~100 items is the category's documented precedent. Note the OS dialog says "Delete N photos" in Apple's blunt wording right after our reassuring review screen — set expectations on the review screen.
6. **Post-commit restore reality.** PhotoKit cannot un-delete; "restore one to test" requires a manual trip into Photos via illustrated navigation — there is no deep link, and Recently Deleted is Face ID-locked since iOS 16. Design that verification flow explicitly or it dies.
7. **Accessibility & internationalization.** VoiceOver/Switch Control parity for a gesture-driven destructive UI; Dynamic Type on evidence chips; reduce-motion variants; color-blind-safe verdict encoding; RTL gesture semantics (is left=keep universal?); OCR keyword coverage beyond English (boarding-pass detection tuned on English fails Japanese/Arabic libraries).
8. **iPad / landscape / pointer.** Decks are a phone-portrait metaphor; iPad users with big libraries are a prime segment.
9. **Multi-device state.** Partially answered: Family Sharing and restore are designed (APP_PLATFORM.md §4 — product-level flag + `AppStore.sync()`), and staged-state survival across device restore is designed (SCAN_PIPELINE.md §9 cloudId remap). Deliberately *not* synced: live staging/rules/trust-ladder state across concurrent devices — per-device state avoids any cloud component; revisit only if users complain.
10. **The clean-library zero state.** Scan finds 300 MB: does the app say "you don't need us yet — come back after your next trip"? Honest answer probably yes; design the expectation and refund posture.
11. **Android later?** Native SwiftUI is the working assumption for iOS quality; an Android port re-implements the pipeline (CameraX/MediaStore + MLKit). Revisit after iOS traction.

## 15. MVP Scope & Roadmap

### MVP (v1.0)

- Scan pipeline: tiered (metadata → hashes/blur → embeddings/faces), incremental, resumable, thumbnail-only.
- **Four families:** Exact/near duplicates, Similar clusters (keep-best), Blurry & junk (incl. blank/corrupt/zero-byte/pocket frames), Screenshots — **review-only in MVP:** the Screenshots Plan card starts a drill-in review rather than offering queue-all, because the chat-screenshot exclusion (§4.4, §5.7) is OCR-dependent and OCR is v1.x. Screenshot batch queue-all ships together with OCR subtyping.
- Two-level deck (Plan cards + drill-ins), the five-gesture vocabulary, cluster-edit grid.
- Staging bin, undo stack, Review & Commit, receipt screen with Recently Deleted deep link + "empty now" guidance.
- Protected classes (Favorites, edited photos, album members) + protections badge. Marked-faces protection ships in v1.x — iOS exposes no face-identity API, so it needs the custom face-anchor design (SCAN_PIPELINE.md §14.8).
- Explainability chips on every card.
- Trust ladder (session-1 training wheels), adaptive thresholds (v1: per-type rejection tracking only).
- Paywall: $2.99 one-time; the entire first session is free (§2).
- Keeper metadata inheritance (albums, favorites).

**Explicitly out of MVP:** OCR anything, video actions, rules, Live Photo conversion, event sweeps, maintenance mode, stacking, iPad layout, Android.

### v1.x — the differentiators

- OCR ephemera family (boarding passes first — it's the marketing moment), receipts/QR/maps — plus screenshot OCR subtyping, which unlocks the batch screenshot sweep and the chat-screenshot hard exclusion.
- Video family (screen recordings, micro-videos, largest-files queue; pocket videos need video analysis, which is not in the app, and there is no paid version; see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md).
- Standing rules (earned, pre-flag model) + weekly mini-deck + threshold-gated notifications + widget.
- Marked-faces protection (face-anchor matching, SCAN_PIPELINE.md §14.8).
- Post-event cleanup prompts.

### v2 — reclaim & curation

- Live→still, slo-mo conversion, HEIC/HEVC compression queues (charging + Wi-Fi gated).
- Album filing, auto-favorite, stacking, archive-offload, sensitive-photo vaulting.
- Event review sessions; iPad.

## 16. Non-Goals

Deliberate exclusions — the category's bundleware that dilutes trust and focus:

- No contacts dedupe, no calendar-spam cleaning, no "network speed test," no battery/RAM boosters.
- No private photo vault as a product (vaulting *suggestions* route to iOS's own Hidden album).
- No cloud processing, no accounts, no photo uploads, ever.
- No subscription, ever — it's in the App Store subtitle.
