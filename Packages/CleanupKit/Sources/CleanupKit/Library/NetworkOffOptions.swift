import Photos

/// The only factories for PhotoKit request options in iclean. Every one keeps
/// network access off, so nothing is ever downloaded from iCloud
/// (Constitution Principle II, spec FR-014).
public enum NetworkOffOptions {
    public static func image(deliveryMode: PHImageRequestOptionsDeliveryMode) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = deliveryMode
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
