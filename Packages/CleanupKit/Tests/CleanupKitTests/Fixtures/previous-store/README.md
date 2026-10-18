# previous-store

A SwiftData store written by the first released iclean build, before the durable scan work
(003) added the chunk entity and optional columns. `StoreMigrationTests` opens a copy of it
with the current schema to prove that a phone with an existing store keeps its data.

Contents: two items (`old-1` analyzed with album "Trip", `old-2` not scanned), one keep
mark (`old-1`) and a running scan with 2 of 4 items processed.

Regenerate with `scripts/make-previous-store-fixture.swift` (see the comments in it). The
generator runs in its own process on purpose: defining these model classes inside the test
process, next to the real ones, makes CoreData mix up the entities and crashes the run.

If a future change to the store is not additive (a rename, a removed column, a new
required column without a default), this test fails first; add a migration plan then.
