import CleanupKit
import Foundation

/// Compares what the real pipeline produced with what the catalog says it should produce.
/// Pure: it only reads its inputs, so it runs the same on every platform.
public enum BaselineValidator {
    public struct Input {
        public var catalog: BaselineCatalog
        public var rendered: [String: RenderedFile]
        /// The device's asset identifier to the catalog's asset id.
        public var mapping: [String: String]
        public var items: [LibraryItem]
        public var results: CleanupResults
        public var device: DeviceFacts
        public var startedAt: Date
        public var timings: [String: Double]

        public init(
            catalog: BaselineCatalog, rendered: [String: RenderedFile], mapping: [String: String],
            items: [LibraryItem], results: CleanupResults, device: DeviceFacts, startedAt: Date,
            timings: [String: Double]
        ) {
            self.catalog = catalog
            self.rendered = rendered
            self.mapping = mapping
            self.items = items
            self.results = results
            self.device = device
            self.startedAt = startedAt
            self.timings = timings
        }
    }

    public static func validate(_ input: Input) -> BaselineReport {
        let catalog = input.catalog
        let mapping = input.mapping
        let baseIDs = Set(mapping.values)
        let itemByBase: [String: LibraryItem] = Dictionary(
            input.items.compactMap { item in mapping[item.assetID].map { ($0, item) } },
            uniquingKeysWith: { a, _ in a })
        var deviceID: [String: String] = [:]
        for (device, base) in mapping { deviceID[base] = device }

        func ids(_ list: [String]) -> Set<String> { Set(list.compactMap { mapping[$0] }) }
        func groups(_ c: CleanupCategory) -> [(members: Set<String>, keepers: Set<String>, ordered: [String])] {
            (input.results.category(c)?.groups ?? []).map { g in
                (ids(g.members), ids(Array(g.keepers)), g.members.compactMap { mapping[$0] })
            }
        }
        func format(_ s: some Sequence<String>) -> String { s.sorted().joined(separator: ", ") }

        var checks: [BaselineCheck] = []
        var metrics: [String: Double] = [:]

        // MARK: Import fidelity (does the device keep what was imported?)

        let missing = catalog.assets.map(\.id).filter { !baseIDs.contains($0) }
        checks.append(
            missing.isEmpty
                ? BaselineCheck("import.complete", "Every baseline asset is in the library", .pass,
                    "\(catalog.assets.count) assets")
                : BaselineCheck("import.complete", "Every baseline asset is in the library", .fail,
                    "missing: \(format(missing))"))

        var wrongDate: [String] = []
        var wrongSize: [String] = []
        var wrongFavorite: [String] = []
        var wrongAlbums: [String] = []
        var wrongLocation: [String] = []
        for asset in catalog.assets {
            guard let item = itemByBase[asset.id] else { continue }
            let m = item.metadata
            if let d = m.captureDate, abs(d.timeIntervalSince(asset.captureDate)) > 2 {
                wrongDate.append(asset.id)
            } else if m.captureDate == nil {
                wrongDate.append(asset.id)
            }
            if let file = input.rendered[asset.id],
                m.pixelWidth != file.width || m.pixelHeight != file.height
            {
                wrongSize.append("\(asset.id) \(m.pixelWidth)x\(m.pixelHeight)")
            }
            if m.isFavorite != asset.favorite { wrongFavorite.append(asset.id) }
            if m.hasLocation != asset.location { wrongLocation.append(asset.id) }
            let wanted = Set([catalog.albumTitle] + asset.albums)
            if !wanted.isSubset(of: Set(m.albumNames)) { wrongAlbums.append(asset.id) }
        }
        checks.append(status("import.dates", "Capture dates are kept", wrongDate))
        checks.append(status("import.dimensions", "Pixel sizes are kept", wrongSize))
        checks.append(status("import.favorites", "Favorites are kept", wrongFavorite))
        checks.append(status("import.albums", "Album membership is kept", wrongAlbums))
        checks.append(status("import.locations", "Locations are kept", wrongLocation))

        // MARK: Scan

        let notScanned = input.items.filter { $0.analysisSource == .notScanned }.map(\.assetID)
            .compactMap { mapping[$0] }
        checks.append(
            status("scan.analyzed", "Every photo was analyzed from a local preview", notScanned))

        // Videos are never analyzed (004 FR-004a): each is stored by its metadata only.
        let analyzedVideos = input.items.filter {
            $0.metadata.kind.isVideo && ($0.analysisSource != .metadataOnly || $0.analysis != nil)
        }.compactMap { mapping[$0.assetID] }
        let videoAssets = catalog.assets.filter { $0.kind == .video }
        let videosSeen = videoAssets.filter { itemByBase[$0.id] != nil }.count
        checks.append(
            videosSeen == 0
                ? BaselineCheck("videos.notAnalyzed", "Videos are stored by metadata only", .skipped,
                    "no videos were imported")
                : status("videos.notAnalyzed", "Videos are stored by metadata only", analyzedVideos))

        // MARK: Duplicates

        func compareGroups(
            _ idPrefix: String, _ title: String, category: CleanupCategory,
            expected: [String: Set<String>]
        ) {
            let actual = groups(category)
            var notFound: [String] = []
            for (name, members) in expected.sorted(by: { $0.key < $1.key })
            where !actual.contains(where: { $0.members == members }) {
                let touching = actual.first { !$0.members.isDisjoint(with: members) }
                notFound.append(
                    touching == nil ? "\(name) (not grouped)"
                        : "\(name) (got \(format(touching!.members)))")
            }
            checks.append(status("\(idPrefix).groups", "\(title): every expected group is found exactly", notFound))
            let known = Set(expected.values)
            let extras = actual.filter { !known.contains($0.members) && !$0.members.isEmpty }
                .map { "[\(format($0.members))]" }
            checks.append(status("\(idPrefix).extras", "\(title): nothing else is grouped", extras))
        }

        compareGroups("duplicates", "Duplicate photos", category: .duplicates,
            expected: catalog.groups(.duplicates))
        compareGroups("similar", "Similar shots", category: .similar,
            expected: catalog.groups(.similar))

        // Keepers.
        var wrongKeepers: [String] = []
        for (name, members) in catalog.groups(.duplicates) {
            let wanted = Set(catalog.assets.filter { members.contains($0.id) && $0.keeper }.map(\.id))
            guard catalog.assets.contains(where: { members.contains($0.id) && $0.checkKeeper }),
                let actual = groups(.duplicates).first(where: { $0.members == members })
            else { continue }
            if actual.keepers != wanted {
                wrongKeepers.append("\(name): kept \(format(actual.keepers)), expected \(format(wanted))")
            }
        }
        checks.append(status("keepers", "The suggested keeper is the expected one", wrongKeepers))

        // MARK: Blurry

        let expectedBlurry = Set(
            catalog.assets.filter { $0.expected == .blurry && !$0.informational }.map(\.id))
        let actualBlurry = ids(input.results.category(.blurry)?.allMembers ?? [])
        let informational = catalog.assets.filter { $0.informational }.map(\.id)
        if !informational.isEmpty {
            let caught = informational.filter(actualBlurry.contains).count
            metrics["informational.caught"] = Double(caught)
            metrics["informational.total"] = Double(informational.count)
        }
        let notFlagged = expectedBlurry.subtracting(actualBlurry)
        checks.append(status("blur.flagged", "Out-of-focus photos are flagged", Array(notFlagged)))
        let controlIDs = Set(catalog.controls.map(\.id))
        let wronglyBlurry = controlIDs.intersection(actualBlurry)
        checks.append(status("blur.controls", "Sharp and low-detail photos are not flagged", Array(wronglyBlurry)))

        // MARK: Screenshots (only where the system tags the images)

        let screenshotAssets = catalog.assets.filter { $0.expected == .screenshots }
        let tagged = screenshotAssets.filter { itemByBase[$0.id]?.metadata.kind == .screenshot }
        if tagged.isEmpty {
            checks.append(BaselineCheck("screenshots.listed", "Screenshots are listed", .skipped,
                "this system did not tag the imported PNGs as screenshots"))
        } else if tagged.count != screenshotAssets.count {
            checks.append(BaselineCheck("screenshots.listed", "Screenshots are listed", .fail,
                "only \(tagged.count) of \(screenshotAssets.count) were tagged"))
        } else {
            let actual = ids(input.results.category(.screenshots)?.allMembers ?? [])
            let want = Set(screenshotAssets.map(\.id))
            checks.append(status("screenshots.listed", "Screenshots are listed",
                Array(want.symmetricDifference(actual))))
        }

        // MARK: Large videos

        let largeOrder = groups(.largeVideos).flatMap(\.ordered)
        let wantLarge = Set(catalog.assets.filter { $0.expected == .largeVideos }.map(\.id))
        var largeProblems: [String] = []
        for id in wantLarge.subtracting(largeOrder) { largeProblems.append("\(id) missing") }
        let sizes = largeOrder.compactMap { id in deviceID[id].flatMap { input.results.items[$0]?.effectiveByteSize } }
        if zip(sizes, sizes.dropFirst()).contains(where: { $0 < $1 }) {
            largeProblems.append("not ordered largest first")
        }
        let largeSelected = largeOrder.filter { id in deviceID[id].map(input.results.defaultSelection.contains) ?? false }
        if !largeSelected.isEmpty { largeProblems.append("pre-selected: \(format(largeSelected))") }
        checks.append(status("videos.large", "Large videos are listed largest first, none pre-selected", largeProblems))

        // MARK: Protection and selection

        let selected = ids(Array(input.results.defaultSelection))
        let favorites = Set(catalog.assets.filter(\.favorite).map(\.id))
        checks.append(status("protected.favorites", "Favorites are never selected for removal",
            Array(favorites.intersection(selected))))
        var selectionProblems: [String] = []
        for category in [CleanupCategory.duplicates, .similar, .blurry, .screenshots] {
            for g in groups(category) {
                let removable = g.members.subtracting(g.keepers)
                for r in removable where !selected.contains(r) { selectionProblems.append("\(r) not selected") }
                for k in g.keepers where selected.contains(k) { selectionProblems.append("keeper \(k) selected") }
            }
        }
        checks.append(status("selection.defaults", "Everything flagged starts selected, keepers do not",
            selectionProblems))

        // MARK: Controls

        let flagged = controlIDs.filter { id in
            deviceID[id].flatMap { input.results.category(of: $0) } != nil
        }
        checks.append(status("controls.clean", "Unrelated photos are not flagged by anything", Array(flagged)))

        // MARK: Metrics

        func metric(_ name: String, expected: BaselineCategory, actual: Set<String>) {
            let e = Set(catalog.assets.filter { $0.expected == expected && !$0.informational }.map(\.id))
            guard !e.isEmpty else { return }
            let hit = Double(e.intersection(actual).count)
            metrics["\(name).recall"] = hit / Double(e.count)
            metrics["\(name).precision"] = actual.isEmpty ? 1 : hit / Double(actual.count)
        }
        metric("duplicates", expected: .duplicates, actual: ids(input.results.category(.duplicates)?.allMembers ?? []))
        metric("similar", expected: .similar, actual: ids(input.results.category(.similar)?.allMembers ?? []))
        metric("blurry", expected: .blurry, actual: actualBlurry)

        // MARK: Capabilities and counts

        let photoItems = input.items.filter { !$0.metadata.kind.isVideo }
        let addedDates = input.items.filter { $0.metadata.addedDate != nil }.count
        let withPrint = photoItems.filter { !($0.analysis?.featurePrint.isEmpty ?? true) }.count
        let local = photoItems.filter { $0.analysisSource == .localPreview }.count
        var capabilities: [String: String] = [
            "featurePrints": withPrint == 0 ? "unavailable (Vision features missing)" : "available (\(withPrint) of \(photoItems.count))",
            "screenshotsTaggedBySystem": "\(tagged.count) of \(screenshotAssets.count)",
            "localPreviews": "\(local) of \(photoItems.count) photos",
            "addedDates": addedDates == 0
                ? "unavailable (this library gave none; the system provides it from iOS 26)"
                : "available (\(addedDates) of \(input.items.count))",
        ]
        capabilities["thermalAtEnd"] = input.device.thermalState

        var timings = input.timings
        if let scan = timings["scanSeconds"], scan > 0 {
            timings["itemsPerSecond"] = Double(input.items.count) / scan
        }
        return BaselineReport(
            fixtureVersion: catalog.version, fixtureName: catalog.name, startedAt: input.startedAt,
            device: input.device, capabilities: capabilities, timings: timings,
            counts: [
                "catalog": catalog.assets.count, "mapped": mapping.count,
                "analyzed": photoItems.count - notScanned.count, "notScanned": notScanned.count,
            ],
            metrics: metrics, checks: checks)
    }

    private static func status(_ id: String, _ title: String, _ problems: [String]) -> BaselineCheck {
        problems.isEmpty
            ? BaselineCheck(id, title, .pass)
            : BaselineCheck(id, title, .fail, problems.sorted().prefix(8).joined(separator: "; ")
                + (problems.count > 8 ? " … (+\(problems.count - 8))" : ""))
    }
}
