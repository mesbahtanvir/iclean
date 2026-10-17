import os

/// On-device logging only. Asset identifiers are private; no image data or file
/// names are ever logged.
public enum Log {
    public static let scan = Logger(subsystem: "com.mesbahtanvir.iclean", category: "scan")
    public static let results = Logger(subsystem: "com.mesbahtanvir.iclean", category: "results")
    public static let removal = Logger(subsystem: "com.mesbahtanvir.iclean", category: "removal")
}
