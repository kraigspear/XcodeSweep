import os

/// Limits how many blocking folder walks run at once, taking turns between lanes.
///
/// A walk holds its cooperative-pool thread until it finishes. Enough of them at once take every
/// thread, so a category whose `simctl` result is already in can't run to report it. Each category
/// queues in its own lane, and a freed permit goes to the next lane in turn, so a category with one
/// folder doesn't wait behind another's whole backlog.
final class FolderWalkLimiter: Sendable {
    /// One caller's queue; lanes with waiters take turns at freed permits.
    struct Lane: Sendable {
        fileprivate let id: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var available: Int
        var queues: [UInt64: [Waiter]] = [:]
        /// Lanes with waiters, in the order they get the next permits.
        var turns: [UInt64] = []
        var nextID: UInt64 = 0

        mutating func makeID() -> UInt64 {
            defer { nextID += 1 }
            return nextID
        }

        mutating func enqueue(_ waiter: Waiter, in lane: Lane) {
            if queues[lane.id] == nil {
                turns.append(lane.id)
            }
            queues[lane.id, default: []].append(waiter)
        }

        mutating func removeWaiter(_ id: UInt64, in lane: Lane) -> Waiter? {
            guard var queue = queues[lane.id], let index = queue.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let waiter = queue.remove(at: index)
            if queue.isEmpty {
                queues[lane.id] = nil
                turns.removeAll { $0 == lane.id }
            } else {
                queues[lane.id] = queue
            }
            return waiter
        }

        mutating func nextWaiter() -> Waiter? {
            guard !turns.isEmpty, var queue = queues[turns[0]] else { return nil }
            let lane = turns.removeFirst()
            let waiter = queue.removeFirst()
            if queue.isEmpty {
                queues[lane] = nil
            } else {
                queues[lane] = queue
                turns.append(lane)
            }
            return waiter
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(width: Int) {
        precondition(width > 0)
        state = OSAllocatedUnfairLock(initialState: State(available: width))
    }

    func makeLane() -> Lane {
        Lane(id: state.withLock { $0.makeID() })
    }

    /// Runs `body` once a permit is free; waiting doesn't hold a thread.
    ///
    /// - Throws: `CancellationError`, without running `body`, if the task is cancelled before
    ///   `body` starts; or whatever `body` throws.
    nonisolated(nonsending)
    func withPermit<T>(in lane: Lane, _ body: () throws(CancellationError) -> T) async throws(CancellationError) -> T {
        try await acquire(in: lane)
        defer { release() }
        return try body()
    }

    /// Takes a permit, waiting in `lane` while none is free; pair with `release()`.
    ///
    /// - Throws: `CancellationError` if the task is cancelled before this returns; no permit is
    ///   then held.
    nonisolated(nonsending)
    func acquire(in lane: Lane) async throws(CancellationError) {
        let id = state.withLock { $0.makeID() }
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
                        state.enqueue(Waiter(id: id, continuation: continuation), in: lane)
                        return nil
                    }
                    switch granted {
                    case true?: continuation.resume()
                    case false?: continuation.resume(throwing: CancellationError())
                    case nil: break
                    }
                }
            } onCancel: {
                let waiter = state.withLock { $0.removeWaiter(id, in: lane) }
                waiter?.continuation.resume(throwing: CancellationError())
            }
        } catch {
            throw CancellationError()
        }
        // A cancel just after a handoff finds nothing queued to remove, so it is caught here.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Hands the permit to the oldest waiter in the next lane's turn, if any.
    func release() {
        let next = state.withLock { state -> Waiter? in
            if let waiter = state.nextWaiter() {
                return waiter
            }
            state.available += 1
            return nil
        }
        next?.continuation.resume()
    }

    /// Callers waiting for a permit; tests read it to know a caller has queued.
    var waiterCount: Int {
        state.withLock { $0.queues.values.reduce(0) { $0 + $1.count } }
    }
}
