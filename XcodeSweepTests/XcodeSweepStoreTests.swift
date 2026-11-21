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
}
