import Foundation
import os
import Testing
@testable import XcodeSweep

@Suite("XcodeStorage cancellation")
struct XcodeStorageCancellationTests {
    /// A scan that stops before `.completed` must not look finished, or the store would keep a
    /// partial inventory instead of restoring the previous one.
    @Test("A producer cancelled on its own makes the scan throw, though the consumer wasn't cancelled", .timeLimit(.minutes(1)))
    func producerCancelledAloneThrows() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            // The producer reads the clock first; cancelling the task that calls it cancels only the producer.
            now: {
                withUnsafeCurrentTask { $0?.cancel() }
                return testISO8601Date("2026-11-21T10:00:00Z")
            }
        )

        let consumer = Task {
            var events: [ScanEvent] = []
            for try await event in storage.scan() {
                events.append(event)
            }
            return events
        }

        let result = try await awaitResult(of: consumer, within: .seconds(10))
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!consumer.isCancelled)
    }

    @Test(
        "Cancelling during booted simctl shutdown stops immediately without deleting or starting remaining items",
        .timeLimit(.minutes(1))
    )
    func cancelledDeletionStopsImmediatelyWithoutFailureOrRemainingItems() async throws {
        let controller = ControllableCommandRunner()
        let trasher = RecordingFileTrasher()
        let storage = XcodeStorage(
            commandRunner: controller,
            fileTrasher: trasher
        )

        let bootedDevice = StorageItem(
            id: "sim-booted",
            category: .simulatorDevices,
            name: "iPhone 17",
            subtitle: "iOS 27.2",
            sizeBytes: 1_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .booted,
            deletionMethod: .simctlDevice(udid: "UDID-BOOTED"),
            metadata: []
        )
        let trailingFile = StorageItem(
            id: "file-trailing",
            category: .derivedData,
            name: "TrailingApp",
            subtitle: "Orphaned",
            sizeBytes: 500_000_000,
            lastUsedDate: nil,
            path: URL(fileURLWithPath: "/tmp/trailing"),
            workspacePath: nil,
            status: .orphaned,
            deletionMethod: .trashFile(URL(fileURLWithPath: "/tmp/trailing")),
            metadata: []
        )

        let recorder = EventRecorder<DeletionEvent>()
        let deleteTask = Task {
            for try await event in storage.delete(DeletionPlan(selection: [bootedDevice, trailingFile])) {
                await recorder.append(event)
            }
        }
        defer { deleteTask.cancel() }

        let shutdownCall = try await controller.nextPendingCall()
        #expect(shutdownCall.arguments == ["simctl", "shutdown", "UDID-BOOTED"])

        deleteTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await deleteTask.value
        }

        // Shutdown cancellation must not fall through to `simctl delete` or touch trailing items.
        #expect(await controller.recordedArguments == [["simctl", "shutdown", "UDID-BOOTED"]])
        #expect(await !controller.hasParkedCall)
        #expect(await trasher.trashedURLs.isEmpty)

        let events = await recorder.snapshot()
        #expect(events == [
            .starting(
                DeletionProgress(completedCount: 0, totalCount: 2, currentItemName: "iPhone 17", removedBytes: 0)
            ),
        ])
    }

    @Test(
        "Cancelling during booted shutdown skips simctl delete even if shutdown returns normally",
        .timeLimit(.minutes(1))
    )
    func cancelledShutdownReturningNormallyStillSkipsDelete() async throws {
        let runner = IgnoreCancelShutdownRunner()
        // Unique, so this test's log entries can't be confused with another's.
        let udid = "UDID-BOOTED-\(UUID().uuidString)"
        let storage = XcodeStorage(
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )

        let bootedDevice = StorageItem(
            id: "sim-booted",
            category: .simulatorDevices,
            name: "iPhone 17",
            subtitle: "iOS 27.2",
            sizeBytes: 1_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .booted,
            deletionMethod: .simctlDevice(udid: udid),
            metadata: []
        )

        let deleteTask = Task {
            for try await _ in storage.delete(DeletionPlan(selection: [bootedDevice])) {}
        }
        defer { deleteTask.cancel() }

        await runner.waitUntilStarted()
        deleteTask.cancel()
        await runner.finishNormally()

        await #expect(throws: CancellationError.self) {
            try await deleteTask.value
        }

        #expect(await runner.recordedArguments == [["simctl", "shutdown", udid]])
        // Nothing reached simctl delete, so the log mustn't suggest the device may be gone.
        let entries = try deletionLogEntries(mentioning: udid)
        #expect(entries.map(\.composedMessage) == ["outcome=skipped method=simctlDevice target=\(udid)"])
    }

    @Test(
        "Cancelling between receiving .starting and pulling execution never touches FileTrashing",
        .timeLimit(.minutes(1))
    )
    func cancelledBetweenStartingAndExecutionNeverTouchesTrasher() async throws {
        let trasher = RecordingFileTrasher()
        let storage = XcodeStorage(
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher
        )

        let item = StorageItem(
            id: "file-1",
            category: .derivedData,
            name: "SampleApp",
            subtitle: "Orphaned",
            sizeBytes: 1000,
            lastUsedDate: nil,
            path: URL(fileURLWithPath: "/tmp/sample"),
            workspacePath: nil,
            status: .orphaned,
            deletionMethod: .trashFile(URL(fileURLWithPath: "/tmp/sample")),
            metadata: []
        )

        let sawStarting = AsyncSignal()
        let proceedAfterCancel = AsyncSignal()

        let deleteTask = Task {
            var iterator = storage.delete(DeletionPlan(selection: [item])).makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first == .starting(
                DeletionProgress(completedCount: 0, totalCount: 1, currentItemName: "SampleApp", removedBytes: 0)
            ))
            await sawStarting.signal()
            await proceedAfterCancel.wait()
            _ = try await iterator.next()
        }
        defer { deleteTask.cancel() }

        await sawStarting.wait()
        deleteTask.cancel()
        await proceedAfterCancel.signal()

        await #expect(throws: CancellationError.self) {
            try await deleteTask.value
        }
        #expect(await trasher.trashedURLs.isEmpty)
    }

    @Test(
        "Throws CancellationError and awaits full producer teardown before consumer exits",
        .timeLimit(.minutes(1))
    )
    func scanCancelledDuringSimctlThrowsWithoutSimulatorProgress() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let timeline = OSAllocatedUnfairLock<[String]>(initialState: [])
        let runner = GatedCleanupCommandRunner(expectedCalls: 2, timeline: timeline)
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )
        let reportedEvents = OSAllocatedUnfairLock<[ScanEvent]>(initialState: [])

        let scanTask = Task {
            defer {
                timeline.withLock { $0.append("consumerExited") }
            }
            for try await event in storage.scan() {
                reportedEvents.withLock { $0.append(event) }
            }
        }
        defer { scanTask.cancel() }

        await runner.waitUntilAllCallsParked()
        scanTask.cancel()
        await runner.waitUntilAllCallsObservedCancellation()

        // Consumer must still be waiting on producer teardown until cleanup finishes.
        #expect(timeline.withLock { $0 }.isEmpty)
        await runner.releaseCleanup()

        await #expect(throws: CancellationError.self) {
            try await scanTask.value
        }

        #expect(timeline.withLock { $0 } == ["cleanupFinished", "cleanupFinished", "consumerExited"])

        let events = reportedEvents.withLock { $0 }
        for event in events {
            switch event {
            case let .categoryScanned(category, _):
                #expect(category != .simulatorDevices)
                #expect(category != .simulatorRuntimes)
            case .completed:
                Issue.record("Cancelled scan must not emit .completed")
            }
        }
    }

    @Test(
        "Cancellation after receiving .completed finishes cleanly without throwing",
        .timeLimit(.minutes(1))
    )
    func cancellationAfterCompletedReturnsNilWithoutThrowing() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )

        let sawCompleted = AsyncSignal()
        let proceedAfterCancel = AsyncSignal()

        let scanTask = Task { () -> ScanEvent? in
            var iterator = storage.scan().makeAsyncIterator()
            while let event = try await iterator.next() {
                if case .completed = event {
                    await sawCompleted.signal()
                    await proceedAfterCancel.wait()
                    return try await iterator.next()
                }
            }
            return nil
        }
        defer { scanTask.cancel() }

        await sawCompleted.wait()
        scanTask.cancel()
        await proceedAfterCancel.signal()

        let trailing = try await scanTask.value
        #expect(trailing == nil)
    }

    @Test(
        "Breaking out of scan early cancels remaining in-flight simctl commands",
        .timeLimit(.minutes(1))
    )
    func breakingOutOfScanEarlyCancelsRemainingWork() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )

        var parkedCalls: [ParkedCall<[String]>] = []
        for try await event in storage.scan() {
            if case .categoryScanned = event {
                // Wait until both simctl calls are parked before breaking out of the loop.
                try parkedCalls.append(await controller.nextPendingCall())
                try parkedCalls.append(await controller.nextPendingCall())
                break
            }
        }

        #expect(parkedCalls.count == 2)
        // Breaking releases the iterator, whose producer handle cancels parked simctl calls.
        for call in parkedCalls {
            do {
                try await controller.waitForCancellation(id: call.id)
            } catch is CancellationError {
                Issue.record("Parked command did not receive cancellation: \(call.arguments.joined(separator: " "))")
                throw CancellationError()
            }
        }
    }
}


