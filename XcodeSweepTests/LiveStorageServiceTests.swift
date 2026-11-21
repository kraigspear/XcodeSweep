import Foundation
import Testing
@testable import XcodeSweep

@Suite("LiveStorageService Deletion")
struct LiveStorageServiceTests {
    @Test(
        "Emits ordered start and completion progress across a suspended deletion and handles failures",
        .timeLimit(.minutes(1))
    )
    func deleteEmitsOrderedProgressAcrossSuspensionAndFailure() async throws {
        let controller = ControllableCommandRunner()
        let service = LiveStorageService(commandRunner: controller)

        let bootedDevice = StorageItem(
            id: "sim-1",
            category: .simulatorDevices,
            name: "iPhone 17 Pro",
            subtitle: "iOS 27.2",
            sizeBytes: 4_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .booted,
            deletionMethod: .simctlDevice(udid: "UDID-1", isBooted: true),
            metadata: []
        )
        let failingRuntime = StorageItem(
            id: "rt-2",
            category: .simulatorRuntimes,
            name: "iOS 26.4",
            subtitle: "Build 23E100",
            sizeBytes: 8_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .stale,
            deletionMethod: .simctlRuntime(identifier: "RT-2"),
            metadata: []
        )
        let protectedRuntime = StorageItem(
            id: "rt-3",
            category: .simulatorRuntimes,
            name: "watchOS 12.0",
            subtitle: "Bundled",
            sizeBytes: 3_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .systemManaged,
            deletionMethod: .notDeletable(reason: "Managed by Xcode"),
            metadata: []
        )

        let recordedEvents = ProgressRecorder()

        async let pendingReport = service.delete(items: [bootedDevice, failingRuntime, protectedRuntime]) { progress in
            await recordedEvents.append(progress)
        }

        // Wait for the booted device shutdown command to enter flight.
        let firstCall = try await controller.nextPendingCall()
        #expect(firstCall.arguments == ["simctl", "shutdown", "UDID-1"])

        // Start event for item 1 must already have arrived before the command resolves, with no removal yet.
        let eventsWhileSuspended = await recordedEvents.snapshot()
        #expect(eventsWhileSuspended.count == 1)
        #expect(eventsWhileSuspended.first == DeletionProgress(
            completedCount: 0,
            totalCount: 3,
            currentItemName: "iPhone 17 Pro",
            removedBytes: 0,
            removedItemID: nil
        ))

        await controller.resumeCall(
            id: firstCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        // Next call is the simctl delete for UDID-1.
        let secondCall = try await controller.nextPendingCall()
        #expect(secondCall.arguments == ["simctl", "delete", "UDID-1"])
        await controller.resumeCall(
            id: secondCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        // Next call is the failing runtime delete; by now item 1's completion event and item 2's start event arrived.
        let thirdCall = try await controller.nextPendingCall()
        #expect(thirdCall.arguments == ["simctl", "runtime", "delete", "RT-2"])

        let eventsBeforeFailureResolves = await recordedEvents.snapshot()
        #expect(eventsBeforeFailureResolves.count == 3)
        #expect(eventsBeforeFailureResolves[1] == DeletionProgress(
            completedCount: 1,
            totalCount: 3,
            currentItemName: "iPhone 17 Pro",
            removedBytes: 4_000_000_000,
            removedItemID: "sim-1"
        ))
        #expect(eventsBeforeFailureResolves[2] == DeletionProgress(
            completedCount: 1,
            totalCount: 3,
            currentItemName: "iOS 26.4",
            removedBytes: 4_000_000_000,
            removedItemID: nil
        ))

        await controller.resumeCall(
            id: thirdCall.id,
            with: .failure(ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "runtime busy"))
        )

        let report = await pendingReport
        let allEvents = await recordedEvents.snapshot()

        // 3 items -> 6 ordered events (start + finish for each item).
        #expect(allEvents.count == 6)
        // Failed runtime must not emit a removedItemID or add bytes.
        #expect(allEvents[3] == DeletionProgress(
            completedCount: 2,
            totalCount: 3,
            currentItemName: "iOS 26.4",
            removedBytes: 4_000_000_000,
            removedItemID: nil
        ))
        // Protected item must not emit a removedItemID or add bytes.
        #expect(allEvents[5] == DeletionProgress(
            completedCount: 3,
            totalCount: 3,
            currentItemName: "watchOS 12.0",
            removedBytes: 4_000_000_000,
            removedItemID: nil
        ))

        #expect(report.deletedCount == 1)
        #expect(report.trashedCount == 0)
        #expect(report.simctlDeletedCount == 1)
        #expect(report.reclaimedBytes == 4_000_000_000)
        #expect(report.removedItemIDs == ["sim-1"])
        #expect(report.failures.map(\.itemID) == ["rt-2", "rt-3"])
    }

    @Test(
        "Cancelling an already-registered command waiter exits immediately instead of hanging",
        .timeLimit(.minutes(1))
    )
    func cancelledRegisteredWaiterExitsImmediately() async throws {
        let controller = ControllableCommandRunner()
        let waiterTask = Task {
            try await controller.nextPendingCall()
        }
        defer { waiterTask.cancel() }

        // Wait (with cancellation + deadline) until the waiter is registered and parked before cancelling.
        try await waitUntil("command waiter registered") {
            await controller.hasRegisteredWaiter
        }
        waiterTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiterTask.value
        }
    }

    @Test(
        "Cancelling while awaiting a structured worker parked on an unexpected extra command exits immediately",
        .timeLimit(.minutes(1))
    )
    func cancelledStructuredWorkerOnExtraCommandExitsImmediately() async throws {
        let controller = ControllableCommandRunner()
        let service = LiveStorageService(commandRunner: controller)

        let device = StorageItem(
            id: "sim-extra",
            category: .simulatorDevices,
            name: "iPhone 17",
            subtitle: "iOS 27.2",
            sizeBytes: 1_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .unavailable,
            deletionMethod: .simctlDevice(udid: "UDID-EXTRA", isBooted: false),
            metadata: []
        )

        // Outer task simulates a test awaiting `pendingReport` when an unexpected command parks the worker.
        let outerTask = Task { () -> DeletionReport in
            async let pendingReport = service.delete(items: [device]) { _ in }
            return await pendingReport
        }
        defer { outerTask.cancel() }

        // Wait (with cancellation + deadline) until the worker is parked inside `ControllableCommandRunner.run`.
        try await waitUntil("worker parked in command runner") {
            await controller.hasParkedCall
        }
        outerTask.cancel()

        let report = await withTaskCancellationHandler {
            await outerTask.value
        } onCancel: {
            outerTask.cancel()
        }
        #expect(report.deletedCount == 0)
        #expect(report.failures.map(\.itemID) == ["sim-extra"])
    }
}

