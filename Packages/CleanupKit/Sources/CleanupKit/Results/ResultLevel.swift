import Foundation

/// How far a category looks (spec 011). Levels nest: what `tight` lists, `medium` lists too, and so does `wide`.
/// The words the person sees depend on the category: Similar Shots says Almost identical, Same shot and Same
/// scene; Unimportant says Most likely, Probably and Maybe.
public enum ResultLevel: Int, Codable, Sendable, Comparable, CaseIterable, Hashable {
    case tight = 1
    case medium = 2
    case wide = 3

    public static func < (a: ResultLevel, b: ResultLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What one level of a category would list: groups, photos in them, and photos that could be removed
/// (a group keeps at least one). Counted among the candidates the detector saw, before the builder
/// drops anything an earlier category already took.
public struct LevelSummary: Codable, Hashable, Sendable {
    public var level: ResultLevel
    public var groups: Int
    public var photos: Int
    public var removable: Int

    public init(level: ResultLevel, groups: Int, photos: Int, removable: Int) {
        self.level = level
        self.groups = groups
        self.photos = photos
        self.removable = removable
    }
}

/// The level chosen for each category with levels. One object is shared by the screens, which change it, and
/// the detectors, which read it when results are built.
public final class ResultLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var chosen: [CleanupCategory: ResultLevel]

    public init(_ chosen: [CleanupCategory: ResultLevel] = [:]) { self.chosen = chosen }

    public subscript(category: CleanupCategory) -> ResultLevel {
        get { lock.withLock { chosen[category] } ?? category.defaultLevel }
        set { lock.withLock { chosen[category] = newValue } }
    }

    /// The choices in a stable form, for the key a saved snapshot is matched against.
    public var key: String {
        CleanupCategory.allCases.filter(\.hasLevels).map { "\($0.rawValue)=\(self[$0].rawValue)" }
            .joined(separator: ",")
    }
}

extension CleanupCategory {
    /// Similar Shots and Unimportant list more or fewer photos as the person chooses.
    public var hasLevels: Bool { self == .similar || self == .unimportant }

    /// The level shown until the person picks one. For Similar Shots it is today's rule.
    public var defaultLevel: ResultLevel { .medium }

    /// Whether the photos a category lists at `level` start selected. Looking further than the default
    /// ("Same scene") only shows more; the person chooses what to take.
    public func preselects(at level: ResultLevel?) -> Bool {
        guard preselects else { return false }
        if self == .similar, level == .wide { return false }
        return true
    }
}
