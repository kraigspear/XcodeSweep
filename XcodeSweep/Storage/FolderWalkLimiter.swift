import os

/// Limits how many blocking folder walks run at once.
///
/// A walk holds its cooperative-pool thread until it finishes. Enough of them at once take every
/// thread, so a category whose `simctl` result is already in can't run to report it.
final class FolderWalkLimiter: Sendable {
    private struct State {
        var available: Int
        var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
        var nextID: UInt64 = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(width: Int) {
        precondition(width > 0)
        state = OSAllocatedUnfairLock(initialState: State(available: width))
    }

    /// Runs `body` once fewer than `width` bodies are running; waiting doesn't hold a thread.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting, without running `body`.
    func withPermit<T>(_ body: () throws(CancellationError) -> T) async throws(CancellationError) -> T {
        try await acquire()
        defer { release() }
        return try body()
    }

    private func acquire() async throws(CancellationError) {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let granted: Bool? = state.withLock { state in
                        // Checked under the lock: a cancel that lands later finds this waiter queued.
                        if Task.isCancelled { return false }
                        if state.available > 0 {
                            state.available -= 1
                            return true
                        }
                        state.waiters.append((id, continuation))
                        return nil
                    }
                    switch granted {
                    case true?: continuation.resume()
                    case false?: continuation.resume(throwing: CancellationError())
                    case nil: break
                    }
                }
            } onCancel: {
                let waiter = state.withLock { state in
                    state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
                }
                waiter?.continuation.resume(throwing: CancellationError())
            }
        } catch {
            throw CancellationError()
        }
    }

    /// Hands the permit straight to the oldest waiter, if any.
    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            if state.waiters.isEmpty {
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}
