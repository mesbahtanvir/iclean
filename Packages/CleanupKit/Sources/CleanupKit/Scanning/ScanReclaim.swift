import Foundation

/// Decides what to do with chunks left `running` by a process that died (003 FR-005,
/// FR-006). Pure, so the rules are unit-tested without a store.
enum ScanReclaim {
    struct Result: Sendable {
        var chunks: [ScanChunk]
        var session: ScanSession
        /// Items given up on because the app died on them twice (003 FR-006).
        var poisoned: [String]
        /// True when at least one chunk was running when the app died.
        var sawCrash: Bool
    }

    static func reclaim(
        _ chunks: [ScanChunk], session: ScanSession, owner: UUID, policy: ScanRetryPolicy
    ) -> Result {
        var session = session
        var poisoned: [String] = []
        var sawCrash = false
        var out: [ScanChunk] = []
        for var chunk in chunks {
            defer { out.append(chunk) }
            guard chunk.state == .running else { continue }
            // A chunk still running belongs to a process that no longer exists: the app
            // died with it in flight. A pause or stop releases chunks first, so this is
            // never counted for those.
            sawCrash = true
            chunk.crashes += 1
            chunk.owner = nil
            let flying = chunk.inFlightIndex
            chunk.inFlightIndex = nil
            if !chunk.isolate {
                chunk.isolate = true
            } else if let flying, !chunk.isDone(flying) {
                // Blame the item that was being analyzed, not the first one left over
                // (an earlier item that only failed must not take the blame).
                if chunk.suspectIndex == flying {
                    // Died twice on the same item: set it aside.
                    chunk.markDone(flying)
                    poisoned.append(chunk.assetIDs[flying])
                    chunk.suspectIndex = nil
                    session.failedItems += 1
                    session.notScannedCount += 1
                    session.processedItems += 1
                } else {
                    chunk.suspectIndex = flying
                }
            }
            chunk.state = chunk.isComplete ? .done : .pending
        }
        if sawCrash {
            // One death is one crash, however many chunks were running when it happened: a scan
            // with several lanes (spec 009) has several, and the budget is for deaths.
            session.crashCount += 1
            session.interruptedCount += 1
            if session.crashCount >= policy.crashBudget {
                // Too many deaths: end the job, keep what was done (003 edge cases).
                session.state = .stopped
                session.finishedAt = .now
            }
        }
        return Result(chunks: out, session: session, poisoned: poisoned, sawCrash: sawCrash)
    }
}
