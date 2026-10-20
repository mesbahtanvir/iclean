#if DEBUG
    import Photos

    /// DEBUG-only guard for tools that write into the real Photos library.
    ///
    /// On an iPhone or in a simulator the library is a test one. On a Mac the app sees the
    /// user's own System Photo Library, so a debug tool that changes it must be asked for with
    /// `-AllowRealLibrary` (005 plan D4, D6). Use a spare macOS user or a virtual machine.
    enum DebugSafety {
        static var allowsLibraryWrites: Bool {
            #if os(macOS)
                ProcessInfo.processInfo.arguments.contains("-AllowRealLibrary")
            #else
                true
            #endif
        }

        /// Says why a debug tool did nothing, so the refusal is not silent.
        static func refuse(_ tool: String) {
            print(
                "[debug] \(tool) refused: it changes the Photos library."
                    + " Pass -AllowRealLibrary to allow it.")
            fflush(stdout)
        }
    }

    /// DEBUG-only: `-SeedFavorites a.jpg,b.jpg` marks the assets with those original
    /// file names as favorites. Used by scripts/seed-simulator.sh. Refuses to run on a Mac
    /// unless `-AllowRealLibrary` is given.
    enum DebugSeeding {
        static func runIfRequested() async {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-SeedFavorites"), i + 1 < args.count else { return }
            guard DebugSafety.allowsLibraryWrites else {
                return DebugSafety.refuse("-SeedFavorites")
            }
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
