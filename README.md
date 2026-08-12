# iClean

An iOS photo-cleanup app: turn the photo cleanup you've put off for years into a few 15-minute swipe sessions. All detection on-device, every proposal explained, nothing deleted without your commit — $2.99 once, no subscription.

## Design documents

| Doc | Covers |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | Product & UX design: action taxonomy, card grammar, the two-level swipe deck, trust & safety design, IA, business model, competitive landscape, decision log, MVP scope |
| [docs/SCAN_PIPELINE.md](docs/SCAN_PIPELINE.md) | Scan pipeline (the read path): staged architecture S0–S7, data model, clustering & scoring algorithms, scheduling & governors, incrementality, performance budgets, build order |
| [docs/APP_PLATFORM.md](docs/APP_PLATFORM.md) | App platform (the write path): commit engine, photo-library authorization, StoreKit 2 entitlements, on-device telemetry, module architecture, release & privacy checklist |
