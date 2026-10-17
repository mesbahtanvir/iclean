import CleanupKit
import Foundation

/// The services the app uses. Built once at launch.
struct AppEnvironment: Sendable {
    let library: PhotoLibrary
    let store: Store
    let scanner: CleanupKit.Scanner
    let resultsBuilder: ResultsBuilder
    let remover: Remover
    let sizeMeasurer: SizeMeasurer

    static func live() -> AppEnvironment {
        #if DEBUG
            if LaunchArguments.isUITesting { return uiTesting() }
        #endif
        let library = PhotoKitLibrary()
        // The on-disk store only fails if Application Support is unusable; fall back to
        // memory so the app still works (results are then not remembered).
        let store: Store = (try? SwiftDataStore.onDisk()) ?? (try! SwiftDataStore.inMemory())
        return make(library: library, store: store)
    }

    static func make(library: PhotoLibrary, store: Store) -> AppEnvironment {
        AppEnvironment(
            library: library, store: store,
            scanner: ScanPipeline(library: library, store: store, analyzer: Detectors.analyzer),
            resultsBuilder: DefaultResultsBuilder(detectors: Detectors.all),
            remover: DefaultRemover(library: library),
            sizeMeasurer: SizeMeasurer(library: library, store: store))
    }

    #if DEBUG
        static func uiTesting() -> AppEnvironment {
            let args = ProcessInfo.processInfo.arguments
            var store: Store = try! SwiftDataStore.inMemory()
            if args.contains("-PersistStore") {
                // On disk in tmp, so a test can relaunch and resume (EdgeCaseTests).
                let folder = FileManager.default.temporaryDirectory.appending(path: "iclean-uitest")
                if args.contains("-ResetStore") { try? FileManager.default.removeItem(at: folder) }
                store = try! SwiftDataStore.at(folder: folder)
            }
            return make(library: DemoPhotoLibrary(scenario: LaunchArguments.demoScenario), store: store)
        }
    #endif
}

enum LaunchArguments {
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-UITesting") }

    static var demoScenario: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-DemoScenario"), i + 1 < args.count { return args[i + 1] }
        return "standard"
    }
}
