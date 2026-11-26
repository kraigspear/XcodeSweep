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

        // Each progress carries the outcomes so far; the last one is the completed report.
        #expect(startFirst.report == .empty)
        #expect(afterFirst.report.deletedCount == 1)
        #expect(afterFirst.report.failures.isEmpty)
        #expect(startSecond.report == afterFirst.report)
        #expect(afterSecond.report.failures == [failure])
        #expect(afterSecond.report == report)

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
            statusExplanation: "",
            deletionMethod: .simctlDevice(udid: "UDID-1"),
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
            statusExplanation: "",
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
            statusExplanation: "",
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
                    report: .empty
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
                DeletionProgress(completedCount: 0, totalCount: 2, currentItemName: "iPhone 17 Pro", report: .empty)
            ),
            .deleted(
                itemID: "sim-1",
                progress: DeletionProgress(
                    completedCount: 1,
                    totalCount: 2,
                    currentItemName: "iPhone 17 Pro",
                    report: .empty.recordingRemoval(of: bootedDevice)
                )
            ),
            .starting(
                DeletionProgress(
                    completedCount: 1,
                    totalCount: 2,
                    currentItemName: "iOS 26.4",
                    report: .empty.recordingRemoval(of: bootedDevice)
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

    @Test("Runs destructive simctl shutdown and delete commands with no timeout")
    func deleteRunsSimctlCommandsWithoutTimeout() async throws {
        let runner = RecordingCommandRunner()
        let storage = XcodeStorage(
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )

        let bootedDevice = makeStorageItem(
            id: "sim-1",
            category: .simulatorDevices,
            status: .booted,
            method: .simctlDevice(udid: "UDID-1")
        )
        let runtime = makeStorageItem(
            id: "rt-1",
            category: .simulatorRuntimes,
            status: .stale,
            method: .simctlRuntime(identifier: "RT-1")
        )

        for try await _ in storage.delete(DeletionPlan(selection: [bootedDevice, runtime])) {}

        let calls = await runner.calls
        #expect(calls.map(\.arguments) == [
            ["simctl", "shutdown", "UDID-1"],
            ["simctl", "delete", "UDID-1"],
            ["simctl", "runtime", "delete", "RT-1"],
        ])
        #expect(calls.allSatisfy { $0.timeout == nil })
    }

    /// A simulator booted after the scan must still be shut down before a permanent delete.
    /// To replicate: scan → boot a shut-down simulator in Simulator.app → delete it in XcodeSweep.
    @Test("Shuts down every simulator before deleting it, whatever the scan saw")
    func shutsDownDeviceNotBootedAtScanTime() async throws {
        let runner = RecordingCommandRunner()
        let storage = XcodeStorage(commandRunner: runner, fileTrasher: RecordingFileTrasher())
        let shutDownAtScan = makeStorageItem(
            id: "sim-2",
            category: .simulatorDevices,
            status: .active,
            method: .simctlDevice(udid: "UDID-2")
        )

        for try await _ in storage.delete(DeletionPlan(selection: [shutDownAtScan])) {}

        #expect(await runner.calls.map(\.arguments) == [
            ["simctl", "shutdown", "UDID-2"],
            ["simctl", "delete", "UDID-2"],
        ])
    }

    /// To replicate: open a SwiftUI preview → delete its preview device in XcodeSweep → it leaves the preview set.
    @Test("Shuts down and deletes a preview device through simctl's preview set")
    func deletesPreviewDeviceInPreviewSet() async throws {
        let runner = RecordingCommandRunner()
        let storage = XcodeStorage(commandRunner: runner, fileTrasher: RecordingFileTrasher())
        let previewDevice = makeStorageItem(
            id: "preview-1",
            category: .previews,
            method: .simctlDevice(udid: "PREVIEW-1", deviceSet: .previews)
        )

        for try await _ in storage.delete(DeletionPlan(selection: [previewDevice])) {}

        #expect(await runner.calls.map(\.arguments) == [
            ["simctl", "--set", "previews", "shutdown", "PREVIEW-1"],
            ["simctl", "--set", "previews", "delete", "PREVIEW-1"],
        ])
    }

    /// To replicate: delete a shut-down simulator; `simctl shutdown` fails, and the delete still succeeds.
    @Test("Deletes a simulator even when its shutdown fails because it is already shut down")
    func deletesWhenShutdownFails() async throws {
        let runner = RecordingCommandRunner(stub: StubCommandRunner(shutdownError: ProcessRunnerError.nonZeroExit(
            command: "xcrun simctl shutdown UDID-3",
            status: 149,
            stderr: "Unable to shutdown device in current state: Shutdown"
        )))
        let storage = XcodeStorage(commandRunner: runner, fileTrasher: RecordingFileTrasher())
        let device = makeStorageItem(id: "sim-3", category: .simulatorDevices, method: .simctlDevice(udid: "UDID-3"))

        var report: DeletionReport?
        for try await event in storage.delete(DeletionPlan(selection: [device])) {
            if case let .completed(completed) = event {
                report = completed
            }
        }

        #expect(await runner.calls.map(\.arguments).last == ["simctl", "delete", "UDID-3"])
        #expect(report?.simctlDeletedCount == 1)
        #expect(report?.failures.isEmpty == true)
    }

    @Test("Test trashers remove only items inside their own fixture")
    func fakeTrashersStayInsideTheirFixture() throws {
        let owned = try TempXcodeFixture()
        let other = try TempXcodeFixture()
        defer {
            owned.cleanup()
            other.cleanup()
        }
        // A sibling whose name starts with the owned root's name must not count as inside it.
        let prefixSibling = URL(fileURLWithPath: owned.rootURL.path + "-sibling")
        try FileManager.default.createDirectory(at: prefixSibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefixSibling) }

        let ownedFile = owned.rootURL.appendingPathComponent("owned.bin")
        let otherFile = other.rootURL.appendingPathComponent("other.bin")
        let siblingFile = prefixSibling.appendingPathComponent("sibling.bin")
        for file in [ownedFile, otherFile, siblingFile] {
            try Data("x".utf8).write(to: file)
        }

        for file in [ownedFile, otherFile, siblingFile] {
            try removeItem(file, ifInside: owned.rootURL)
        }
        try removeItem(otherFile, ifInside: nil)

        #expect(!FileManager.default.fileExists(atPath: ownedFile.path))
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(FileManager.default.fileExists(atPath: siblingFile.path))
    }
}
