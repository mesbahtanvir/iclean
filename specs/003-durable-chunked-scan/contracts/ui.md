# Contract: Screens and states (delta to 001 and 002)

## Scanning screen

| Element | Accessibility id | Text |
|---------|------------------|------|
| **New** footnote | `scan.failed` | "N couldn't be checked" (shown when `failed > 0`) |

Everything else is unchanged; Resume after a crash is the existing `home.resume`.

## Settings

| Element | Accessibility id | Text |
|---------|------------------|------|
| **New** row at the end of the list | `settings.recentScans` | "Recent Scans" (opens the screen below) |

## Recent Scans (new screen)

| Element | Accessibility id | Text |
|---------|------------------|------|
| One row per recent scan, newest first | `settings.session` | "Scan · Completed" over "<date> · N of M" |
| Empty state | `recentScans.empty` | "No scans yet." |
| Footer | — | "N items couldn't be checked." and "N scans were interrupted and resumed." when non-zero, else "Scans resume where they left off." |

Delete All Data clears the list (FR-012). The list lives on its own screen so Settings
stays short: a section added above the existing ones made the accessibility audit flag
the Privacy text as clipped at large text sizes.
