# Test fixtures

Labeled photos used to measure accuracy (spec SC-002, SC-003) and to seed a simulator.

## Synthetic set (always available)

The accuracy tests build a synthetic labeled set in memory. To write it to disk for
the simulator:

```bash
ICLEAN_EXPORT_FIXTURES=1 swift test --package-path Packages/CleanupKit --filter FixtureExport
```

Files land in `Fixtures/generated/` (git-ignored) with a `labels.json`.

## Real photos (recommended before release)

Synthetic images only approximate real photos. To calibrate thresholds on real ones,
add photos you have the rights to under `Fixtures/` and describe them in
`Fixtures/labels.json`:

```json
[
  { "file": "duplicates/beach.jpg", "duplicateGroup": "beach" },
  { "file": "duplicates/beach-whatsapp.jpg", "duplicateGroup": "beach" },
  { "file": "duplicates/beach-cropped.jpg", "edited": true },
  { "file": "blur/shaky.jpg", "blurry": true },
  { "file": "blur/portrait.jpg", "blurry": false, "portrait": true },
  { "file": "similar/burst1.jpg", "similarGroup": "dinner" }
]
```

When `labels.json` exists, the accuracy tests also run against these photos.
