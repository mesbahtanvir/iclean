import Foundation

/// Runs work with a time limit (003 FR-007). On timeout the work task is cancelled but
/// never awaited, so a request that ignores cancellation cannot stall the scan.
enum Timeout {
    enum Outcome<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    static func run<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async -> T
    ) async -> Outcome<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let once = FirstWins()
            let handle = TaskHandle()
            let timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, once.claim() else { return }
                handle.cancel()
                continuation.resume(returning: .timedOut)
            }
            handle.set(
                Task {
                    let value = await work()
                    guard once.claim() else { return }
                    timer.cancel()
                    continuation.resume(returning: .finished(value))
                })
        }
    }
}

/// First caller wins (PhotoKitLibrary has its own `Once` for callbacks).
final class FirstWins: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Holds a task so another task can cancel it.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock {
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
