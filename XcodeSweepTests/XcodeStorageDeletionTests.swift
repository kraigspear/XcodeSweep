import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeStorage deletion")
struct XcodeStorageDeletionTests {
    @Test("Trashes filesystem items through FileTrashing adapter and streams per-item outcomes")
    func deleteTrashesFilesAndRecordsFailure() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let goodURL = try fixture.addDerivedData(
            folderName: "Good-1",
            workspacePath: "/nonexistent/Good.xcodeproj",
            lastAccessed: now
        )
        let badURL = try fixture.addDerivedData(
            folderName: "Locked-2",
            workspacePath: "/nonexistent/Locked.xcodeproj",
            lastAccessed: now
        )

        let trasher = RecordingFileTrasher(failingURLs: [badURL])
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher
        )

        let snapshot = try await finalScanSnapshot(from: storage)
        let items = try #require(snapshot.itemsByCategory[.derivedData])
            .sorted { $0.name < $1.name }

        var events: [DeletionEvent] = []
        for try await event in storage.delete(DeletionPlan(selection: items)) {
            events.append(event)
        }

        let trashed = await trasher.trashedURLs
        #expect(trashed == [goodURL])
        #expect(events.count == 5)

        guard case let .starting(startFirst) = events[0],
              case let .deleted(deletedID, afterFirst) = events[1],
              case let .starting(startSecond) = events[2],
              case let .failed(failure, afterSecond) = events[3],
              case let .completed(report) = events[4]
        else {
            Issue.record("Unexpected deletion event sequence: \(events)")
            return
        }

        #expect(startFirst.completedCount == 0)
        #expect(deletedID == "derivedData:\(goodURL.path)")
        #expect(afterFirst.completedCount == 1)
        #expect(startSecond.completedCount == 1)
        #expect(failure.itemID == "derivedData:\(badURL.path)")
        #expect(afterSecond.completedCount == 2)

        #expect(report.deletedCount == 1)
        #expect(report.trashedCount == 1)
        #expect(report.simctlDeletedCount == 0)
        #expect(report.failures.map(\.itemID) == ["derivedData:\(badURL.path)"])
    }

    @Test(
        "Emits ordered start and outcome events across a suspended simctl deletion and handles failures",
        .timeLimit(.minutes(1))
    )
    func deleteEmitsOrderedProgressAcrossSuspensionAndFailure() async throws {
        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )

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

        let recorder = EventRecorder<DeletionEvent>()
        let deletionTask = Task {
            for try await event in storage.delete(DeletionPlan(selection: [
                bootedDevice,
                failingRuntime,
                protectedRuntime,
            ])) {
                await recorder.append(event)
            }
        }
        defer { deletionTask.cancel() }

        let firstCall = try await controller.nextPendingCall()
        #expect(firstCall.arguments == ["simctl", "shutdown", "UDID-1"])

        let eventsWhileSuspended = await recorder.snapshot()
        #expect(eventsWhileSuspended == [
            .starting(
                DeletionProgress(
                    completedCount: 0,
                    totalCount: 2,
                    currentItemName: "iPhone 17 Pro",
                    removedBytes: 0
                )
            ),
        ])

        await controller.resume(
            id: firstCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        let secondCall = try await controller.nextPendingCall()
        #expect(secondCall.arguments == ["simctl", "delete", "UDID-1"])
        await controller.resume(
            id: secondCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        let thirdCall = try await controller.nextPendingCall()
        #expect(thirdCall.arguments == ["simctl", "runtime", "delete", "RT-2"])

        let eventsBeforeFailureResolves = await recorder.snapshot()
        #expect(eventsBeforeFailureResolves == [
            .starting(
                DeletionProgress(completedCount: 0, totalCount: 2, currentItemName: "iPhone 17 Pro", removedBytes: 0)
            ),
            .deleted(
                itemID: "sim-1",
                progress: DeletionProgress(
                    completedCount: 1,
                    totalCount: 2,
                    currentItemName: "iPhone 17 Pro",
                    removedBytes: 4_000_000_000
                )
            ),
            .starting(
                DeletionProgress(
                    completedCount: 1,
                    totalCount: 2,
                    currentItemName: "iOS 26.4",
                    removedBytes: 4_000_000_000
                )
            ),
        ])

        await controller.resume(
            id: thirdCall.id,
            with: .failure(ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "runtime busy"))
        )

        try await deletionTask.value
        let allEvents = await recorder.snapshot()

        // The protected runtime never reaches deletion: DeletionPlan sets it aside.
        #expect(allEvents.count == 5)
        guard case let .failed(runtimeFailure, _) = allEvents[3],
              case let .completed(report) = allEvents[4]
        else {
            Issue.record("Unexpected tail events: \(allEvents)")
            return
        }

        #expect(runtimeFailure.itemID == "rt-2")
        #expect(report.deletedCount == 1)
        #expect(report.trashedCount == 0)
        #expect(report.simctlDeletedCount == 1)
        #expect(report.reclaimedBytes == 4_000_000_000)
        #expect(report.failures.map(\.itemID) == ["rt-2"])
    }
}
