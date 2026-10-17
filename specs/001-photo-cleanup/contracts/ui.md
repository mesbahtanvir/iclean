# Contract: Screens and states

What the user sees. UI tests are written against these screens, states, and
accessibility identifiers.

## Screens

| Screen | Purpose | Key elements (accessibility id) |
|--------|---------|--------------------------------|
| **Access** | Ask for Photos access; explain why; explain "everything stays on your phone" | `access.allow`, `access.openSettings` (when denied) |
| **Home** | Start a scan, see last results summary | `home.scan`, `home.lastScan`, `home.settings` |
| **Scanning** | Progress, pause/resume/stop | `scan.progress`, `scan.pause`, `scan.resume`, `scan.stop` |
| **Results** | One row per category with count and space | `results.category.<name>`, `results.reviewAll`, `results.notScanned` |
| **Category** | Grid of items or groups with selection toggles | `category.item.<assetID>`, `category.selectAll`, `category.keeperBadge`, `category.albumBadge`, `category.previewOnlyBadge` |
| **Group detail** | Side-by-side compare, change keeper | `group.compare`, `group.makeKeeper` |
| **Photo viewer** | Full screen view, zoom, keep/remove, "always keep" | `viewer.toggleSelect`, `viewer.alwaysKeep` |
| **Confirm sheet** | Summary by category, count and space; one confirm button (FR-012) | `confirm.summary`, `confirm.remove`, `confirm.cancel` |
| **Done** | Removed count, space freed, Recently Deleted reminder, failures | `done.removed`, `done.freed`, `done.failures` |
| **Settings** | Clear keep marks, delete all iclean data, privacy statement | `settings.clearKeepMarks`, `settings.deleteAllData` |

## Flow

```text
Access ─▶ Home ─▶ Scanning ─▶ Results ─▶ Category ─▶ (Group detail / Photo viewer)
                                  │            │
                                  └────────────┴─▶ Confirm sheet ─▶ iOS system prompt ─▶ Done
```

## States each screen must handle

- **Access**: not determined, limited ("scanning only the photos you shared with iclean"),
  denied (explain + open Settings button, nothing scanned).
- **Scanning**: running, paused, interrupted-and-resumable (shown on Home after relaunch),
  thermal pause.
- **Results**: nothing found ("your library looks clean"), some items not scanned (count
  shown), item removed elsewhere during review (silently dropped).
- **Confirm sheet**: removing every photo of a group shows a separate warning (FR-016);
  sizes marked "about" when estimated.
- **Done**: full success, partial failure (lists items not removed), user cancelled the
  iOS system prompt (nothing removed, back to Category).

## Rules

- Every gesture action also has a VoiceOver action; all text uses Dynamic Type; no
  animation when Reduce Motion is on (FR-017a).
- Every item cell shows: selected state, keeper badge, album badge (album names in its
  accessibility label), favorite heart, "preview only" badge (FR-014).
- No screen loads web content or links to websites.
