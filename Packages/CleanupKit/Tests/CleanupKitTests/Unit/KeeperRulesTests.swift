import Foundation
import Testing

@testable import CleanupKit

@Suite struct KeeperRulesTests {
    func item(
        _ id: String, w: Int = 4032, h: Int = 3024, size: Int64 = 1_000, minutes: Double = 0,
        favorite: Bool = false
    ) -> LibraryItem {
        Make.item(
            Make.meta(id, date: Date(timeIntervalSince1970: minutes * 60), width: w, height: h, favorite: favorite),
            size: size)
    }

    @Test func favoriteWins() {
        let keepers = KeeperRules.duplicateKeepers([
            item("big", w: 8000, h: 6000), item("fav", w: 100, h: 75, favorite: true),
        ])
        #expect(keepers == ["fav"])
    }

    @Test func allFavoritesAreKept() {
        let keepers = KeeperRules.duplicateKeepers([
            item("a", favorite: true), item("b", favorite: true), item("c"),
        ])
        #expect(keepers == ["a", "b"])
    }

    @Test func highestResolutionThenQualityThenOldest() {
        #expect(KeeperRules.duplicateKeepers([item("small", w: 2016, h: 1512), item("large")]) == ["large"])
        #expect(KeeperRules.duplicateKeepers([item("low", size: 500), item("high", size: 900)]) == ["high"])
        #expect(
            KeeperRules.duplicateKeepers([item("newer", minutes: 10), item("older", minutes: 1)])
                == ["older"])
    }
}
