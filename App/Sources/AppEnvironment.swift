import Foundation
import BackgroundTasks
import Photos
import SwiftUI
import PhotoGateway
import ScanEngine
import ProposalStore
import CommitEngine
import Entitlements
import iCleanUI

/// Composition root — the only place all modules meet (APP_PLATFORM.md §1).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()
    static let backgroundTaskIdentifier = "com.iclean.scan.processing"

    let gateway = PhotosGateway()
    let imageLoader = PhotoCardImageLoader()

    private(set) var database: AppDatabase?
    private(set) var deckStore: DeckStore?
    private(set) var commitRunner: CommitRunner?
    private var orchestrator: ScanOrchestrator?
    private var scanTask: Task<Void, Never>?

    #if canImport(StoreKit)
    let entitlements = StoreEntitlements()
    #else
    let entitlements = FixedEntitlements(unlocked: false)
    #endif

    private init() {
        do {
            let database = try AppDatabase.open()
            self.database = database
            self.deckStore = DeckStore(database: database)
            self.commitRunner = CommitRunner(
                database: database,
                gateway: gateway,
                entitlements: entitlements
            )
            let store = GRDBPipelineStore(database: database)
            let governor = Governor(inputs: GovernorInputs(
                thermalLevel: { ProcessInfo.processInfo.thermalState.rawValue },
                isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                batteryFraction: { Double(UIDevice.current.batteryLevel) },
                isCharging: {
                    UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
                },
                isMemoryConstrained: { false } // wire os_proc_available_memory during device tuning
            ))
            self.orchestrator = ScanOrchestrator(gateway: gateway, store: store, governor: governor)
        } catch {
            assertionFailure("database bootstrap failed: \(error)")
        }
    }

    func startEntitlements() {
        #if canImport(StoreKit)
        Task { await entitlements.startListening() }
        #endif
    }

    func startFirstScanIfNeeded() {
        guard scanTask == nil, let orchestrator else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        scanTask = Task.detached(priority: .utility) {
            await orchestrator.onAppForeground()
            await orchestrator.runIncremental() // full scan when no token exists
        }
    }

    // MARK: - Background lane (SCAN_PIPELINE.md §8)

    func scheduleBackgroundScanIfNeeded() {
        guard let orchestrator else { return }
        Task {
            guard await orchestrator.hasPendingWork() else { return }
            let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            // Submitted idempotently — replaces any pending request.
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    nonisolated func handleBackgroundTask(_ task: BGProcessingTask) {
        let flag = ExpirationFlag()
        task.expirationHandler = { flag.expire() }
        Task { @MainActor in
            guard let orchestrator = self.orchestrator else {
                task.setTaskCompleted(success: false)
                return
            }
            await orchestrator.runBackground(shouldContinue: { !flag.isExpired })
            self.scheduleBackgroundScanIfNeeded() // resubmit if work remains
            task.setTaskCompleted(success: true)
        }
    }
}

/// Expiration flag checked at every batch boundary.
final class ExpirationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    var isExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func expire() {
        lock.lock()
        expired = true
        lock.unlock()
    }
}

/// UI image loading — best local image, never triggers iCloud downloads
/// (SCAN_PIPELINE.md §3 constraint 1).
final class PhotoCardImageLoader: CardImageLoading, @unchecked Sendable {
    private let manager = PHCachingImageManager()

    func image(assetId: String, maxDimension: Int) async -> Image? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetId], options: nil
        ).firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: maxDimension, height: maxDimension),
                contentMode: .aspectFit,
                options: options
            ) { uiImage, _ in
                continuation.resume(returning: uiImage.map(Image.init(uiImage:)))
            }
        }
    }
}
