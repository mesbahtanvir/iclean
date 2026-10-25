# Contract: Screens and states (delta to 001, 002 and 003)

## Home

- A **Cleanup plan** list above the category rows with four rows: Quick wins, Photos, Similar
  shots, Best-shot refinement. In the free app there is no Duplicate Videos row or category (a
  Pro feature, FR-004a; no Pro version since 2026-10-24, 016); Large Videos is listed by file size under Quick wins.
- Each row shows one state: Waiting, Running with "checked N of M" and a time range, Paused
  with a reason, Done with what was found, or Not run with "Run now".
- The primary button reads Start cleaning, Review N items, or Continue finding more.
- While a scan runs, a row's "Stop after this step" ends the plan cleanly (FR-028).
- Category rows show "found so far" and "checked N of M" until their steps are done; the
  empty state "Your library looks clean" appears only when they are (FR-013).
- A "12 new" prompt appears at the bottom of an open category when a later update has more.
- Status line examples: "Waiting for your iPad to be charging", "Low Power Mode is on",
  "Slowed down: this iPhone is warm", "Paused: battery under 20%". Each pairs with the
  button that applies ("Run now"). Words follow the device: iPhone, iPad, Mac.

## Category and group screens

- The list is frozen when opened (FR-010). Counts on Home may change; this list does not.
- A keeper the user has seen does not change (FR-012).

## Settings

- **Scan speed**: Automatic, Gentle, Full speed, with one sentence about each.
- "Speed measured: N photos per second, checked on <date>", once known, and "Measure again".
- Recent Scans lists each step's duration and counts.

## Accessibility

- Each plan row is one VoiceOver element: "Step 2 of 4, Photos, running, 40 percent, about 6
  minutes left".
- Status changes post an announcement; nothing relies on colour alone (001 FR-017a).
- New controls get identifiers: `plan.row.<step>`, `plan.runNow`, `plan.stopAfter`,
  `category.newPrompt`, `settings.scanSpeed`.
