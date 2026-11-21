import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeSweepStore")
@MainActor
struct XcodeSweepStoreTests {
    @Test("Scans real XcodeStorage, aggregates metrics, selects reclaimable items, and trashes them")
    func scanFilterSelectAndDelete() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let activeProject = try fixture.createWorkspace(folderName: "main-repo", projectName: "SampleApp.xcodeproj")
        let orphanedURL = try fixture.addDerivedData(
            folderName: "SampleApp-old",
            workspacePath: "/nonexistent/SampleApp-old.xcodeproj",
            lastAccessed: now,
            payloadBytes: 16384
        )
        let activeURL = try fixture.addDerivedData(
            folderName: "SampleApp-main",
            workspacePath: activeProject.path,
            lastAccessed: now,
            payloadBytes: 32768
        )

        let devicesJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
              {
                "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/SIM-1/data",
                "dataPathSize": 3000000000,
                "logPathSize": 0,
                "udid": "SIM-1",
                "isAvailable": false,
                "state": "Shutdown",
                "name": "iPhone 15"
              }
            ]
          }
        }
        """

        let trasher = RecordingFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(devicesJSON: devicesJSON),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.refresh()

        let orphanedItem = try #require(store.items(for: .derivedData).first { $0.path == orphanedURL })
        let activeItem = try #require(store.items(for: .derivedData).first { $0.path == activeURL })
        let expectedTotal = orphanedItem.sizeBytes + activeItem.sizeBytes + 3_000_000_000
        let expectedReclaimable = orphanedItem.sizeBytes + 3_000_000_000

        #expect(store.summary.totalBytes == expectedTotal)
        #expect(store.summary.reclaimableBytes == expectedReclaimable)
        #expect(store.summary.reclaimableItemCount == 2)

        store.openCategoryAndSelectReclaimable(.derivedData)
        #expect(store.sidebarSelection == .category(.derivedData))
        #expect(store.statusFilter == .reclaimable)
        #expect(store.selectedItemIDs == [orphanedItem.id])
        #expect(store.selectedTotalBytes == orphanedItem.sizeBytes)

        store.requestDeleteSelected()
        let pending = try #require(store.pendingDeletion)
        #expect(pending.items.map(\.id) == [orphanedItem.id])

        // Simulate SwiftUI `.confirmationDialog(item:)` clearing the binding before the button's Task runs.
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(await trasher.trashedURLs == [orphanedURL])
        #expect(store.items(for: .derivedData).map(\.id) == [activeItem.id])
        #expect(store.summary.totalBytes == activeItem.sizeBytes + 3_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.reclaimedBytes == orphanedItem.sizeBytes)
        #expect(store.deletionProgress == nil)
    }

    @Test("Removes only succeeded item IDs when duplicate project names share a failure")
    func removesByIDNotNameWhenDuplicateNamesExist() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let firstURL = try fixture.addDerivedData(
            folderName: "SampleApp-dup1",
            workspacePath: "/nonexistent/one/SampleApp.xcodeproj",
            lastAccessed: now,
            payloadBytes: 8192
        )
        let secondURL = try fixture.addDerivedData(
            folderName: "SampleApp-dup2",
            workspacePath: "/nonexistent/two/SampleApp.xcodeproj",
            lastAccessed: now,
            payloadBytes: 16384
        )

        let trasher = RecordingFileTrasher(failingURLs: [secondURL])
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.refresh()
        #expect(store.items(for: .derivedData).allSatisfy { $0.name == "SampleApp" })

        store.openCategoryAndSelectReclaimable(.derivedData)
        store.requestDeleteSelected()

        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(await trasher.trashedURLs == [firstURL])
        #expect(store.items(for: .derivedData).map(\.path) == [secondURL])
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.failures.map(\.itemID) == ["derivedData:\(secondURL.path)"])
    }

    @Test(
        "Updates items and totals live while a batch is suspended in FileTrashing, clears state, and handles a follow-up batch",
        .timeLimit(.minutes(1))
    )
    func liveProgressUpdatesDuringSuspendedBatchAndClearsOnCompletion() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let firstURL = try fixture.addDerivedData(
            folderName: "First-1",
            workspacePath: "/nonexistent/First.xcodeproj",
            lastAccessed: now,
            payloadBytes: 16384
        )
        let secondURL = try fixture.addDerivedData(
            folderName: "Second-2",
            workspacePath: "/nonexistent/Second.xcodeproj",
            lastAccessed: now,
            payloadBytes: 32768
        )
        let thirdURL = try fixture.addDerivedData(
            folderName: "Third-3",
            workspacePath: "/nonexistent/Third.xcodeproj",
            lastAccessed: now,
            payloadBytes: 65536
        )

        let trasher = ControllableFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.refresh()

        let first = try #require(store.items(for: .derivedData).first { $0.path == firstURL })
        let second = try #require(store.items(for: .derivedData).first { $0.path == secondURL })
        let third = try #require(store.items(for: .derivedData).first { $0.path == thirdURL })
        let totalInitialBytes = first.sizeBytes + second.sizeBytes + third.sizeBytes
        #expect(store.summary.totalBytes == totalInitialBytes)

        // Batch 1: delete first and second, suspending between them inside FileTrashing.
        store.requestDelete(items: [first, second])
        let batch1 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch1Done: Void = store.confirmDeletion(batch1)

        let call1 = try await trasher.nextPendingTrash()
        #expect(call1.url == firstURL)
        #expect(store.isDeleting)
        #expect(store.deletionProgress?.completedCount == 0)
        #expect(store.deletionProgress?.totalCount == 2)

        await trasher.resumeTrash(id: call1.id)
        let call2 = try await trasher.nextPendingTrash()
        #expect(call2.url == secondURL)

        // Item 1 must already be removed live and summary totals decremented before batch 1 completes.
        #expect(store.isDeleting)
        #expect(Set(store.items(for: .derivedData).map(\.id)) == [second.id, third.id])
        #expect(store.summary.totalBytes == second.sizeBytes + third.sizeBytes)
        #expect(store.deletionProgress?.completedCount == 1)
        #expect(store.deletionProgress?.removedBytes == first.sizeBytes)

        await trasher.resumeTrash(id: call2.id)
        await batch1Done

        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == [third.id])
        #expect(store.summary.totalBytes == third.sizeBytes)
        #expect(store.lastDeletionReport?.deletedCount == 2)

        // Batch 2: verify a subsequent batch runs cleanly with no leftover progress state.
        store.requestDelete(items: [third])
        let batch2 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch2Done: Void = store.confirmDeletion(batch2)

        let call3 = try await trasher.nextPendingTrash()
        #expect(call3.url == thirdURL)
        #expect(store.isDeleting)
        #expect(store.deletionProgress?.totalCount == 1)
        await trasher.resumeTrash(id: call3.id)

        await batch2Done
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).isEmpty)
        #expect(store.summary.totalBytes == 0)
        #expect(store.lastDeletionReport?.deletedCount == 1)
    }

    @Test(
        "Cancelling while awaiting a store batch parked in FileTrashing exits cleanly and keeps item intact",
        .timeLimit(.minutes(1))
    )
    func cancelledStoreBatchExitsCleanly() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let parkedURL = try fixture.addDerivedData(
            folderName: "Parked-1",
            workspacePath: "/nonexistent/Parked.xcodeproj",
            lastAccessed: now
        )

        let trasher = ControllableFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.refresh()
        let item = try #require(store.items(for: .derivedData).first { $0.path == parkedURL })

        store.requestDelete(items: [item])
        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let outerTask = Task { @MainActor in
            await store.confirmDeletion(pending)
        }
        defer { outerTask.cancel() }

        try await waitUntil("store batch parked in file trasher") {
            await trasher.hasParkedCall
        }
        outerTask.cancel()
        await outerTask.value

        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == [item.id])
    }

    @Test(
        "A cancelled scan leaves the store unscanned so the next appearance scans again",
        .timeLimit(.minutes(1))
    )
    func cancelledScanLeavesStoreUnscanned() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        // Given: a refresh parked on both simctl commands
        let refreshTask = Task { await store.refresh() }
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()

        // When
        refreshTask.cancel()
        await refreshTask.value
        try await Task.sleep(for: .milliseconds(50)) // let queued progress updates land

        // Then
        #expect(store.summary.scannedAt == .distantPast)
        #expect(store.errorMessage == nil)
        #expect(store.scanWarnings.isEmpty)
        #expect(!store.isScanning)
    }

    @Test(
        "A cancelled rescan restores the last completed result, including warnings and totals",
        .timeLimit(.minutes(1))
    )
    func cancelledRescanRestoresLastCompletedResult() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        try fixture.addDerivedData(
            folderName: "Kept-1",
            workspacePath: "/nonexistent/Kept.xcodeproj",
            lastAccessed: Date.distantPast
        )

        // Given: a completed scan with one DerivedData item and a runtime warning
        let firstScan = Task { await store.refresh() }
        for _ in 0 ..< 2 {
            let call = try await controller.nextPendingCall()
            if call.arguments.contains("devices") {
                await controller.resumeCall(id: call.id, with: .success(
                    CommandOutput(stdout: Data(#"{"devices":{}}"#.utf8), stderr: Data(), terminationStatus: 0)
                ))
            } else {
                await controller.resumeCall(id: call.id, with: .failure(TestTrashError(message: "runtime list failed")))
            }
        }
        await firstScan.value
        let completedSummary = store.summary
        let completedWarnings = store.scanWarnings
        #expect(completedWarnings.count == 1)

        // When: DerivedData changes, the rescan reports it, then the rescan is cancelled
        try fixture.addDerivedData(
            folderName: "Added-2",
            workspacePath: "/nonexistent/Added.xcodeproj",
            lastAccessed: Date.distantPast
        )
        let rescan = Task { await store.refresh() }
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()
        try await waitUntil("rescan reported new DerivedData") {
            await store.items(for: .derivedData).count == 2
        }
        rescan.cancel()
        await rescan.value
        try await Task.sleep(for: .milliseconds(50)) // let queued progress updates land

        // Then
        #expect(store.items(for: .derivedData).map(\.name) == ["Kept"])
        #expect(store.summary == completedSummary)
        #expect(store.scanWarnings == completedWarnings)
        #expect(store.completedCategories == Set(StorageCategory.allCases))
    }

    @Test(
        "A cancelled rescan does not bring back an item deleted while it ran",
        .timeLimit(.minutes(1))
    )
    func cancelledRescanKeepsDeletionsMadeDuringScan() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let trasher = RecordingFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: trasher
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        try fixture.addDerivedData(
            folderName: "Doomed-1",
            workspacePath: "/nonexistent/Doomed.xcodeproj",
            lastAccessed: Date.distantPast
        )

        // Given: a completed scan, then a rescan parked on simctl
        let firstScan = Task { await store.refresh() }
        try await answerSimctl(controller)
        await firstScan.value
        let doomed = try #require(store.items(for: .derivedData).first)

        let rescan = Task { await store.refresh() }
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()

        // When: the item is deleted mid-scan, then the rescan is cancelled
        await store.confirmDeletion(PendingDeletion(items: [doomed]))
        #expect(try await trasher.trashedURLs == [#require(doomed.path)])
        rescan.cancel()
        await rescan.value

        // Then
        #expect(store.items(for: .derivedData).isEmpty)
        #expect(store.summary.totalItemCount == 0)
    }

    private func answerSimctl(_ controller: ControllableCommandRunner) async throws {
        for _ in 0 ..< 2 {
            let call = try await controller.nextPendingCall()
            let json = call.arguments.contains("devices") ? #"{"devices":{}}"# : "{}"
            await controller.resumeCall(id: call.id, with: .success(
                CommandOutput(stdout: Data(json.utf8), stderr: Data(), terminationStatus: 0)
            ))
        }
    }
}
