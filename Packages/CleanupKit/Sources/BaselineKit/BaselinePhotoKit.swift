#if canImport(Photos)
    import CoreLocation
    import Foundation
    import Photos

    /// Puts the baseline assets into the real Photos library and finds them again. Works the
    /// same on every platform that has PhotoKit, so one catalog tests every device.
    ///
    /// Imported assets keep a fixed file name, capture date, favorite flag, location and album, and all
    /// of them sit in the baseline album, so they can be listed and removed as one set. If
    /// iCloud Photos is on, the system syncs them like any other photos; use a test library or
    /// remove them afterwards.
    public enum BaselinePhotoKit {
        public struct ImportSummary: Sendable {
            public var imported: Int
            public var alreadyThere: Int
            public var seconds: Double
        }

        // MARK: Access

        /// Asks for read and write access. Throws, naming the status, when the baseline assets
        /// cannot be seen.
        public static func requestAccess() async throws {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                let name: String
                switch status {
                case .notDetermined: name = "not determined"
                case .restricted: name = "restricted"
                case .denied: name = "denied"
                default: name = "unknown"
                }
                throw BaselineError.notAuthorized(name)
            }
        }

        // MARK: Finding what is already there

        /// The baseline album, if it exists.
        static func album(titled title: String) -> PHAssetCollection? {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", title)
            return PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: options
            ).firstObject
        }

        static func originalFilename(_ asset: PHAsset) -> String? {
            PHAssetResource.assetResources(for: asset).first?.originalFilename
        }

        /// File name to asset, for what the baseline album holds.
        static func existing(_ catalog: BaselineCatalog) -> [String: PHAsset] {
            guard let album = album(titled: catalog.albumTitle) else { return [:] }
            var out: [String: PHAsset] = [:]
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                if let name = originalFilename(asset) { out[name] = asset }
            }
            return out
        }

        /// The library's asset identifier to the catalog's asset id, by file name.
        public static func mapping(_ catalog: BaselineCatalog) -> [String: String] {
            let byName = Dictionary(
                catalog.assets.map { ($0.filename, $0.id) }, uniquingKeysWith: { a, _ in a })
            var out: [String: String] = [:]
            for (name, asset) in existing(catalog) {
                if let id = byName[name] { out[asset.localIdentifier] = id }
            }
            return out
        }

        // MARK: Import

        /// Adds the assets that are not yet in the library. Safe to run again.
        public static func importMissing(
            catalog: BaselineCatalog, rendered: [String: RenderedFile],
            progress: (@Sendable (Int, Int) -> Void)? = nil
        ) async throws -> ImportSummary {
            let start = ContinuousClock.now
            let there = Set(existing(catalog).keys)
            let todo = catalog.assets.filter { !there.contains($0.filename) }
            var done = 0
            for batch in stride(from: 0, to: todo.count, by: 20).map({ Array(todo[$0..<min($0 + 20, todo.count)]) }) {
                try await PHPhotoLibrary.shared().performChanges {
                    var albums: [String: PHAssetCollectionChangeRequest] = [:]
                    func albumRequest(_ title: String) -> PHAssetCollectionChangeRequest {
                        if let r = albums[title] { return r }
                        let r: PHAssetCollectionChangeRequest
                        if let existing = album(titled: title) {
                            r = PHAssetCollectionChangeRequest(for: existing)!
                        } else {
                            r = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                                withTitle: title)
                        }
                        albums[title] = r
                        return r
                    }
                    for asset in batch {
                        guard let file = rendered[asset.id] else { continue }
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = asset.filename
                        options.shouldMoveFile = false
                        request.addResource(
                            with: asset.kind == .video ? .video : .photo, fileURL: file.url,
                            options: options)
                        request.creationDate = asset.captureDate
                        request.isFavorite = asset.favorite
                        if asset.location {
                            request.location = CLLocation(latitude: 43.6532, longitude: -79.3832)
                        }
                        guard let placeholder = request.placeholderForCreatedAsset else { continue }
                        let list = [placeholder] as NSArray
                        albumRequest(catalog.albumTitle).addAssets(list)
                        for title in asset.albums { albumRequest(title).addAssets(list) }
                    }
                }
                done += batch.count
                progress?(done, todo.count)
            }
            let elapsed = ContinuousClock.now - start
            return ImportSummary(
                imported: todo.count, alreadyThere: catalog.assets.count - todo.count,
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }

        // MARK: Removal

        /// Moves the baseline assets to Recently Deleted and removes the baseline albums. The
        /// system asks the person to confirm. Returns how many assets were requested.
        public static func removeAll(_ catalog: BaselineCatalog) async throws -> Int {
            let assets = Array(existing(catalog).values)
            let titles = Set([catalog.albumTitle] + catalog.assets.flatMap(\.albums))
            let collections = titles.compactMap { album(titled: $0) }
            try await PHPhotoLibrary.shared().performChanges {
                if !assets.isEmpty { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
                if !collections.isEmpty {
                    PHAssetCollectionChangeRequest.deleteAssetCollections(collections as NSArray)
                }
            }
            return assets.count
        }
    }
#endif
