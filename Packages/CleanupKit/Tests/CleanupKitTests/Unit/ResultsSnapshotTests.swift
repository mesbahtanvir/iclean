import Foundation
import Testing

@testable import CleanupKit

@Suite struct ResultsSnapshotTests {
    let key = BuilderKey(detectors: [.duplicates, .similar], access: .full)

    /// Results with a duplicate group, a similar group, a blurry single and a large video.
    func results() -> CleanupResults {
        func item(
            _ id: String, kind: ItemKind = .photo, favorite: Bool = false, size: Int64? = 1_000
        )
            -> LibraryItem
        {
            var m = Make.meta(id, kind: kind, date: Date(timeIntervalSince1970: 1_700_000_000))
            m.isFavorite = favorite
            m.addedDate = Date(timeIntervalSince1970: 1_700_000_100)
            m.hasLocation = true
            m.albumNames = ["Trip"]
            return Make.item(
                m, dHash: 99, thumbprint: Data(repeating: 1, count: 64), print: Data([1, 2, 3]),
                sharpness: 0.7, aesthetics: 0.2, face: 0.5, size: size)
        }
        var items: [String: LibraryItem] = [:]
        for id in ["a", "b", "c", "d", "e", "f", "g", "video"] {
            items[id] = item(id, kind: id == "video" ? .video : .photo, favorite: id == "c")
        }
        items["unlisted"] = item("unlisted")
        let dup = ResultGroup(
            type: .duplicatePhotos, members: ["a", "b"], keepers: ["a"],
            dateNotes: ["b": [.savedDate, .midnight]])
        let sim = ResultGroup(
            type: .similarShots, members: ["c", "d", "e"], keepers: ["c"], confidence: .lower)
        let blur = ResultGroup(type: .single, members: ["f"])
        let big = ResultGroup(type: .single, members: ["video"])
        return CleanupResults(
            categories: [
                CategoryResult(category: .duplicates, groups: [dup]),
                CategoryResult(category: .similar, groups: [sim]),
                CategoryResult(category: .blurry, groups: [blur]),
                CategoryResult(category: .largeVideos, groups: [big]),
            ],
            defaultSelection: ["b", "d", "e", "f"], notScannedCount: 2, items: items)
    }

    func envelope(
        _ results: CleanupResults, revision: Int64 = 7, builtAt: Date = .now, items: Int = 9,
        marks: Int = 1, key: BuilderKey? = nil
    ) throws -> StateEnvelope {
        let snapshot = ResultsSnapshot(
            results: results, builderKey: key ?? self.key, itemCount: items, keepMarkCount: marks,
            builtAt: builtAt)
        return StateEnvelope(
            key: .results, version: ResultsSnapshot.formatVersion,
            payload: try StateCodec.seal(snapshot),
            basedOnRevision: revision, updatedAt: .now)
    }

    func restore(
        _ e: StateEnvelope?, key k: BuilderKey? = nil, revision: Int64 = 7, items: Int = 9,
        marks: Int = 1, now: Date = .now
    ) -> SnapshotRestore.Outcome {
        SnapshotRestore.restore(
            e, expecting: k ?? key, revision: revision, itemCount: items, keepMarkCount: marks,
            now: now
        ).outcome
    }

    // MARK: Round trip

    @Test func aSnapshotRestoresExactlyWhatSlimmedResultsAre() throws {
        let original = results()
        let r = SnapshotRestore.restore(
            try envelope(original), expecting: key, revision: 7, itemCount: 9, keepMarkCount: 1)
        #expect(r.outcome == .restored)
        #expect(r.results == original.slimmed())
    }

    @Test func slimResultsKeepOnlyGroupMembersAndNoFingerprints() {
        let slim = results().slimmed()
        #expect(slim.items["unlisted"] == nil)
        #expect(Set(slim.items.keys) == ["a", "b", "c", "d", "e", "f", "video"])
        for item in slim.items.values {
            #expect(item.analysis?.dHash == 0)
            #expect(item.analysis?.thumbprint.isEmpty == true)
            #expect(item.analysis?.featurePrint.isEmpty == true)
            // What lists and keeper re-picks still need is kept.
            #expect(item.analysis?.sharpness == 0.7)
            #expect(item.analysis?.faceQuality == 0.5)
        }
    }