private actor IgnoreCancelShutdownRunner: CommandRunning {
    private(set) var recordedArguments: [[String]] = []
    private let started = AsyncSignal()
    private let release = AsyncSignal()

    func run(executableURL _: URL, arguments: [String], timeout _: Duration?) async throws -> CommandOutput {
        recordedArguments.append(arguments)
        await started.signal()
        await release.wait()
        return CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func finishNormally() async {
        await release.signal()
    }
}

private actor GatedCleanupCommandRunner: CommandRunning {
    private let expectedCalls: Int
    private let timeline: OSAllocatedUnfairLock<[String]>
    private var parkedCount = 0
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledCount = 0
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightParks: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let cleanupGate = AsyncSignal()

    init(expectedCalls: Int, timeline: OSAllocatedUnfairLock<[String]>) {
        self.expectedCalls = expectedCalls
        self.timeline = timeline
    }

    func run(executableURL _: URL, arguments _: [String], timeout _: Duration?) async throws -> CommandOutput {
        let callID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkedCount += 1
                if parkedCount >= expectedCalls {
                    let waiters = parkedWaiters
                    parkedWaiters.removeAll()
                    for waiter in waiters {
                        waiter.resume()
                    }
                }
                if Task.isCancelled {
                    incrementCancelledCount()
                    continuation.resume()
                } else {
                    inFlightParks[callID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelParkedCall(id: callID) }
        }

        await cleanupGate.wait()
        timeline.withLock { $0.append("cleanupFinished") }
        throw CancellationError()
    }

    func waitUntilAllCallsParked() async {
        if parkedCount >= expectedCalls {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if parkedCount >= expectedCalls {
                continuation.resume()
            } else {
                parkedWaiters.append(continuation)
            }
        }
    }

    func waitUntilAllCallsObservedCancellation() async {
        if cancelledCount >= expectedCalls {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if cancelledCount >= expectedCalls {
                continuation.resume()
            } else {
                cancelledWaiters.append(continuation)
            }
        }
    }

    func releaseCleanup() async {
        await cleanupGate.signal()
    }

    private func cancelParkedCall(id: UUID) {
        guard let continuation = inFlightParks.removeValue(forKey: id) else { return }
        incrementCancelledCount()
        continuation.resume()
    }

    private func incrementCancelledCount() {
        cancelledCount += 1
        if cancelledCount >= expectedCalls {
            let waiters = cancelledWaiters
            cancelledWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
