import Testing

@testable import CleanupKit

/// Spec 017 FR-013: each tier has one state, derived from a scan's progress and nothing else, so every
/// screen describes the tiers the same way. `TieredScanTests` checks the cases the spec names; this
/// checks the rules the screens rely on over every progress an engine could report: five states, four
/// tiers, four counts, two owed counts and two reasons to wait.
@Suite struct TierStatusTableTests {
    static let states: [ScanState] = [.idle, .running, .paused, .stopped, .completed]
    static let tiers: [ScanTier?] = [nil, .instant, .photos, .deep]
    static let counts: [(done: Int, total: Int)] = [(0, 0), (0, 10), (4, 10), (10, 10)]
    static let owedCounts = [0, 7]
    static let waits: [DeepWait?] = [nil, .lowPowerMode]

    static var everyProgress: [ScanProgress] {
        var all: [ScanProgress] = []
        for state in states {
            for tier in tiers {
                for count in counts {
                    for owed in owedCounts {
                        for wait in waits {
                            all.append(
                                ScanProgress(
                                    processed: count.done, total: count.total, notScanned: 0,
                                    state: state, tier: tier, deepRemaining: owed, deepWait: wait))
                        }
                    }
                }
            }
        }
        return all
    }

    /// Both the progress and what it was derived to, for a failure message.
    static func described(_ p: ScanProgress) -> String {
        "\(p.state) \(String(describing: p.tier)) \(p.processed)/\(p.total) owed \(p.deepRemaining) "
            + "wait \(String(describing: p.deepWait))"
    }

    @Test func theTableIsAsBigAsItSays() {
        #expect(Self.everyProgress.count == 5 * 4 * 4 * 2 * 2)
    }

    /// Only a tiered scan that has started and whose job is not the quick wins has tiers to show.
    @Test func aStatusExistsOnlyForAStartedPhotoOrDeepJob() {
        for p in Self.everyProgress {
            let expected = p.state != .idle && (p.tier == .photos || p.tier == .deep)
            #expect((ScanTierStatus(p) != nil) == expected, "\(Self.described(p))")
        }
    }

    /// The quick wins are stored before the first event, so by any event they are ready.
    @Test func quickWinsAreReadyInEveryStatus() {
        for p in Self.everyProgress {
            guard let status = ScanTierStatus(p) else { continue }
            #expect(status.instant == .ready, "\(Self.described(p))")
        }
    }

    /// The deep check starts after the photo check ends, never beside it.
    @Test func theDeepCheckRunsOnlyAfterThePhotoCheckIsReady() {
        for p in Self.everyProgress {
            guard let status = ScanTierStatus(p) else { continue }
            if case .running = status.deep {
                #expect(status.photos == .ready, "\(Self.described(p))")
            }
            if case .running = status.photos {
                #expect(status.deep != .ready, "\(Self.described(p))")
            }
        }
    }

    /// The job that is running is the one that shows a count, and the count is the job's.
    @Test func theRunningTierShowsTheJobsOwnCount() {
        for p in Self.everyProgress where p.state == .running || p.state == .paused {
            guard let status = ScanTierStatus(p) else { continue }
            let count = TierState.running(done: p.processed, total: p.total)
            #expect(status[p.tier!] == count, "\(Self.described(p))")
        }
    }

    /// A scan that completed owes exactly what it says: nothing waits behind a finished deep check, and
    /// work owed after the photo check is either waiting for a reason or offered, never lost.
    @Test func aCompletedScanLeavesNothingHiddenAndNothingOwedUnsaid() {
        for p in Self.everyProgress where p.state == .completed {
            guard let status = ScanTierStatus(p) else { continue }
            #expect(status.photos == .ready, "\(Self.described(p))")
            switch p.tier {
            case .deep:
                #expect(status.deep == .ready, "\(Self.described(p))")
            case .photos:
                if p.deepRemaining == 0 {
                    #expect(status.deep == .ready, "\(Self.described(p))")
                } else if let wait = p.deepWait {
                    #expect(status.deep == .waitingFor(wait), "\(Self.described(p))")
                } else {
                    #expect(status.deep == .notRun(owed: p.deepRemaining), "\(Self.described(p))")
                }
            default:
                break
            }
        }
    }

    /// A scan that was stopped says what it did not do, in the unit of its own job.
    @Test func aStoppedScanSaysWhatItLeftUndone() {
        for p in Self.everyProgress where p.state == .stopped {
            guard let status = ScanTierStatus(p) else { continue }
            switch p.tier {
            case .photos:
                #expect(
                    status.photos == .notRun(owed: max(0, p.total - p.processed)),
                    "\(Self.described(p))")
            case .deep:
                #expect(status.deep == .notRun(owed: p.deepRemaining), "\(Self.described(p))")
            default:
                break
            }
        }
    }

    /// "Waiting for Low Power Mode" is about the deep check; no other tier ever waits for a reason.
    @Test func onlyTheDeepCheckWaitsForAReason() {
        for p in Self.everyProgress {
            guard let status = ScanTierStatus(p) else { continue }
            for tier in [ScanTier.instant, .photos] {
                if case .waitingFor = status[tier] {
                    Issue.record("\(tier) waits for a reason: \(Self.described(p))")
                }
            }
        }
    }

    /// No state carries a negative count, and a finished state is exactly the ready one.
    @Test func countsAreNeverNegativeAndFinishedMeansReady() {
        for p in Self.everyProgress {
            guard let status = ScanTierStatus(p) else { continue }
            for tier in ScanTier.allCases {
                let state = status[tier]
                #expect(state.isFinished == (state == .ready), "\(Self.described(p))")
                if case .notRun(let owed) = state { #expect(owed >= 0, "\(Self.described(p))") }
                if case .running(let done, let total) = state {
                    #expect(done >= 0 && total >= 0, "\(Self.described(p))")
                }
            }
        }
    }

    /// The subscript and the three properties agree.
    @Test func theSubscriptReadsTheSameThreeStates() {
        for p in Self.everyProgress {
            guard let status = ScanTierStatus(p) else { continue }
            #expect(status[.instant] == status.instant)
            #expect(status[.photos] == status.photos)
            #expect(status[.deep] == status.deep)
        }
    }
}
