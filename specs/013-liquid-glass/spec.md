# 013 Liquid Glass and a Library screen

**Feature Branch**: `013-liquid-glass`
**Created**: 2026-10-23
**Status**: Draft
**Input**: "Follow the Liquid Glass and standard Apple app design guidelines and look and feel", and
"instead of just the text iclean, make it look like a serious professional app."

**Builds on**: [012-calm-polish](../012-calm-polish/spec.md), which stays the design of every
screen: the state machine, the words, the colours of text, the one filled control, the scrim on
photos, the pinned bars and their caps. This entry changes how the system draws a few of those
pieces on iOS 26 and macOS 26, and gives Home the look of a top-level screen. Where this entry and
012 disagree, this one wins; everything it does not mention is unchanged.

## What changes

### FR-001 Bars are the system's glass
A pinned bar (`pinnedBar(isPresented:)`: the Review bar, the Category Remove bar, the Confirm and
Done buttons, the Access button) is a `safeAreaBar` on iOS 26 and macOS 26: Liquid Glass, with the
list or the photos scrolling under its edge, and no fill of its own. Before iOS 26 it is the
`safeAreaInset` with the `.bar` material that 012 describes. Navigation bars, toolbars, sheets and
lists are system components and take on glass by themselves; nothing custom is drawn behind them.

### FR-002 The two button styles are glass
The one filled control on a screen uses `prominentButtonStyle()`: `.glassProminent` on iOS 26 and
macOS 26, `.borderedProminent` before. A secondary action, and a primary that is switched off, uses
`secondaryButtonStyle()`: `.glass` on iOS 26 and macOS 26, `.bordered` before. Every place 012 named
`.borderedProminent` or `.bordered` uses these (Glass.swift). `actionShape(pinned:)` still sets the
shape and the caps, so the audit allowances of 012 are unchanged. The scan card's Pause and Resume
keep their own style (012 0.6.7).

### FR-003 Nothing is glass over a photo
The marks, the chip and the expand control on a photo keep the black scrim of 012 4.2: a blur on
every visible cell is costly to scroll, and the owner's phone holds 38,000 photos.

### FR-004 Home is "Library", with a large title
On iOS the Home screen is titled "Library" and shows the large title a top-level screen has, in
place of the inline "iclean". At accessibility text sizes the title is inline: the large one is
127 pt tall there and pushed the first category row under the pinned Review bar. The app's name
stays the Mac window's title. No test reads the title.

### FR-005 The hero is a card with a storage bar
On Home with results the hero (012 6.3 item 1) sits in a card of its own instead of a quiet row.
Under the figure, once something is selected, a bar splits the selection by category: one slice per
category in that category's colour, in the fixed category order, like iPhone Storage. The bar is
decoration under the figure that says the total, so VoiceOver skips it, and it is the first thing
to go at accessibility text sizes (as the Access symbol is in 012 6.1). It reads the cached
selection summary, like the hero, and never a photo.

### FR-006 Each category has a colour and a tile
A category row on Home (and the Mac Overview) starts with a rounded tile in the category's colour
with the glyph in white, the way Settings and Files begin a row, in place of the secondary glyph.
The colours are system colours (Duplicates blue, Similar Shots indigo, Blurry Photos orange,
Unimportant gray, Screenshots teal, Duplicate Videos pink, Large Videos purple) and are used only for
the tile and the storage bar: never for text, a control or a mark on a photo, so 012 4.2 still holds
for meaning. The tile scales with Dynamic Type and is hidden from VoiceOver; the row's spoken label
is unchanged.

### FR-007 Both platforms, both generations
The app builds and looks right on iOS 18 and macOS 15 (the deployment targets), where it is exactly
the 012 design, and on iOS 26 and macOS 26, where the pieces above are glass.

### FR-008 Nothing else moves
No behaviour, accessibility identifier, label or VoiceOver text changes.

## Success criteria
- **SC-001**: The iOS simulator and the Mac build with no new warnings; the accessibility, Home,
  hero, review, removal and duplicates UI tests pass. Two test allowances: the scan card's hit
  areas are compared after rounding, because a frame at a third-of-a-point offset under the large
  title is reported as 43.99999999999994 pt; and on Home with the Review bar up, the audit's
  "potentially inaccessible text" with no element is tolerated, because the audit reads the screen
  as pixels and can make out the rows blurred under the glass bar, which are elements of the list.
- **SC-002**: On an iOS 26 simulator, Home shows the large "Library" title, the hero card with the
  storage bar and the tinted tiles, and the Review bar floats on glass; a category, Confirm and
  Access show glass buttons; all of it in light and dark appearance.
- **SC-003**: Scrolling a flat category is as smooth as before: no cell draws glass.
