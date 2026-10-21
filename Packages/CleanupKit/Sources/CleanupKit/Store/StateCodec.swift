import CryptoKit
import Foundation

/// The kinds of saved state. Each is one row (specs/007-persistent-session).
public enum StateKey: String, Sendable, CaseIterable {
    /// The slim results the screens show. A disposable cache.
    case results
    /// The person's selections and keeper choices.
    case decisions
    /// Which screen they were on.
    case position
}

/// A saved state row, checksum already verified.
public struct StateEnvelope: Sendable, Equatable {
    public var key: StateKey
    public var version: Int
    /// The sealed payload (see `StateCodec`).
    public var payload: Data
    public var basedOnRevision: Int64
    public var updatedAt: Date
}

/// Size and age of a saved state row, for the "Saved on this iPhone" screen.
public struct StateInfo: Sendable, Equatable {
    public var bytes: Int
    public var updatedAt: Date
    public var basedOnRevision: Int64
}

/// Seals a value into compact bytes and opens it again. The bytes are LZFSE-compressed JSON; the
/// store adds a SHA-256 checksum next to them, so damage is found before a payload is decoded.
public enum StateCodec {
    public enum Failure: Error, Equatable {
        case damaged
    }

    public static func seal<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        return try (json as NSData).compressed(using: .lzfse) as Data
    }

    public static func open<T: Decodable>(_ bytes: Data, as type: T.Type = T.self) throws -> T {
        guard let json = try? (bytes as NSData).decompressed(using: .lzfse) as Data else {
            throw Failure.damaged
        }
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch {
            throw Failure.damaged
        }
    }

    public static func checksum(_ bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }
}
