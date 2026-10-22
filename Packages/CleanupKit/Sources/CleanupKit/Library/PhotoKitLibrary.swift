#if canImport(Photos)
    import AVFoundation
    import Photos

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    /// PhotoKit implementation of `PhotoLibrary` (research R2, R7, R8, R10).
    public final class PhotoKitLibrary: NSObject, PhotoLibrary, PHPhotoLibraryChangeObserver,
        @unchecked Sendable
    {
        private let imageManager = PHImageManager()
        /// For pictures on the screen: it keeps what was prefetched, and scrolling asks it for the
        /// same images (see `thumbnails`). Separate from `imageManager`, which the scan uses.
        private let cachingManager: PHCachingImageManager = {
            let manager = PHCachingImageManager()
            // Many small thumbnails: the manager must not hold on to full-quality copies.
            manager.allowsCachingHighQualityImages = false
            return manager
        }()
        /// One shared instance: PhotoKit reuses a prefetched image only for identical options.
        nonisolated(unsafe) private static let thumbnailOptions = NetworkOffOptions.thumbnail()
        /// Assets already looked up, so the picture of a cell does not cost a fetch of its own.
        /// PHAsset objects are snapshots, so this is emptied whenever the library changes.
        private let assetCache: NSCache<NSString, PHAsset> = {
            let cache = NSCache<NSString, PHAsset>()
            cache.countLimit = 4_000
            return cache
        }()
        /// Start and stop of prefetching happen in order, off the main thread.
        private let prefetchQueue = DispatchQueue(label: "iclean.prefetch", qos: .userInitiated)
        /// Decodes the pictures PhotoKit delivers, one at a time and in order, off the main thread.
        private let decodeQueue = DispatchQueue(label: "iclean.decode", qos: .userInitiated)
        private let lock = NSLock()
        private var fetchResult: PHFetchResult<PHAsset>?
        private var continuations: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

        public override init() {
            super.init()
        }

        deinit {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }

        // MARK: Access

        public func authorizationStatus() -> LibraryAccess {
            Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }

        public func requestAuthorization() async -> LibraryAccess {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            let access = Self.map(status)
            if access == .full || access == .limited {
                PHPhotoLibrary.shared().register(self)
            }
            return access
        }

        private static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
            switch status {
            case .authorized: .full
            case .limited: .limited
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        }

        // MARK: Metadata

        public func fetchAllItems() async -> [AssetMetadata] {
            if authorizationStatus() == .full || authorizationStatus() == .limited {
                PHPhotoLibrary.shared().register(self)
            }
            let options = PHFetchOptions()
            // Only the user's own library: shared-album items are never touched.
            options.includeAssetSourceTypes = [.typeUserLibrary]
            options.includeAllBurstAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)
            lock.withLock { fetchResult = result }

            let albums = albumNamesByAsset()
            var items: [AssetMetadata] = []
            items.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image || asset.mediaType == .video else { return }
                items.append(Self.metadata(for: asset, albums: albums[asset.localIdentifier] ?? []))
            }
            return items
        }

        public func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
            guard !assetIDs.isEmpty else { return [] }
            var assets: [PHAsset] = []
            // The same view of the library as the full enumeration: the person's own library, bursts
            // included, and nothing hidden. A photo that is hidden, in Recently Deleted or outside
            // a limited selection is simply not returned, which is what a check before removing wants.
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = [.typeUserLibrary]
            options.includeAllBurstAssets = true
            PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: options).enumerateObjects {
                asset, _, _ in
                guard !asset.isHidden else { return }
                if asset.mediaType == .image || asset.mediaType == .video { assets.append(asset) }
            }
            return assets.map { asset in
                var names: [String] = []
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
                    .enumerateObjects { album, _, _ in
                        if album.assetCollectionSubtype == .albumRegular {
                            names.append(album.localizedTitle ?? "")
                        }
                    }
                return Self.metadata(for: asset, albums: names)
            }
        }

        public func stamps(forIDs assetIDs: [String]) async -> [String: AssetStamp] {
            guard !assetIDs.isEmpty else { return [:] }
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = [.typeUserLibrary]
            options.includeAllBurstAssets = true
            var out: [String: AssetStamp] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: options).enumerateObjects {
                asset, _, _ in
                guard !asset.isHidden, asset.mediaType == .image || asset.mediaType == .video
                else { return }
                out[asset.localIdentifier] = AssetStamp(
                    modificationDate: asset.modificationDate, isFavorite: asset.isFavorite,
                    hasAdjustments: asset.hasAdjustments, pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight)
            }
            return out
        }

        static func metadata(for asset: PHAsset, albums: [String]) -> AssetMetadata {
            let subtypes = asset.mediaSubtypes
            let kind: ItemKind =
                if asset.mediaType == .video {
                    .video
                } else if subtypes.contains(.photoScreenshot) {
                    .screenshot
                } else if subtypes.contains(.photoLive) {
                    .livePhoto
                } else {
                    .photo
                }
            return AssetMetadata(
                assetID: asset.localIdentifier, kind: kind, captureDate: asset.creationDate,
                modificationDate: asset.modificationDate, pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.mediaType == .video ? asset.duration : nil,
                isFavorite: asset.isFavorite, hasAdjustments: asset.hasAdjustments,
                isPortrait: subtypes.contains(.photoDepthEffect),
                isLongExposure: LongExposure.isLongExposure(asset),
                burstID: asset.burstIdentifier, albumNames: albums,
                addedDate: Self.addedDate(of: asset), hasLocation: asset.location != nil)
        }

        /// When the asset was added to the library, where the system says (iOS 26, macOS 26 and
        /// visionOS 26 and later).
        private static func addedDate(of asset: PHAsset) -> Date? {
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) { return asset.addedDate }
            return nil
        }

        /// Names of the user's own albums for each asset.
        private func albumNamesByAsset() -> [String: [String]] {
            var map: [String: [String]] = [:]
            let albums = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            albums.enumerateObjects { album, _, _ in
                let name = album.localizedTitle ?? ""
                PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                    map[asset.localIdentifier, default: []].append(name)
                }
            }
            return map
        }

        private func asset(_ id: String) -> PHAsset? {
            if let cached = assetCache.object(forKey: id as NSString) { return cached }
            guard
                let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                    .firstObject
            else { return nil }
            assetCache.setObject(found, forKey: id as NSString)
            return found
        }

        /// Many assets in one fetch, for prefetching a screenful at a time.
        private func assets(_ ids: [String]) -> [PHAsset] {
            var found: [PHAsset] = []
            var missing: [String] = []
            for id in ids {
                if let cached = assetCache.object(forKey: id as NSString) {
                    found.append(cached)
                } else {
                    missing.append(id)
                }
            }
            if !missing.isEmpty {
                PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
                    .enumerateObjects { asset, _, _ in
                        self.assetCache.setObject(asset, forKey: asset.localIdentifier as NSString)
                        found.append(asset)
                    }
            }
            return found
        }

        // MARK: Previews

        public func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
            guard let asset = asset(assetID) else { return .unavailable }
            let size = CGSize(width: maxPixels, height: maxPixels)
            let (image, inCloud) = await requestImage(
                asset, size: size,
                options: NetworkOffOptions.image(deliveryMode: .highQualityFormat))
            if let image { return .local(image) }
            guard inCloud else { return .unavailable }
            let (thumb, _) = await requestImage(
                asset, size: size, options: NetworkOffOptions.image(deliveryMode: .fastFormat))
            return thumb.map(PreviewResult.cloudPreview) ?? .unavailable
        }

        // MARK: Thumbnails

        private static func targetSize(_ pixelSize: Int) -> CGSize {
            CGSize(width: pixelSize, height: pixelSize)
        }

        private static func contentMode(_ fit: ThumbnailFit) -> PHImageContentMode {
            fit == .fill ? .aspectFill : .aspectFit
        }

        public func thumbnails(for assetID: String, pixelSize: Int, fit: ThumbnailFit)
            -> AsyncStream<ThumbnailImage>
        {
            AsyncStream { continuation in
                let token = RequestToken()
                let manager = cachingManager
                // Looked up and requested on the ordered background queue, behind any prefetch that
                // is filling the asset cache, so no cell costs the main thread a PhotoKit fetch.
                prefetchQueue.async { [self] in
                    guard !token.isCancelled, let asset = self.asset(assetID) else {
                        continuation.finish()
                        return
                    }
                    let requestID = manager.requestImage(
                        for: asset, targetSize: Self.targetSize(pixelSize),
                        contentMode: Self.contentMode(fit), options: Self.thumbnailOptions
                    ) { image, info in
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                        let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                        let failed = info?[PHImageErrorKey] != nil
                        // PhotoKit calls this on the main thread for a picture that was not at hand,
                        // so the decode is handed to a queue of ours, which keeps the order of the
                        // quick picture and the final one and never makes scrolling wait.
                        let handoff = ImageHandoff(image)
                        self.decodeQueue.async {
                            // A cell that scrolled away is not waiting: skip the decode.
                            if token.isCancelled {
                                continuation.finish()
                                return
                            }
                            if let cgImage = handoff.image.flatMap(Self.displayReady) {
                                continuation.yield(
                                    ThumbnailImage(image: cgImage, isFinal: !degraded))
                            }
                            // A degraded picture is followed by the final one (or by a failure), so
                            // the stream stays open for it.
                            if !degraded || cancelled || failed { continuation.finish() }
                        }
                    }
                    token.began(requestID, on: manager)
                }
                continuation.onTermination = { _ in token.cancel(on: manager) }
            }
        }

        public func startPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit) {
            guard !assetIDs.isEmpty else { return }
            prefetchQueue.async { [self] in
                cachingManager.startCachingImages(
                    for: assets(assetIDs), targetSize: Self.targetSize(pixelSize),
                    contentMode: Self.contentMode(fit), options: Self.thumbnailOptions)
            }
        }

        public func stopPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit) {
            guard !assetIDs.isEmpty else { return }
            prefetchQueue.async { [self] in
                cachingManager.stopCachingImages(
                    for: assets(assetIDs), targetSize: Self.targetSize(pixelSize),
                    contentMode: Self.contentMode(fit), options: Self.thumbnailOptions)
            }
        }

        private func requestImage(
            _ asset: PHAsset, size: CGSize, options: PHImageRequestOptions
        ) async -> (CGImage?, Bool) {
            await withCheckedContinuation { continuation in
                let once = Once()
                imageManager.requestImage(
                    for: asset, targetSize: size, contentMode: .aspectFit, options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded, options.deliveryMode != .fastFormat { return }
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    let cgImage = image.flatMap(Self.cgImage)
                    once.run { continuation.resume(returning: (cgImage, inCloud)) }
                }
            }
        }

        /// The image PhotoKit hands back is a `UIImage` on iOS and visionOS and an `NSImage` on
        /// the Mac; the rest of the package only knows `CGImage`.
        #if canImport(UIKit)
            typealias PlatformImage = UIImage
            private static func cgImage(_ image: UIImage) -> CGImage? { image.cgImage }
            /// Decoded off the main thread (see `decodeQueue`), so drawing a cell does not decode it.
            private static func displayReady(_ image: UIImage) -> CGImage? {
                (image.preparingForDisplay() ?? image).cgImage
            }
        #elseif canImport(AppKit)
            typealias PlatformImage = NSImage
            private static func cgImage(_ image: NSImage) -> CGImage? {
                image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            private static func displayReady(_ image: NSImage) -> CGImage? { cgImage(image) }
        #endif

        // MARK: Playback

        /// A player item for a video whose file is on the phone. Network access is off, so a video
        /// that is only in iCloud gives nil and is never downloaded to play it.
        public func playerItem(for assetID: String) async -> PlayableVideo? {
            guard let asset = asset(assetID), asset.mediaType == .video else { return nil }
            return await withCheckedContinuation { continuation in
                let once = Once()
                imageManager.requestPlayerItem(
                    forVideo: asset, options: NetworkOffOptions.video()
                ) { item, _ in
                    once.run { continuation.resume(returning: item.map(PlayableVideo.init)) }
                }
            }
        }

        // MARK: Sizes

        public func localByteSize(for assetID: String) async -> Int64? {
            guard let asset = asset(assetID) else { return nil }
            if asset.mediaType == .video {
                return await videoFileSize(asset)
            }
            let resources = PHAssetResource.assetResources(for: asset)
            var total: Int64 = 0
            for resource in resources {
                guard let bytes = await resourceSize(resource) else { return nil }
                total += bytes
            }
            return total
        }

        private func videoFileSize(_ asset: PHAsset) async -> Int64? {
            await withCheckedContinuation { continuation in
                imageManager.requestAVAsset(forVideo: asset, options: NetworkOffOptions.video()) {
                    avAsset, _, _ in
                    guard let url = (avAsset as? AVURLAsset)?.url,
                        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: Int64(size))
                }
            }
        }

        private func resourceSize(_ resource: PHAssetResource) async -> Int64? {
            await withCheckedContinuation { continuation in
                let counter = ByteCounter()
                PHAssetResourceManager.default().requestData(
                    for: resource, options: NetworkOffOptions.resource(),
                    dataReceivedHandler: { counter.add($0.count) },
                    completionHandler: { error in
                        continuation.resume(returning: error == nil ? counter.total : nil)
                    })
            }
        }

        // MARK: Removal

        public func remove(_ assetIDs: [String]) async -> RemovalResult {
            guard !assetIDs.isEmpty else { return RemovalResult(removed: [], failed: []) }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            var found: [String] = []
            assets.enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
            let missing = Set(assetIDs).subtracting(found)
            // One request, so the system shows one confirmation for the whole selection.
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
                return RemovalResult(removed: found, failed: Array(missing))
            } catch let error as NSError {
                if error.domain == PHPhotosErrorDomain,
                    error.code == PHPhotosError.userCancelled.rawValue
                {
                    return RemovalResult(removed: [], failed: [], cancelled: true)
                }
                return RemovalResult(removed: [], failed: assetIDs)
            }
        }

        // MARK: Changes

        public func changes() -> AsyncStream<LibraryChange> {
            AsyncStream { continuation in
                let id = UUID()
                lock.withLock { continuations[id] = continuation }
                continuation.onTermination = { [weak self] _ in
                    self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
                }
            }
        }

        public func photoLibraryDidChange(_ changeInstance: PHChange) {
            // Looked-up assets are snapshots: an edited or removed photo must be looked up again.
            assetCache.removeAllObjects()
            let (change, listeners): (LibraryChange?, [AsyncStream<LibraryChange>.Continuation]) =
                lock.withLock {
                    guard let current = fetchResult,
                        let details = changeInstance.changeDetails(for: current)
                    else { return (nil, Array(continuations.values)) }
                    fetchResult = details.fetchResultAfterChanges
                    let changed = Set(
                        (details.insertedObjects + details.changedObjects).map(\.localIdentifier))
                    let removed = Set(details.removedObjects.map(\.localIdentifier))
                    return (
                        LibraryChange(insertedOrChanged: changed, removed: removed),
                        Array(continuations.values)
                    )
                }
            guard let change, !(change.insertedOrChanged.isEmpty && change.removed.isEmpty) else {
                return
            }
            listeners.forEach { $0.yield(change) }
        }
    }

    /// Lets a stream that ends early (a cell scrolled away) cancel a request that may not have
    /// started yet.
    private final class RequestToken: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func began(_ id: PHImageRequestID, on manager: PHImageManager) {
            let alreadyCancelled = lock.withLock {
                if !cancelled { requestID = id }
                return cancelled
            }
            if alreadyCancelled { manager.cancelImageRequest(id) }
        }

        func cancel(on manager: PHImageManager) {
            let id = lock.withLock {
                cancelled = true
                return requestID
            }
            if let id { manager.cancelImageRequest(id) }
        }
    }

    /// A picture on its way from PhotoKit's callback to the decode queue. Nothing else touches it.
    private struct ImageHandoff: @unchecked Sendable {
        let image: PhotoKitLibrary.PlatformImage?
        init(_ image: PhotoKitLibrary.PlatformImage?) { self.image = image }
    }

    /// Runs a closure at most once (PhotoKit callbacks may fire more than once).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock {
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }

    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int64 = 0
        func add(_ n: Int) { lock.withLock { count += Int64(n) } }
        var total: Int64 { lock.withLock { count } }
    }
#endif