private struct ConditionTimeoutError: Error, CustomStringConvertible {
    let description: String
}

private func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(5),
    condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline {
            throw ConditionTimeoutError(description: "Timed out waiting for: \(label)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Test Doubles

private actor ProgressRecorder {
    private var events: [DeletionProgress] = []

    func append(_ progress: DeletionProgress) {
        events.append(progress)
    }

    func snapshot() -> [DeletionProgress] {
        events
    }
}

private struct PendingCommandHandle: Sendable {
    let id: UUID
    let arguments: [String]
}

private actor ControllableCommandRunner: CommandRunning {
    private var queuedHandles: [PendingCommandHandle] = []
    private var inFlightCalls: [UUID: CheckedContinuation<CommandOutput, any Error>] = [:]
    private var waiters: [(id: UUID, continuation: CheckedContinuation<PendingCommandHandle, any Error>)] = []

    var hasRegisteredWaiter: Bool {
        !waiters.isEmpty
    }

    var hasParkedCall: Bool {
        !inFlightCalls.isEmpty
    }

    func run(executableURL _: URL, arguments: [String]) async throws -> CommandOutput {
        let callID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightCalls[callID] = continuation
                let handle = PendingCommandHandle(id: callID, arguments: arguments)
                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.continuation.resume(returning: handle)
                } else {
                    queuedHandles.append(handle)
                }
            }
        } onCancel: {
            Task { await self.cancelCall(id: callID) }
        }
    }

    func nextPendingCall() async throws -> PendingCommandHandle {
        if !queuedHandles.isEmpty {
            return queuedHandles.removeFirst()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !queuedHandles.isEmpty {
                    continuation.resume(returning: queuedHandles.removeFirst())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func resumeCall(id: UUID, with result: Result<CommandOutput, any Error>) {
        guard let continuation = inFlightCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func cancelCall(id: UUID) {
        queuedHandles.removeAll { $0.id == id }
        guard let continuation = inFlightCalls.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
