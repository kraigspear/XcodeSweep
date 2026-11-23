import Foundation
import os
import Testing
@testable import XcodeSweep

@Suite("Folder walk limiter")
struct FolderWalkLimiterTests {
    /// Blocking walks beyond the width would occupy the threads that other categories' results need.
    @Test("Concurrent inspections never exceed the limiter's width", .timeLimit(.minutes(1)))
    func inspectionsStayWithinWidth() async {
        let counts = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0))
        let limiter = FolderWalkLimiter(width: 2)

        let items = await XcodeStorage.scanConcurrently(Array(0 ..< 24), limiter: limiter) { index in
            counts.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
            usleep(5_000) // Blocks like a folder walk.
            counts.withLock { $0.running -= 1 }
            return makeStorageItem(id: "item-\(index)")
        }

        #expect(items.count == 24)
        #expect(counts.withLock { $0.peak } == 2)
    }

    @Test("A cancelled waiter throws, runs nothing, and leaves the permit for the next caller", .timeLimit(.minutes(1)))
    func cancelledWaiterThrows() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let held = try await holdPermit(of: limiter)

        let waiterRan = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            try await limiter.withPermit { waiterRan.withLock { $0 = true } }
        }
        // Long enough for the waiter to queue behind the holder.
        try await Task.sleep(for: .milliseconds(50))

        let waited = try await cancelAndAwaitResult(of: waiter, within: .seconds(5))
        #expect(throws: CancellationError.self) { try waited.get() }
        try await held.release()
        _ = try await awaitResult(of: Task { try await limiter.withPermit {} }, within: .seconds(5)).get()
        #expect(!waiterRan.withLock { $0 })
    }

    /// Cancellation that lands before the waiter queues runs its handler with nothing to remove.
    @Test("A caller cancelled before it waits throws instead of queueing", .timeLimit(.minutes(1)))
    func callerCancelledBeforeWaitingThrows() async throws {
        let limiter = FolderWalkLimiter(width: 1)
        let held = try await holdPermit(of: limiter)

        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await limiter.withPermit {}
        }

        let waited = try await awaitResult(of: waiter, within: .seconds(5))
        #expect(throws: CancellationError.self) { try waited.get() }
        try await held.release()
    }

    /// Takes `limiter`'s only permit until `release()`, blocking a thread like a folder walk.
    private func holdPermit(of limiter: FolderWalkLimiter) async throws -> HeldPermit {
        let flags = OSAllocatedUnfairLock(initialState: (started: false, released: false))
        let holding = Task {
            try await limiter.withPermit {
                flags.withLock { $0.started = true }
                while !flags.withLock({ $0.released }) {
                    usleep(1_000)
                }
            }
        }
        while !flags.withLock({ $0.started }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        return HeldPermit(flags: flags, holding: holding)
    }
}

private struct HeldPermit {
    let flags: OSAllocatedUnfairLock<(started: Bool, released: Bool)>
    let holding: Task<Void, any Error>

    func release() async throws {
        flags.withLock { $0.released = true }
        _ = try await awaitResult(of: holding, within: .seconds(5)).get()
    }
}
