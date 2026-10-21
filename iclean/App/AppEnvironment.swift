import CleanupKit
import Foundation

/// The services the app uses. Built once at launch.
struct AppEnvironment: Sendable {
    let library: PhotoLibrary
    let store: Store
    let scanner: CleanupKit.Scanner
    let resultsBuilder: ResultsBuilder
    /// Reads the store and builds results without holding every fingerprint (spec 008).
    let resultsLoader: ResultsLoader
    let remover: Remover
    let sizeMeasurer: SizeMeasurer
    /// What Pro unlocks for this run. Free for everyone until the purchase exists.
    let features: ProFeatures

    static func live() -> AppEnvironment {
        #if DEBUG
            if LaunchArguments.isUITesting { return uiTesting() }
        #endif
        let library = PhotoKitLibrary()
        // The store opens itself off the main thread, on first use. If it cannot be opened the
        // app runs on a memory store and says so (it never silently looks like an empty library),
        // and the damaged files are left exactly as they are.
        let store = DeferredStore(
            opening: { try SwiftDataStore.onDisk() },
            fallback: { try SwiftDataStore.inMemory() },
            erase: { try SwiftDataStore.eraseStoreFiles(in: SwiftDataStore.storeFolder()) })
        return make(library: library, store: store)
    }

    static func make(
        library: PhotoLibrary, store: Store, features: ProFeatures = LaunchArguments.features
    ) -> AppEnvironment {
        let builder = DefaultResultsBuilder(detectors: Detectors.all(features))
        return AppEnvironment(
            library: library, store: store,
            scanner: ScanPipeline(
                library: library, store: store, analyzer: Detectors.analyzer,
                chunkSize: LaunchArguments.chunkSize, features: features,
                minProgressInterval: .milliseconds(250)),
            resultsBuilder: builder,
            resultsLoader: ResultsLoader(store: store, builder: builder),
            remover: DefaultRemover(library: library),
            sizeMeasurer: SizeMeasurer(library: library, store: store),
            features: features)
    }

    #if DEBUG
        static func uiTesting() -> AppEnvironment {
            let args = ProcessInfo.processInfo.arguments
            let store: DeferredStore
            if args.contains("-PersistStore") {
                // On disk in tmp, so a test can relaunch and resume (EdgeCaseTests).
                let folder = FileManager.default.temporaryDirectory.appending(path: "iclean-uitest")
                if args.contains("-ResetStore") { try? FileManager.default.removeItem(at: folder) }
                store = DeferredStore(
                    opening: { try SwiftDataStore.at(folder: folder) },
                    fallback: { try SwiftDataStore.inMemory() },
                    erase: { try SwiftDataStore.eraseStoreFiles(in: folder) })
            } else {
                store = DeferredStore(
                    opening: { try SwiftDataStore.inMemory() },
                    fallback: { try SwiftDataStore.inMemory() })
            }
            return make(
                library: DemoPhotoLibrary(scenario: LaunchArguments.demoScenario), store: store)
        }
    #endif
}

enum LaunchArguments {
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-UITesting") }

    /// DEBUG only: `-ChunkSize N` makes the small demo library span several chunks, so
    /// tests can prove that a resume continues from saved chunks (003).
    static var chunkSize: Int {
        #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-ChunkSize"), i + 1 < args.count,
                let n = Int(args[i + 1])
            {
                return n
            }
        #endif
        return 32
    }

    /// What Pro unlocks. Always free in a release build: the one-time Pro purchase is not
    /// built yet, and this is the single place it will plug into. DEBUG only:
    /// `-ProVideoAnalysis` turns video analysis on, so the Pro path can be tested.
    static var features: ProFeatures {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ProVideoAnalysis") { return .pro }
        #endif
        return .free
    }

    static var demoScenario: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-DemoScenario"), i + 1 < args.count { return args[i + 1] }
        return "standard"
    }
}
