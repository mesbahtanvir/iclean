#if os(iOS)
    import Photos

    /// Detects Live Photos with the Long Exposure effect (FR-003a).
    ///
    /// PhotoKit has no documented flag for this effect. The rule used here must be
    /// verified on a physical device (tasks.md T051, research.md R5 open item).
    /// Until then, a Live Photo whose playback style is not `.livePhoto` while it
    /// still carries the `.photoLive` subtype (Loop, Bounce, Long Exposure effects
    /// change the playback style) is treated as a possible long exposure.
    enum LongExposure {
        static func isLongExposure(_ asset: PHAsset) -> Bool {
            guard asset.mediaSubtypes.contains(.photoLive) else { return false }
            return asset.playbackStyle == .image
        }
    }
#endif
