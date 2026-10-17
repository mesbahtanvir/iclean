import Foundation
import Testing

@testable import CleanupKit

/// SC-002: ≥ 98% of true duplicate groups found, < 1% false duplicates.
@Suite struct DuplicateAccuracyTests {
    @Test func syntheticSet() async throws {
        try await measure(LabeledFixtures.duplicates(), name: "synthetic")
    }

    @Test(.enabled(if: LabeledFixtures.real() != nil)) func realPhotos() async throws {
        try await measure(LabeledFixtures.real()!, name: "real")
    }

    func measure(_ images: [LabeledImage], name: String) async throws {
        let items = try await LabeledFixtures.analyze(images)
        let groups = DuplicatePhotoDetector().detect(items: items)
        let truth = Dictionary(
            images.compactMap { l in l.duplicateGroup.map { (l.file, $0) } },
            uniquingKeysWith: { a, _ in a })
        let trueGroups = Dictionary(grouping: truth.keys, by: { truth[$0]! })

        // A true group is found when one detected group holds exactly its members.
        let detected = groups.map { Set($0.members) }
        let found = trueGroups.values.filter { detected.contains(Set($0)) }.count
        let recall = Double(found) / Double(trueGroups.count)

        // A grouped item is a false duplicate when it is not in the group's true set.
        var grouped = 0
        var wrong = 0
        for g in groups {
            let labels = g.members.map { truth[$0] }
            let majority = Dictionary(grouping: labels.compactMap { $0 }, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key
            for label in labels {
                grouped += 1
                if label == nil || label != majority { wrong += 1 }
            }
        }
        let falseRate = grouped == 0 ? 0 : Double(wrong) / Double(grouped)
        print("Duplicate accuracy (\(name)): recall \(recall), false duplicates \(falseRate), groups \(groups.count)/\(trueGroups.count)")
        #expect(recall >= 0.98)
        #expect(falseRate < 0.01)
    }
}

/// Exports the synthetic fixtures for the simulator when ICLEAN_EXPORT_FIXTURES=1.
@Suite struct FixtureExport {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ICLEAN_EXPORT_FIXTURES"] == "1"))
    func export() throws {
        let folder = LabeledFixtures.repoRoot.appending(path: "Fixtures/generated")
        var labels = try LabeledFixtures.export(LabeledFixtures.duplicates(), to: folder)
        labels += try LabeledFixtures.export(LabeledFixtures.extraSets(), to: folder)
        let data = try JSONEncoder.pretty.encode(labels)
        try data.write(to: folder.appending(path: "labels.json"))
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
