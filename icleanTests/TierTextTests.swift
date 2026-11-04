import CleanupKit
import Foundation
import Testing

@testable import iclean

/// The words of a tiered scan (spec 017 FR-013, FR-015): every tier and every state has some, the
/// identifiers the UI tests look for are the ones the screens set, and no word invents a time or
/// claims the library is clean while work is owed.
@Suite struct TierTextTests {
    private static var isEnglish: Bool { Locale.current.language.languageCode == .english }

    /// One of each state a tier row can be in.
    private static let states: [TierState] = [
        .waiting, .running(done: 3, total: 10), .running(done: 0, total: 0), .ready,
        .waitingFor(.lowPowerMode), .notRun(owed: 5), .notRun(owed: 0),
    ]

    // MARK: Tiers

    @Test func everyTierHasItsWords() {
        for tier in ScanTier.allCases {
            #expect(!tier.title.isEmpty, "\(tier)")
            #expect(!tier.finds.isEmpty, "\(tier)")
            #expect(!tier.heading.isEmpty, "\(tier)")
        }
    }

    @Test func theTiersAreToldApart() {
        let titles = ScanTier.allCases.map(\.title)
        let headings = ScanTier.allCases.map(\.heading)
        let finds = ScanTier.allCases.map(\.finds)
        #expect(Set(titles).count == titles.count, "\(titles)")
        #expect(Set(headings).count == headings.count, "\(headings)")
        #expect(Set(finds).count == finds.count, "\(finds)")
    }

    /// The UI tests, the accessibility identifiers and the prototype all say these three words.
    @Test func theIdentifiersAreTheOnesTheScreensSet() {
        #expect(ScanTier.allCases.map(\.identifier) == ["instant", "photos", "deep"])
    }

    /// Quick wins are never "coming later": they are ready before anything is shown. The other two
    /// say what will appear, so the group is not an empty box.
    @Test func onlyTheLaterTiersSayWhatIsComing() {
        #expect(ScanTier.instant.comingLater.isEmpty)
        #expect(!ScanTier.photos.comingLater.isEmpty)
        #expect(!ScanTier.deep.comingLater.isEmpty)
    }

    /// The tiers go in the order of the work: the cheapest first.
    @Test func theTiersRunCheapestFirst() {
        #expect(ScanTier.allCases == [.instant, .photos, .deep])
        #expect(ScanTier.instant < .photos)
        #expect(ScanTier.photos < .deep)
    }

    // MARK: States

    @Test func everyStateHasWords() {
        for state in Self.states {
            #expect(!state.words.isEmpty, "\(state)")
            for tier in ScanTier.allCases {
                #expect(state.spoken(for: tier).contains(tier.title), "\(state) \(tier)")
            }
        }
    }

    /// The row is a count of real work, never a guess of how long it takes (spec 017: no estimate
    /// until one is measured) and never a percentage the scan cannot back.
    @Test func noWordInventsATime() {
        let banned = [
            "minute", "min.", "second", "sec.", "hour", "left", "remaining", "estimate", "~", "%",
        ]
        for state in Self.states {
            for text in [state.words] + ScanTier.allCases.map({ state.spoken(for: $0) }) {
                let lower = text.lowercased()
                for word in banned {
                    #expect(!lower.contains(word), "“\(text)” says “\(word)”")
                }
            }
        }
    }

    @Test func onlyReadyAndRunningAreActive() {
        #expect(TierState.ready.isActive)
        #expect(TierState.running(done: 1, total: 2).isActive)
        #expect(!TierState.waiting.isActive)
        #expect(!TierState.waitingFor(.lowPowerMode).isActive)
        #expect(!TierState.notRun(owed: 7).isActive)
    }

    @Test(.enabled(if: Self.isEnglish)) func theWordsOfEachStateInEnglish() {
        #expect(TierState.waiting.words == "Waiting")
        #expect(TierState.ready.words == "Ready")
        #expect(TierState.notRun(owed: 5).words == "Not run")
        #expect(TierState.waitingFor(.lowPowerMode).words == "Waiting for Low Power Mode")
        #expect(TierState.running(done: 3, total: 10).words == "3 of 10")
    }

    @Test(.enabled(if: Self.isEnglish)) func aRunningRowIsReadAloudWithItsUnit() {
        let spoken = TierState.running(done: 3, total: 10).spoken(for: .photos)
        #expect(spoken == "Photo check, 3 of 10 checked")
        #expect(TierState.ready.spoken(for: .instant) == "Quick wins, Ready")
    }

    /// Big counts are grouped the way the rest of the app groups them ("12,400"), not run together.
    @Test(.enabled(if: Self.isEnglish)) func countsAreGrouped() {
        let words = TierState.running(done: 1_200, total: 12_400).words
        #expect(words.contains(1_200.formatted()), words)
        #expect(words.contains(12_400.formatted()), words)
    }

    // MARK: The offer to look deeper

    @Test func theExplanationNamesTheNumberOwed() {
        for owed in [1, 2, 12, 1_000, 12_400] {
            let text = DeepOfferText.explanation(owed: owed, wait: nil)
            #expect(text.contains(owed.formatted()), "\(owed): \(text)")
        }
    }

    /// Spec 017 FR-015: while work is owed the screen never says the library is clean.
    @Test(.enabled(if: Self.isEnglish)) func theExplanationNeverSaysTheLibraryIsClean() {
        for wait in [nil, DeepWait.lowPowerMode] {
            let text = DeepOfferText.explanation(owed: 40, wait: wait).lowercased()
            #expect(text.contains("may be missing"), text)
            #expect(!text.contains("all clean"), text)
            #expect(!text.contains("nothing to clean"), text)
        }
    }

    @Test(.enabled(if: Self.isEnglish)) func theExplanationAgreesWithTheCount() {
        let one = DeepOfferText.explanation(owed: 1, wait: nil)
        let twelve = DeepOfferText.explanation(owed: 12, wait: nil)
        #expect(one.hasPrefix("1 photo not compared yet."), one)
        #expect(twelve.hasPrefix("12 photos not compared yet."), twelve)
    }

    /// In Low Power Mode the sentence starts with why nothing began by itself.
    @Test func lowPowerModeIsSaidFirst() {
        let wait = DeepWait.lowPowerMode
        let text = DeepOfferText.explanation(owed: 5, wait: wait)
        #expect(text.hasPrefix(wait.because), text)
        #expect(!wait.words.isEmpty)
        #expect(text.count > DeepOfferText.explanation(owed: 5, wait: nil).count)
    }
}
