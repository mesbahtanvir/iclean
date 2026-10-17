#if DEBUG
    import Photos

    /// DEBUG-only: `-SeedFavorites a.jpg,b.jpg` marks the assets with those original
    /// file names as favorites. Used by scripts/seed-simulator.sh.
    enum DebugSeeding {
        static func runIfRequested() async {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-SeedFavorites"), i + 1 < args.count else { return }
            let names = Set(args[i + 1].split(separator: ",").map(String.init))
            guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else { return }
            var targets: [PHAsset] = []
            PHAsset.fetchAssets(with: nil).enumerateObjects { asset, _, _ in
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
                if names.contains(name) { targets.append(asset) }
            }
            try? await PHPhotoLibrary.shared().performChanges {
                for asset in targets { PHAssetChangeRequest(for: asset).isFavorite = true }
            }
        }
    }
#endif