    @Test func everythingTheScreensShowSurvives() throws {
        let original = results()
        let slim = try #require(
            SnapshotRestore.restore(
                try envelope(original), expecting: key, revision: 7, itemCount: 9, keepMarkCount: 1
            ).results)
        #expect(slim.defaultSelection == original.defaultSelection)
        #expect(slim.notScannedCount == 2)
        #expect(
            slim.category(.duplicates)?.groups.first?.dateNotes["b"] == [.savedDate, .midnight])
        #expect(slim.category(.similar)?.groups.first?.confidence == .lower)
        #expect(slim.category(.similar)?.groups.first?.keepers == ["c"])
        let a = try #require(slim.items["a"])
        #expect(a.metadata.albumNames == ["Trip"] && a.metadata.hasLocation == true)
        #expect(a.metadata.addedDate == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(a.byteSize == 1_000)
        #expect(slim.items["video"]?.metadata.kind == .video)
    }

    @Test func removingFromRestoredResultsBehavesLikeRemovingFromBuiltOnes() throws {
        let original = results()
        let restored = try #require(
            SnapshotRestore.restore(
                try envelope(original), expecting: key, revision: 7, itemCount: 9, keepMarkCount: 1
            ).results)
        #expect(restored.removing(["d"]) == original.slimmed().removing(["d"]))
        #expect(restored.removing(["a"]).category(.duplicates) == nil)
    }

    @Test func aSnapshotIsSmallAndCompressed() throws {
        let e = try envelope(results())
        #expect(e.payload.count < 4_000)
    }

    // MARK: Validity gate

    @Test func aMissingSnapshotIsNotAnError() {
        #expect(restore(nil) == .rejected(.none))
    }

    @Test func aSnapshotFromAnotherRevisionIsRejected() throws {
        #expect(restore(try envelope(results(), revision: 6)) == .rejected(.revision))
        #expect(restore(try envelope(results(), revision: 8)) == .rejected(.revision))
    }

    @Test func aSnapshotFromAnotherBuilderIsRejectedForEachPartOfTheKey() throws {
        let e = try envelope(results())
        let free = BuilderKey(detectors: [.duplicates, .similar], access: .full)
        #expect(
            restore(
                e,
                key: BuilderKey(
                    detectors: [.duplicates, .similar], access: .limited))
                == .rejected(.builder))
        #expect(
            restore(e, key: BuilderKey(detectors: [.duplicates], access: .full))
                == .rejected(.builder))
        var tz = Calendar(identifier: .gregorian)
        tz.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        var other = Calendar(identifier: .gregorian)
        other.timeZone = TimeZone(identifier: "America/Toronto")!
        let a = try envelope(
            results(),
            key: BuilderKey(
                detectors: [.duplicates, .similar], access: .full, calendar: tz))
        #expect(
            restore(
                a,
                key: BuilderKey(
                    detectors: [.duplicates, .similar], access: .full,
                    calendar: other)) == .rejected(.builder))
        var changed = free
        changed.builderVersion += 1
        #expect(restore(e, key: changed) == .rejected(.builder))
        var thresholds = free
        thresholds.thresholds += "|x"
        #expect(restore(e, key: thresholds) == .rejected(.builder))
        #expect(restore(e, key: free) == .restored)
    }

    @Test func aSnapshotWhoseCountsDisagreeWithTheStoreIsRejected() throws {
        let e = try envelope(results())
        #expect(restore(e, items: 10) == .rejected(.counts))
        #expect(restore(e, marks: 0) == .rejected(.counts))
    }

    @Test func aSnapshotOlderThanAWeekIsRejected() throws {
        let built = Date(timeIntervalSince1970: 1_700_000_000)
        let e = try envelope(results(), builtAt: built)
        #expect(restore(e, now: built.addingTimeInterval(7 * 86_400 - 60)) == .restored)
        #expect(restore(e, now: built.addingTimeInterval(7 * 86_400 + 60)) == .rejected(.age))
    }

    @Test func aNewerFormatIsRejected() throws {
        var e = try envelope(results())
        e.version = ResultsSnapshot.formatVersion + 1
        #expect(restore(e) == .rejected(.version))
    }

    @Test func damagedPayloadsAreRejectedNotDecodedIntoNonsense() throws {
        let good = try envelope(results())
        var truncated = good
        truncated.payload = good.payload.prefix(good.payload.count / 2)
        #expect(restore(truncated) == .rejected(.damaged))
        var flipped = good
        var bytes = [UInt8](good.payload)
        bytes[bytes.count / 2] ^= 0xFF
        flipped.payload = Data(bytes)
        // A flipped byte either fails to decompress or decodes to something that fails the gate.
        #expect(restore(flipped) != .restored)
        var garbage = good
        garbage.payload = Data("not a snapshot".utf8)
        #expect(restore(garbage) == .rejected(.damaged))
        var empty = good
        empty.payload = Data()
        #expect(restore(empty) == .rejected(.damaged))
    }

    // MARK: Through the store

    @Test func aSnapshotSurvivesTheStoreAndIsRejectedAfterAWrite() async throws {
        let s = try InMemoryStore.make()
        try await s.upsert([Make.item(Make.meta("a"))])
        let revision = try await s.revision()
        let count = try await s.loadLaunchState().itemCount
        let snapshot = ResultsSnapshot(
            results: results(), builderKey: key, itemCount: count, keepMarkCount: 0)
        #expect(
            try await s.saveSnapshot(
                try StateCodec.seal(snapshot), version: ResultsSnapshot.formatVersion,
                ifRevision: revision))
        var state = try await s.loadLaunchState()
        let ok = SnapshotRestore.restore(
            state.states[.results], expecting: key, revision: state.revision,
            itemCount: state.itemCount, keepMarkCount: state.keepMarks.count)
        #expect(ok.outcome == .restored)
        // A new photo arrives: the same snapshot is stale.
        try await s.upsert([Make.item(Make.meta("b"))])
        state = try await s.loadLaunchState()
        let stale = SnapshotRestore.restore(
            state.states[.results], expecting: key, revision: state.revision,
            itemCount: state.itemCount, keepMarkCount: state.keepMarks.count)
        #expect(stale.outcome == .rejected(.revision))
    }
}
