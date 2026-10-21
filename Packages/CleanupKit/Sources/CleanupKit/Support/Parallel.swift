import Foundation

/// Plain data parallelism for the results build (spec 009). Everything that uses it computes a pure
/// function of its inputs and merges the answers in an order that does not depend on which thread
/// finished first, so the output equals the serial output.
enum Parallel {
    /// Runs `body(worker)` once for each worker, all at the same time, and returns when every one has
    /// finished. A worker takes its share of the work from a `WorkQueue`, so a slow share does not
    /// hold the others up, and one that never gets a thread of its own just finds the queue empty.
    static func run(workers: Int, _ body: @Sendable (Int) -> Void) {
        if workers <= 1 {
            body(0)
        } else {
            DispatchQueue.concurrentPerform(iterations: workers, execute: body)
        }
    }

    /// Threads to use for `tasks` pieces of work, at most `limit`.
    static func workers(for tasks: Int, limit: Int) -> Int {
        max(1, min(limit, tasks))
    }
}

/// Hands out 0, 1, 2 … to the workers asking, once each.
final class WorkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    let count: Int

    init(count: Int) { self.count = count }

    func take() -> Int? {
        lock.withLock {
            guard next < count else { return nil }
            defer { next += 1 }
            return next
        }
    }
}

/// Collects one value per worker, or per piece of work, from several threads.
final class Collector<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func add(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

/// An array whose slots are written by different threads, each slot by one thread only.
final class Slots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Value) { lock.withLock { values[index] = value } }
    var all: [Value?] { lock.withLock { values } }
}
