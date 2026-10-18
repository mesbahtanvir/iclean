import CleanupKit
import Foundation

/// Runs the real pipeline (the scanner, the analyzer, the size measurer and the detectors the
/// app uses) over the baseline assets of one library and validates the outcome.
public enum BaselineRunner {
    /// - Parameters:
    ///   - library: the library holding the baseline assets, real or rendered.
    ///   - mapping: the library's asset identifier to the catalog's asset id.
    ///   - importSeconds: how long importing took, when it was done in this run.
    public static func run(
        catalog: BaselineCatalog, rendered: [String: RenderedFile], library: any PhotoLibrary,
        mapping: [String: String], importSeconds: Double? = nil,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> BaselineReport {
        let started = Date()
        // Only the baseline assets: the rest of the person's photos stay untouched.
        let subset = SubsetPhotoLibrary(base: library, allowed: Set(mapping.keys))
        // Its own store, in memory: nothing here touches the app's saved results.
        let store = try SwiftDataStore.inMemory()
        let scanner = ScanPipeline(
            library: subset, store: store, analyzer: StandardPipeline.analyzer, features: .free)

        let clock = ContinuousClock()
        let scanStart = clock.now
        for await p in await scanner.startFullScan() { progress?(p) }
        let scanSeconds = seconds(clock.now - scanStart)

        // The app measures real sizes after the first results and uses them from then on.
        var items = try await store.items()
        _ = await SizeMeasurer(library: subset, store: store).measure(items)
        items = try await store.items()

        let buildStart = clock.now
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors(.free))
            .buildResults(items: items, keepMarks: [])
        let resultsSeconds = seconds(clock.now - buildStart)

        var timings: [String: Double] = ["scanSeconds": scanSeconds, "resultsSeconds": resultsSeconds]
        if let importSeconds { timings["importSeconds"] = importSeconds }
        return BaselineValidator.validate(
            .init(
                catalog: catalog, rendered: rendered, mapping: mapping, items: items,
                results: results, device: .current(), startedAt: started, timings: timings))
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
