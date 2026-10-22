import Foundation

/// How hard a scan may work (spec 009): how many photos are analyzed at the same time, how many
/// chunks are worked on at the same time, and how many finished chunks may wait to be written.
///
/// The Mac and the iPhone differ in what limits them. On the Mac, measured with the real analyzer,
/// the Neural Engine serves Vision's feature print and face requests at about 330 photos a second
/// however many cores wait for it (a width of 4 reaches that), so what a wider scan buys is the
/// hiding of preview latency, store writes and the end of every chunk behind that rate. A phone has
/// fewer cores, a battery, and a system that ends a background app that works too hard or holds
/// too much memory, so it keeps the narrow settings the 30,000-photo work (spec 008) was
/// validated with: four photos at a time, one chunk, every chunk written before the next.
public struct ScanProfile: Sendable, Equatable {
    public var name: String
    /// Photos analyzed at the same time, over all lanes.
    public var concurrency: Int
    /// Chunks worked on at the same time. A lane leases a chunk, opens its previews, analyzes
    /// them and hands the result to the writer; with several lanes one lane's end-of-chunk wait
    /// and store write overlap the others' analysis.
    public var lanes: Int
    /// Items per chunk (1…64).
    public var chunkSize: Int
    /// Finished chunks that may wait for the store while the next ones are analyzed. Zero writes
    /// every chunk before the next starts. Each waiting chunk holds its results in memory, about
    /// 20 KB a photo.
    public var writeBehind: Int
    /// Whether the width follows the phone's or Mac's heat and Low Power Mode. A scan pauses
    /// outright at a serious thermal state whatever the profile says.
    public var adaptsToConditions: Bool
    /// Threads for reading the store and comparing photos when results are built. The answer is the
    /// same for any number; one is the plain serial code.
    public var buildParallelism: Int

    public init(
        name: String, concurrency: Int, lanes: Int = 1, chunkSize: Int = 32, writeBehind: Int = 0,
        adaptsToConditions: Bool = false, buildParallelism: Int = 1
    ) {
        self.name = name
        self.concurrency = max(1, concurrency)
        self.lanes = max(1, min(lanes, self.concurrency))
        self.chunkSize = min(max(1, chunkSize), ScanChunk.maxSize)
        self.writeBehind = max(0, writeBehind)
        self.adaptsToConditions = adaptsToConditions
        self.buildParallelism = max(1, buildParallelism)
    }

    /// Conservative: what spec 008 validated for 30,000 photos on a phone.
    public static let phone = ScanProfile(name: "phone", concurrency: 4)

    /// Every performance core busy, several chunks at a time, and a few chunks of write-behind so a
    /// long read of the store (a results rebuild) does not stop the analysis.
    public static func mac(cores: Int = ProcessInfo.processInfo.activeProcessorCount)
        -> ScanProfile
    {
        let width = min(max(cores, 6), 16)
        return ScanProfile(
            name: "mac", concurrency: width, lanes: width >= 12 ? 4 : (width >= 8 ? 3 : 2),
            chunkSize: 32,
            writeBehind: 24, adaptsToConditions: true, buildParallelism: min(max(cores, 2), 16))
    }

    /// The profile for the platform this code runs on.
    public static var current: ScanProfile {
        #if os(macOS)
            return .mac()
        #else
            return .phone
        #endif
    }

    /// Photos to keep in flight now. A fair thermal state takes a quarter off and Low Power Mode
    /// half; serious and critical states never reach here, the scan pauses instead.
    public func width(thermal: ProcessInfo.ThermalState, lowPower: Bool) -> Int {
        guard adaptsToConditions else { return concurrency }
        var width = Double(concurrency)
        if thermal == .fair { width *= 0.75 }
        if lowPower { width *= 0.5 }
        return max(min(2, concurrency), Int(width.rounded()))
    }

    /// Photos per lane for a total width.
    public func laneWidth(total: Int) -> Int {
        max(1, (total + lanes - 1) / lanes)
    }
}
