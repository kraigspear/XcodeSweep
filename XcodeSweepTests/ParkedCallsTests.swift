import Foundation
import Testing

@Suite("ParkedCalls test adapter")
struct ParkedCallsTests {
    /// Verifies the shared parked-call fake cannot hang a test whose waiter is cancelled.
    /// To replicate: not app behavior; guards the test fake behind both the command and trash seams.
    @Test("Cancelling a registered parked-call waiter exits immediately", .timeLimit(.minutes(1)))
    func cancelledParkedCallWaiterExitsImmediately() async throws {
        let calls = ParkedCalls<Int, Void>()
        let waiterTask = Task {
            try await calls.nextPendingCall()
        }
        defer { waiterTask.cancel() }

        try await waitUntil("waiter registered") {
            await calls.hasRegisteredWaiter
        }
        waiterTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiterTask.value
        }
    }
}
