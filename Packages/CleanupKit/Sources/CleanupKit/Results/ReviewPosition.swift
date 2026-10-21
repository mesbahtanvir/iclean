import Foundation

/// A screen the person pushed in the review flow. Never a sheet, the full-screen viewer, the
/// confirm dialog or Settings: restoring one of those could leave a removal one tap away.
public enum Route: Codable, Hashable, Sendable {
    case category(CleanupCategory)
    /// A group of a category, found again by any of its photos (a group's own id changes when
    /// one of them leaves).
    case group(CleanupCategory, anchors: [String])

    public static let anchorCount = 3

    public static func group(_ category: CleanupCategory, containing group: ResultGroup) -> Route {
        .group(category, anchors: Array(group.members.prefix(anchorCount)))
    }
}

/// Where the person was, saved so a relaunch can put them back.
public struct ReviewPosition: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// How long after leaving the app it is put back on the screen it was on. Later than that, or
    /// after a failed attempt, Home offers a "Continue reviewing" row instead.
    public static let autoRestoreWindow: TimeInterval = 24 * 3600
    /// Failed restore attempts after which the app stops restoring by itself.
    public static let maxAttempts = 2

    public var path: [Route]
    /// The photo last touched, to scroll to.
    public var focusAssetID: String?
    public var savedAt: Date
    /// Restores begun and not yet proven to have survived. Cleared by a clean flush at inactive or
    /// background, or after a while in the foreground; if the app dies before, it stays counted.
    public var restoreAttempts: Int

    public init(
        path: [Route] = [], focusAssetID: String? = nil, savedAt: Date = .now,
        restoreAttempts: Int = 0
    ) {
        self.path = path
        self.focusAssetID = focusAssetID
        self.savedAt = savedAt
        self.restoreAttempts = restoreAttempts
    }

    public var isHome: Bool { path.isEmpty }

    /// Whether to navigate there by itself.
    public func shouldAutoRestore(now: Date = .now) -> Bool {
        !path.isEmpty && restoreAttempts < Self.maxAttempts
            && now.timeIntervalSince(savedAt) <= Self.autoRestoreWindow
    }
}

public enum RouteValidator {
    /// The longest prefix of `path` that still leads somewhere real in `results`: a category must
    /// have results, a group must still exist (found by any anchor), and the anchors are refreshed
    /// to the group's current first members.
    public static func validate(_ path: [Route], in results: CleanupResults) -> [Route] {
        var valid: [Route] = []
        var open: CleanupCategory?
        for route in path {
            switch route {
            case .category(let c):
                guard valid.isEmpty, results.category(c) != nil else { return valid }
                valid.append(route)
                open = c
            case .group(let c, let anchors):
                guard open == c, let result = results.category(c),
                    let group = result.groups.first(where: { g in
                        anchors.contains(where: g.members.contains)
                    })
                else { return valid }
                valid.append(.group(c, containing: group))
            }
        }
        return valid
    }

    /// The group a route points at, if it still exists.
    public static func group(for route: Route, in results: CleanupResults) -> ResultGroup? {
        guard case .group(let c, let anchors) = route, let result = results.category(c) else {
            return nil
        }
        return result.groups.first { g in anchors.contains(where: g.members.contains) }
    }
}
