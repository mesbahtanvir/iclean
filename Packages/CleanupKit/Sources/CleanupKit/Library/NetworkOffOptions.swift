import Photos

/// The only factories for PhotoKit request options in iclean. Every one keeps
/// network access off, so nothing is ever downloaded from iCloud
/// (Constitution Principle II, spec FR-014).
public enum NetworkOffOptions {
    public static func image(deliveryMode: PHImageRequestOptionsDeliveryMode)
        -> PHImageRequestOptions
    {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isSynchronous = false
        options.version = .current
        return options
    }

    /// For pictures on the screen: the quick low-resolution picture first (opportunistic), so a cell
    /// is not empty while the better one is made. One shared instance is used for requests and for
    /// prefetching, because PhotoKit only reuses a prefetched image for identical options.
    public static func thumbnail() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        options.version = .current
        return options
    }

    public static func resource() -> PHAssetResourceRequestOptions {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return options
    }

    public static func video() -> PHVideoRequestOptions {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        options.version = .current
        return options
    }
}
