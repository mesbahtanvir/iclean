#if canImport(Photos) && canImport(Vision) && canImport(CoreGraphics)
import Foundation
import Photos
import Vision
import CoreGraphics
import ImageIO
#if canImport(CryptoKit)
import CryptoKit
#endif

/// PhotoKit-backed gateway. The ONLY place `import Photos` appears
/// (APP_PLATFORM.md §1). All heavy work happens off the main actor.
public final class PhotosGateway: PhotoLibraryGateway {
    /// Pinned Vision revision — distances are only valid within a revision;
    /// a bump is a detector version bump (SCAN_PIPELINE.md §5-S4, §14.1).
    /// If the pinned revision is unsupported on this OS, feature printing is
    /// disabled (nil computer) rather than run uncalibrated (§6.3).
    public static let pinnedFeaturePrintRevision = 2

    private let imageManager = PHImageManager.default()

    public init() {}

    // MARK: - S0 enumeration

    public func enumerateAssets(batchSize: Int) -> AsyncThrowingStream<[AssetStub], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let options = PHFetchOptions()
                options.includeAllBurstAssets = true // burst members must exist as rows — SCAN_PIPELINE.md §5-S0
                options.includeHiddenAssets = false
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)

                var batch: [AssetStub] = []
                batch.reserveCapacity(batchSize)
                for index in 0..<result.count {
                    if Task.isCancelled { break }
                    batch.append(Self.stub(from: result.object(at: index)))
                    if batch.count >= batchSize {
                        continuation.yield(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func persistentChanges(since token: Data?) -> AsyncThrowingStream<ChangeSet, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let library = PHPhotoLibrary.shared()
                    let sinceToken: PHPersistentChangeToken
                    if let token {
                        guard let unarchived = try? NSKeyedUnarchiver.unarchivedObject(
                            ofClass: PHPersistentChangeToken.self, from: token
                        ) else {
                            throw GatewayError.expiredChangeToken
                        }
                        sinceToken = unarchived
                    } else {
                        // No stored token: caller should run full enumeration instead.
                        sinceToken = library.currentChangeToken
                    }

                    let changes: PHPersistentChangeFetchResult
                    do {
                        changes = try library.fetchPersistentChanges(since: sinceToken)
                    } catch {
                        throw GatewayError.expiredChangeToken
                    }

                    for change in changes {
                        if Task.isCancelled { break }
                        guard let details = try? change.changeDetails(for: .asset) else { continue }
                        let insertedIds = Array(details.insertedLocalIdentifiers)
                        let updatedIds = Array(details.updatedLocalIdentifiers)
                        let deletedIds = Array(details.deletedLocalIdentifiers)

                        let tokenData = try? NSKeyedArchiver.archivedData(
                            withRootObject: change.changeToken, requiringSecureCoding: true
                        )
                        continuation.yield(
                            ChangeSet(
                                inserted: Self.stubs(forLocalIds: insertedIds),
                                updated: Self.stubs(forLocalIds: updatedIds),
                                deletedIds: deletedIds,
                                token: tokenData
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Current library token, for storing after a full enumeration completes.
    public func currentChangeTokenData() -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: PHPhotoLibrary.shared().currentChangeToken,
            requiringSecureCoding: true
        )
    }

    // MARK: - S1.5 albums

    public func userAlbums() async throws -> [AlbumInfo] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        var albums: [AlbumInfo] = []
        collections.enumerateObjects { collection, _, _ in
            let fetch = PHAsset.fetchAssets(in: collection, options: nil)
            var memberIds: [String] = []
            memberIds.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in memberIds.append(asset.localIdentifier) }
            albums.append(
                AlbumInfo(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "",
                    memberIds: memberIds
                )
            )
        }
        return albums
    }

    // MARK: - S2 thumbnails & probes

    public func grayThumbnail(assetId: String, maxDimension: Int, allowNetwork: Bool) async -> ThumbnailResult {
        guard let asset = Self.asset(assetId) else { return .failed("asset not found") }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // single callback — SCAN_PIPELINE.md §5-S2
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork
        options.isSynchronous = false

        let target = CGSize(width: maxDimension, height: maxDimension)
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: options
            ) { image, info in
                if let cgImage = image?.cgImage {
                    if let gray = Self.grayscale(cgImage, maxDimension: maxDimension) {
                        continuation.resume(returning: .ok(gray))
                    } else {
                        continuation.resume(returning: .failed("grayscale conversion failed"))
                    }
                } else if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
                    continuation.resume(returning: .needsConnection)
                } else {
                    let message = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "no image"
                    continuation.resume(returning: .failed(message))
                }
            }
        }
    }

    public func probeOriginalAvailability(assetId: String) async -> Availability {
        guard let asset = Self.asset(assetId) else { return .unknown }
        switch asset.mediaType {
        case .video:
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            return await withCheckedContinuation { continuation in
                self.imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if avAsset != nil {
                        continuation.resume(returning: .local)
                    } else if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
                        continuation.resume(returning: .evicted)
                    } else {
                        continuation.resume(returning: .unknown)
                    }
                }
            }
        default:
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat
            return await withCheckedContinuation { continuation in
                self.imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                    if data != nil {
                        continuation.resume(returning: .local)
                    } else if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
                        continuation.resume(returning: .evicted)
                    } else {
                        continuation.resume(returning: .unknown)
                    }
                }
            }
        }
    }

    public func byteHashIfLocal(assetId: String) async -> Data? {
        #if canImport(CryptoKit)
        guard let asset = Self.asset(assetId) else { return nil }
        guard let resource = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto })
        else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var hasher = SHA256()
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { data in hasher.update(data: data) },
                completionHandler: { error in
                    if error == nil {
                        continuation.resume(returning: Data(hasher.finalize()))
                    } else {
                        continuation.resume(returning: nil) // evicted or unreadable — stays "near-certain copy"
                    }
                }
            )
        }
        #else
        return nil
        #endif
    }

    // MARK: - S3 resources

    public func resourceInfo(assetId: String) async -> ResourceInfo? {
        guard let asset = Self.asset(assetId) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }

        let primary = resources.first {
            $0.type == .photo || $0.type == .video || $0.type == .fullSizePhoto
        } ?? resources[0]

        // No public file-size API — undocumented KVC key with an estimate fallback
        // (SCAN_PIPELINE.md §3). The canary: if the key vanishes in an iOS update,
        // sizes silently fall back to estimates rather than crashing.
        var fileSize: Int64?
        var isEstimate = false
        if primary.responds(to: NSSelectorFromString("fileSize")),
           let size = primary.value(forKey: "fileSize") as? Int64, size > 0 {
            fileSize = size
        } else {
            fileSize = Self.estimatedBytes(width: asset.pixelWidth, height: asset.pixelHeight,
                                           uti: primary.uniformTypeIdentifier,
                                           duration: asset.duration)
            isEstimate = true
        }

        let isEdited = resources.contains { $0.type == .adjustmentData }
        let hasRaw = resources.contains { $0.type == .alternatePhoto }

        return ResourceInfo(
            filename: primary.originalFilename,
            uti: primary.uniformTypeIdentifier,
            fileSize: fileSize,
            fileSizeIsEstimate: isEstimate,
            isEdited: isEdited,
            hasRawResource: hasRaw
        )
    }

    // MARK: - S4 Vision

    public func visionSignals(assetId: String, maxDimension: Int) async -> VisionSignals? {
        guard case let .ok(thumb) = await grayThumbnailAsCG(assetId: assetId, maxDimension: maxDimension) else {
            return nil
        }
        return Self.runVision(on: thumb)
    }

    public func confirmNoFaces(assetId: String) async -> Bool {
        // 1024-px best-local confirming pass before any no-face batch eligibility
        // (SCAN_PIPELINE.md §5-S4).
        guard case let .ok(cgImage) = await grayThumbnailAsCG(assetId: assetId, maxDimension: 1024) else {
            return false // can't confirm → not batch-eligible
        }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return false }
        return (request.results ?? []).isEmpty
    }

    public func featureDistances(assetIds: [String], maxDimension: Int) async -> FeatureDistanceComputer? {
        guard VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(Self.pinnedFeaturePrintRevision) else {
            return nil // unrecognized revision → similar detector disables (§6.3)
        }
        var prints: [String: VNFeaturePrintObservation] = [:]
        prints.reserveCapacity(assetIds.count)

        for id in assetIds {
            guard case let .ok(cgImage) = await grayThumbnailAsCG(assetId: id, maxDimension: maxDimension) else {
                continue
            }
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = Self.pinnedFeaturePrintRevision
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first as? VNFeaturePrintObservation
            else { continue }
            prints[id] = observation
        }
        guard !prints.isEmpty else { return nil }

        let captured = prints
        return FeatureDistanceComputer(visionRevision: Self.pinnedFeaturePrintRevision) { a, b in
            guard let pa = captured[a], let pb = captured[b] else { return nil }
            var distance: Float = 0
            guard (try? pa.computeDistance(&distance, to: pb)) != nil else { return nil }
            return Double(distance)
        }
    }

    // MARK: - §9 cloud identifiers

    public func cloudIdentifiers(forLocalIds ids: [String]) async -> [String: String] {
        let mappings = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: ids)
        var out: [String: String] = [:]
        for (localId, result) in mappings {
            if let cloudId = try? result.get() { out[localId] = cloudId.stringValue }
        }
        return out
    }

    public func localIdentifiers(forCloudIds ids: [String]) async -> [String: String] {
        let cloudIds = ids.map { PHCloudIdentifier(stringValue: $0) }
        let mappings = PHPhotoLibrary.shared().localIdentifierMappings(for: cloudIds)
        var out: [String: String] = [:]
        for (cloudId, result) in mappings {
            if let localId = try? result.get() { out[cloudId.stringValue] = localId }
        }
        return out
    }

    // MARK: - Commit (APP_PLATFORM.md §2)

    public func performCommitChunk(_ plan: CommitChunkPlan) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // Keeper inheritance FIRST, deletion LAST, one atomic block:
                // user-cancel throws and rolls back the inheritance too.
                for add in plan.albumAdds {
                    guard
                        let collection = PHAssetCollection.fetchAssetCollections(
                            withLocalIdentifiers: [add.albumId], options: nil
                        ).firstObject,
                        let keeper = PHAsset.fetchAssets(
                            withLocalIdentifiers: [add.keeperId], options: nil
                        ).firstObject,
                        let changeRequest = PHAssetCollectionChangeRequest(for: collection)
                    else { continue }
                    changeRequest.addAssets([keeper] as NSArray)
                }
                if !plan.favoriteKeeperIds.isEmpty {
                    let keepers = PHAsset.fetchAssets(withLocalIdentifiers: plan.favoriteKeeperIds, options: nil)
                    keepers.enumerateObjects { asset, _, _ in
                        PHAssetChangeRequest(for: asset).isFavorite = true
                    }
                }
                let doomed = PHAsset.fetchAssets(withLocalIdentifiers: plan.deleteIds, options: nil)
                PHAssetChangeRequest.deleteAssets(doomed)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            throw CommitChunkError.userCancelled
        } catch {
            throw CommitChunkError.photoKit(String(describing: error))
        }
    }

    public func existingAssetIds(among ids: [String]) async -> Set<String> {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var existing: Set<String> = []
        fetch.enumerateObjects { asset, _, _ in existing.insert(asset.localIdentifier) }
        return existing
    }

    public func modificationDates(for ids: [String]) async -> [String: Date] {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out: [String: Date] = [:]
        fetch.enumerateObjects { asset, _, _ in
            if let date = asset.modificationDate { out[asset.localIdentifier] = date }
        }
        return out
    }

    // MARK: - Private helpers

    private static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func stubs(forLocalIds ids: [String]) -> [AssetStub] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var out: [AssetStub] = []
        out.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in out.append(stub(from: asset)) }
        return out
    }

    private static func stub(from asset: PHAsset) -> AssetStub {
        var subtypes: AssetSubtypes = []
        let raw = asset.mediaSubtypes
        if raw.contains(.photoScreenshot) { subtypes.insert(.screenshot) }
        if raw.contains(.photoPanorama) { subtypes.insert(.panorama) }
        if raw.contains(.photoHDR) { subtypes.insert(.hdr) }
        if raw.contains(.photoLive) { subtypes.insert(.livePhoto) }
        if raw.contains(.videoHighFrameRate) { subtypes.insert(.slomo) }
        if raw.contains(.videoTimelapse) { subtypes.insert(.timelapse) }
        if raw.contains(.photoDepthEffect) { subtypes.insert(.depthEffect) }

        var bucket: LocationBucket?
        if let coordinate = asset.location?.coordinate {
            // ~1 km grid; we never persist precise coordinates (SCAN_PIPELINE.md §5-S1).
            bucket = LocationBucket(
                lat: Int((coordinate.latitude / 0.01).rounded(.down)),
                lon: Int((coordinate.longitude / 0.01).rounded(.down))
            )
        }

        return AssetStub(
            id: asset.localIdentifier,
            mediaKind: asset.mediaType == .video ? .video : .image,
            subtypes: subtypes,
            createdAt: asset.creationDate,
            modifiedAt: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            burstId: asset.burstIdentifier,
            representsBurst: asset.representsBurst,
            isBurstUserPick: asset.burstSelectionTypes.contains(.userPick),
            locationBucket: bucket
        )
    }

    private enum CGResult {
        case ok(CGImage)
        case unavailable
    }

    private func grayThumbnailAsCG(assetId: String, maxDimension: Int) async -> CGResult {
        guard let asset = Self.asset(assetId) else { return .unavailable }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let target = CGSize(width: maxDimension, height: maxDimension)
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: options
            ) { image, _ in
                if let cgImage = image?.cgImage {
                    continuation.resume(returning: .ok(cgImage))
                } else {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    private static func grayscale(_ image: CGImage, maxDimension: Int) -> GrayThumbnail? {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayThumbnail(width: width, height: height, pixels: pixels)
    }

    private static func runVision(on cgImage: CGImage) -> VisionSignals? {
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([landmarksRequest, qualityRequest, saliencyRequest])) != nil else {
            return nil
        }

        let faces = landmarksRequest.results ?? []
        let qualities = (qualityRequest.results ?? []).compactMap(\.faceCaptureQuality)
        let bestQuality = qualities.map(Double.init).max()

        // Eyes-open derived from eye-landmark aspect ratio — custom logic with its
        // own error rate, part of the keep-best kernel's tuning scope
        // (SCAN_PIPELINE.md §3, DESIGN.md §5.8).
        var eyesOpenMin: Double?
        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            for eye in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                let points = eye.normalizedPoints
                guard points.count >= 4 else { continue }
                let xs = points.map { Double($0.x) }
                let ys = points.map { Double($0.y) }
                let widthSpan = (xs.max() ?? 0) - (xs.min() ?? 0)
                let heightSpan = (ys.max() ?? 0) - (ys.min() ?? 0)
                guard widthSpan > 0 else { continue }
                let ratio = heightSpan / widthSpan
                // EAR ~0.10 = closed, ~0.30 = open; normalize into 0...1.
                let openness = min(1.0, max(0.0, (ratio - 0.10) / 0.20))
                eyesOpenMin = min(eyesOpenMin ?? 1.0, openness)
            }
        }

        var saliencyBox: SaliencyBox?
        if let observation = saliencyRequest.results?.first,
           let salient = observation.salientObjects?.first {
            let box = salient.boundingBox
            saliencyBox = SaliencyBox(
                x: box.origin.x, y: box.origin.y,
                width: box.size.width, height: box.size.height
            )
        }

        return VisionSignals(
            faceCount: faces.count,
            bestFaceQuality: bestQuality,
            eyesOpenMin: eyesOpenMin,
            saliencyBox: saliencyBox
        )
    }

    private static func estimatedBytes(width: Int, height: Int, uti: String?, duration: TimeInterval) -> Int64 {
        if duration > 0 {
            // ~8 Mbps HEVC ballpark.
            return Int64(duration * 1_000_000)
        }
        let pixels = Int64(width * height)
        let bytesPerPixel: Double
        switch uti {
        case .some(let value) where value.contains("png"): bytesPerPixel = 2.0
        case .some(let value) where value.contains("heic"): bytesPerPixel = 0.25
        default: bytesPerPixel = 0.5 // JPEG-ish
        }
        return Int64(Double(pixels) * bytesPerPixel)
    }
}
#endif
