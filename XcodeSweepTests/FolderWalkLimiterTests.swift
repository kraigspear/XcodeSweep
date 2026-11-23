import Foundation
import os
import Testing
@testable import XcodeSweep

/// Tests hold permits with `acquire()` and `release()` rather than blocking bodies, so they
/// progress however few pool threads are free.
@Suite("Folder walk limiter")
@MainActor
struct FolderWalkLimiterTests {
    @Test("Every input is inspected, never more at once than the width", .timeLimit(.minutes(1)))
    func scanConcurrentlyInspectsEveryInputWithinWidth() async {
        let counts = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0))

        let items = await XcodeStorage.scanConcurrently(Array(0 ..< 24), limiter: FolderWalkLimiter(width: 2)) { index in
            counts.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
            usleep(1_000) // Blocks like a folder walk.
            counts.withLock { $0.running -= 1 }
            return makeStorageItem(id: "item-\(index)")
        }

        #expect(items.count == 24)
        #expect(counts.withLock { $0.peak } <= 2)
    }

    @Test("Callers beyond the width wait, and a release admits one", .timeLimit(.minutes(1)))
    func releaseAdmitsWaiter() async throws {
        let limiter = FolderWalkLimiter(width: 2)
        let lane = limiter.makeLane()
        try await limiter.acquire(in: lane)
        try await limiter.acquire(in: lane)

        let third = Task { try await limiter.acquire(in: lane) }
        try await waitUntil("third caller queued") { limiter.waiterCount == 1 }
        limiter.release()

        _ = try await awaitResult(of: third, within: .seconds(5)).get()
        #expect(limiter.waiterCount == 0)
    }

    /// A category with one folder must not wait behind another category's whole backlog.
    @Test("Freed permits go to lanes in turn", .timeLimit(.minutes(1)))
    func lanesTakeTurns() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let backlog = limiter.makeLane()
        let single = limiter.makeLane()
        try await limiter.acquire(in: limiter.makeLane())

        let order = OSAllocatedUnfairLock<[String]>(initialState: [])
        var waiters: [Task<Void, any Error>] = []
        for (name, lane) in [("a1", backlog), ("a2", backlog), ("a3", backlog), ("b1", single)] {
            waiters.append(Task {
                try await limiter.acquire(in: lane)
                order.withLock { $0.append(name) }
                limiter.release()
            })
            let queued = waiters.count
            try await waitUntil("\(name) queued") { limiter.waiterCount == queued }
        }
        limiter.release()

        for waiter in waiters {
            _ = try await awaitResult(of: waiter, within: .seconds(5)).get()
        }
        #expect(order.withLock { $0 } == ["a1", "b1", "a2", "a3"])
    }

    @Test("A cancelled waiter throws and leaves the permit for the next caller", .timeLimit(.minutes(1)))
    func cancelledWaiterThrows() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let lane = limiter.makeLane()
        try await limiter.acquire(in: lane)

        let waiter = Task { try await limiter.acquire(in: lane) }
        try await waitUntil("waiter queued") { limiter.waiterCount == 1 }
        let waited = try await cancelAndAwaitResult(of: waiter, within: .seconds(5))

        #expect(throws: CancellationError.self) { try waited.get() }
        #expect(limiter.waiterCount == 0)
        limiter.release()
        _ = try await awaitResult(of: Task { try await limiter.acquire(in: lane) }, within: .seconds(5)).get()
    }

    /// Cancellation that lands before the caller queues runs its handler with nothing to remove.
    @Test("A caller cancelled before it waits throws instead of queueing", .timeLimit(.minutes(1)))
    func callerCancelledBeforeWaitingThrows() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let lane = limiter.makeLane()
        try await limiter.acquire(in: lane)

        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await limiter.acquire(in: lane)
        }

        let waited = try await awaitResult(of: waiter, within: .seconds(5))
        #expect(throws: CancellationError.self) { try waited.get() }
        #expect(limiter.waiterCount == 0)
    }

    /// The waiter runs on the main actor, so it can't resume between the handoff and the cancel.
    @Test("A cancel just after the permit is handed over still stops the body", .timeLimit(.minutes(1)))
    func cancelAfterHandoffStopsBody() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let lane = limiter.makeLane()
        try await limiter.acquire(in: lane)

        let bodyRan = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task { @MainActor in
            try await limiter.withPermit(in: lane) { bodyRan.withLock { $0 = true } }
        }
        try await waitUntil("waiter queued") { limiter.waiterCount == 1 }
        limiter.release()
        waiter.cancel()

        let waited = try await awaitResult(of: waiter, within: .seconds(5))
        #expect(throws: CancellationError.self) { try waited.get() }
        #expect(!bodyRan.withLock { $0 })
        _ = try await awaitResult(of: Task { try await limiter.acquire(in: lane) }, within: .seconds(5)).get()
    }

    @Test("A body that throws still releases its permit", .timeLimit(.minutes(1)))
    func throwingBodyReleasesPermit() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let lane = limiter.makeLane()

        await #expect(throws: CancellationError.self) {
            try await limiter.withPermit(in: lane) { () throws(CancellationError) in throw CancellationError() }
        }

        _ = try await awaitResult(of: Task { try await limiter.acquire(in: lane) }, within: .seconds(5)).get()
    }
}
