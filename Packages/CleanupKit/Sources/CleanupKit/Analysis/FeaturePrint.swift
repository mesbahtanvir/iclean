import CoreGraphics
import Foundation
import Vision

/// Apple's on-device image feature prints (research R3, R4).
public enum FeaturePrint {
    public static func compute(_ image: CGImage) async throws -> Data {
        let observation = try await GenerateImageFeaturePrintRequest().perform(on: image)
        return try JSONEncoder().encode(observation)
    }

    public static func decode(_ data: Data) -> FeaturePrintObservation? {
        try? JSONDecoder().decode(FeaturePrintObservation.self, from: data)
    }

    /// Distance between two feature prints; smaller means more alike.
    /// Returns `.infinity` when either cannot be decoded.
    public static func distance(_ a: Data, _ b: Data) -> Double {
        guard let a = decode(a), let b = decode(b) else { return .infinity }
        return distance(a, b)
    }

    public static func distance(_ a: FeaturePrintObservation, _ b: FeaturePrintObservation) -> Double {
        (try? a.distance(to: b)) ?? .infinity
    }
}

/// Decodes feature prints once and caches them for repeated comparisons.
final class FeaturePrintCache {
    private var cache: [String: FeaturePrintObservation] = [:]

    func distance(_ a: LibraryItem, _ b: LibraryItem) -> Double {
        guard let fa = observation(a), let fb = observation(b) else { return .infinity }
        return FeaturePrint.distance(fa, fb)
    }

    private func observation(_ item: LibraryItem) -> FeaturePrintObservation? {
        if let cached = cache[item.assetID] { return cached }
        guard let data = item.analysis?.featurePrint, let fp = FeaturePrint.decode(data) else {
            return nil
        }
        cache[item.assetID] = fp
        return fp
    }
}
