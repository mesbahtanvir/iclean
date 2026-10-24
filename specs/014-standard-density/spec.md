# 014 Standard density: say it once, where iOS says it

**Feature Branch**: `014-standard-density`
**Created**: 2026-10-23
**Status**: Draft
**Input**: "The UI is too verbose and not consistent with regular iOS app UI; for example, the bottom
20% of the Home screen is explanation and a button."

**Builds on**: [012-calm-polish](../012-calm-polish/spec.md) and [013-liquid-glass](../013-liquid-glass/spec.md).
012 said the reassurance in several places (under the Review bar, under the Remove bar, at the
top of a category at large text, under the Confirm button). On a phone that reads as copy, and a
regular iOS app says such a thing once, on the sheet where the decision is made. This entry removes
the repeats and moves the tools where iOS keeps them. Where this entry and 012 or 013 disagree,
this one wins; everything it does not mention is unchanged, the Mac in particular.

## What changes

### FR-001 One line, one button at the bottom of Home
The Review bar is one line, "Review 12 Items", in the one filled control. The size is the hero's
job, right above; VoiceOver still hears "Review 12 Items, about 36 megabytes" so the two agree out
loud. Nothing is written under the button: the sentence "Nothing is removed until you confirm.
Removed items go to Recently Deleted in Photos." (`results.reviewNote`) leaves the phone's Home,
also at accessibility sizes. The Mac Overview keeps it under its hero.

### FR-002 Scan Again is a tool in the bar
"Scan Again" (or "Scan Library" before a full scan has finished) is a toolbar button with the
`arrow.clockwise` glyph next to the Settings gear, offered under the same rule as before: not while
a scan runs, finishes or waits to be resumed. It keeps the identifier `home.scan` and its label. The
Mac's sidebar footer keeps its line.

### FR-003 The periphery is footer text
"Scanned 3 minutes ago" (`home.lastScan`), the iCloud sentence (`results.notScanned`) and the
notices (`home.limitedAccess`, `home.storeVolatile`, `home.storeUnreadable`) are the footer of the
category section: plain text in the list's own footer style, without glyphs, no rows of their own.
When there are no rows yet, the footer stands alone, so the notices keep their slot.

### FR-004 The hero's caption states the fact
"from 12 selected items." and, while scanning, "from 12 items selected so far." The clause "You
choose what goes." is gone; the Confirm sheet says it when it matters.

### FR-005 The category's Remove bar is one line
"Remove 3 Photos" alone. The size is in the summary line above the photos ("3 sets · 6.4 MB"), and
where they go is said on the Confirm sheet. The second line (`category.removeSelected.detail`) and
its copy at accessibility sizes are gone, as is the reassurance sentence the summary line carried at
accessibility sizes. The caption (what the category is) stays: one sentence, as Photos writes one
over its Duplicates.

### FR-006 The Confirm sheet announces nothing twice
Under the button, only while it is switched off: "Turn on “Remove them all anyway” to continue."
(`confirm.footnote`). The sentence about the system's own confirmation ("You’ll be asked to confirm
once more…") is gone; the body already says "Nothing is erased yet. For at least 30 days you can
put them back from Photos." once.

### FR-007 Nothing else moves
No behaviour or other identifier changes. The VoiceOver labels of the buttons are unchanged; the
hero's label loses the clause of FR-004.

## Success criteria
- **SC-001**: On an iPhone 17 Pro at the default text size, the pinned area under Home's list is
  one button tall and the list's last section ends in footer text, not rows.
- **SC-002**: The iOS simulator and the Mac build; the Home, hero, review, removal, duplicates,
  accessibility and background-scan UI tests pass. Two assertions turned around: the review note is
  now expected to be absent, and the Remove bar's label no longer says where photos go. The audits'
  allowance lists name the Review and Remove buttons themselves, because a one-line button is
  reported as the button and not as its texts; the hero's overline and caption take their own
  height (`fixedSize`), so the audit sees them grow with the text size.
