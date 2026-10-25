import BaselineKit
import Foundation
import Testing

@testable import CleanupKit

/// The baseline library on the development machine. The catalog is calibrated here, with
/// the real analyzer and detectors, so that a failure on a device points at the device.
@Suite struct BaselineHostTests {
    let catalog = BaselineCatalogV4.make()

    @Test func theCatalogIsConsistent() {
        let ids = catalog.assets.map(\.id)
        #expect(Set(ids).count == ids.count, "asset ids are unique")
        let names = catalog.assets.map(\.filename)
        #expect(Set(names).count == names.count, "file names are unique")
        #expect(
            names.allSatisfy { $0.hasPrefix("BASE\(catalog.version)_") },
            "file names carry the catalog version, so an older import is never reused")
        #expect(catalog.assets.count >= 60)
        for category in [BaselineCategory.duplicates, .similar] {
            for (group, members) in catalog.groups(category) {
                #expect(members.count >= 2, "\(group) has at least two members")
                let checked = catalog.assets.filter { members.contains($0.id) && $0.checkKeeper }
                if !checked.isEmpty {
                    #expect(checked.filter(\.keeper).count == 1, "\(group) has exactly one keeper")
                }
            }
        }
        // Every category is covered.
        for category in [
            BaselineCategory.duplicates, .similar, .blurry, .screenshots, .largeVideos, .none,
        ] {
            #expect(catalog.assets.contains { $0.expected == category }, "\(category) is covered")
        }
    }

    @Test func theCatalogRendersTheSameBytesTwice() async throws {
        let sample = catalog.assets.filter { ["dup-A2", "sim-A-3"].contains($0.id) }
        for asset in sample {
            let a = try BaselineRenderer.image(for: asset.recipe)
            let b = try BaselineRenderer.image(for: asset.recipe)
            #expect(a.width == b.width && a.height == b.height)
            #expect(a.dataProvider?.data == b.dataProvider?.data, "\(asset.id) renders identically")
        }
    }

    @Test func theBaselineLibraryPassesOnThisMachine() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "iclean-baseline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendered = try await BaselineRenderer.renderAll(catalog, to: folder)
        let library = RenderedPhotoLibrary(catalog: catalog, rendered: rendered)
        let mapping = Dictionary(uniqueKeysWithValues: catalog.assets.map { ($0.id, $0.id) })
        let report = try await BaselineRunner.run(
            catalog: catalog, rendered: rendered, library: library, mapping: mapping)
        print(report.summary())
        print(
            report.metrics.sorted { $0.key < $1.key }.map {
                "\($0.key)=\(String(format: "%.2f", $0.value))"
            }.joined(separator: " "))
        #expect(report.failed.isEmpty, "\n\(report.summary())")
    }

    /// What the results builder produces for the baseline library, as a fingerprint of the groups
    /// and the kept copy of each (only the parts the catalog asserts, so no borderline photo can
    /// make it differ between machines). A saved snapshot is trusted only while
    /// `BuilderVersion.current` is the version the builder had when it was saved, so a change of
    /// behaviour that moves this fingerprint must bump the version, and this test makes you say
    /// so by updating both numbers together.
    @Test func theBuilderOutputOnTheBaselineIsPinnedToTheBuilderVersion() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "iclean-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendered = try await BaselineRenderer.renderAll(catalog, to: folder)
        let library = RenderedPhotoLibrary(catalog: catalog, rendered: rendered)
        let subset = SubsetPhotoLibrary(base: library, allowed: Set(catalog.assets.map(\.id)))
        let store = try SwiftDataStore.inMemory()
        let scanner = ScanPipeline(
            library: subset, store: store, analyzer: StandardPipeline.analyzer)
        for await _ in await scanner.startFullScan() {}
        var items = try await store.items()
        _ = await SizeMeasurer(library: subset, store: store).measure(items)
        items = try await store.items()
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: items, keepMarks: [])

        var lines: [String] = []
        for c in results.categories
        where [.duplicates, .similar, .largeVideos].contains(c.category) {
            for g in c.groups {
                lines.append(
                    "\(c.category.rawValue)|\(g.members.sorted().joined(separator: ","))|"
                        + g.keepers.sorted().joined(separator: ","))
            }
        }
        lines.sort()
        let fingerprint = StateCodec.checksum(Data(lines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
        print("builder fingerprint \(fingerprint) for BuilderVersion \(BuilderVersion.current)")
        #expect(
            fingerprint == Self.pinnedFingerprint && BuilderVersion.current == Self.pinnedVersion,
            """
            The results builder's output on the baseline library changed, or the builder version did.
            If the output changed on purpose, bump BuilderVersion.current so saved results built the
            old way are never shown, then set pinnedVersion and pinnedFingerprint to the new values
            printed above. Lines:\n\(lines.joined(separator: "\n"))
            """)
    }

    static let pinnedVersion = 1
    static let pinnedFingerprint = "d147a997dda94d41"
}
