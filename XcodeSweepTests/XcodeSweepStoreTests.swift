import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeSweepStore")
@MainActor
struct XcodeSweepStoreTests {
    @Test("Runs initial scan via refreshIfNeeded, aggregates metrics, selects reclaimable items, and trashes them")
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

        #expect(store.inventory.scannedAt == nil)
        #expect(!store.hasCompletedScan)
        #expect(store.operation == .idle)

        await store.refreshIfNeeded()

        #expect(store.inventory.scannedAt == now)
        #expect(store.hasCompletedScan)
        #expect(store.operation == .idle)

        let orphanedItem = try #require(store.inventory.items(in: .derivedData).first { $0.path == orphanedURL })
        let activeItem = try #require(store.inventory.items(in: .derivedData).first { $0.path == activeURL })
        let expectedTotal = orphanedItem.sizeBytes + activeItem.sizeBytes + 3_000_000_000
        let expectedReclaimable = orphanedItem.sizeBytes + 3_000_000_000

        #expect(store.inventory.totalBytes == expectedTotal)
        #expect(store.inventory.reclaimableBytes == expectedReclaimable)
        #expect(store.inventory.reclaimableItemCount == 2)

        store.openCategoryAndSelectReclaimable(.derivedData)
        #expect(store.sidebarSelection == .category(.derivedData))
        #expect(store.statusFilter == .reclaimable)
        #expect(store.selectedItemIDs == [orphanedItem.id])
        #expect(store.selectionPlan.totalBytes == orphanedItem.sizeBytes)

        store.requestDeleteSelected()
        let pending = try #require(store.pendingDeletion)
        #expect(pending.deletableItems.map(\.id) == [orphanedItem.id])

        // Simulate SwiftUI `.confirmationDialog(item:)` clearing the binding before the button's Task runs.
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(await trasher.trashedURLs == [orphanedURL])
        #expect(store.inventory.items(in: .derivedData).map(\.id) == [activeItem.id])
        #expect(store.inventory.totalBytes == activeItem.sizeBytes + 3_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.reclaimedBytes == orphanedItem.sizeBytes)
        #expect(store.operation == .idle)
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
        #expect(store.inventory.items(in: .derivedData).allSatisfy { $0.name == "SampleApp" })

        store.openCategoryAndSelectReclaimable(.derivedData)
        store.requestDeleteSelected()

        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(await trasher.trashedURLs == [firstURL])
        #expect(store.inventory.items(in: .derivedData).map(\.path) == [secondURL])
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

        let first = try #require(store.inventory.items(in: .derivedData).first { $0.path == firstURL })
        let second = try #require(store.inventory.items(in: .derivedData).first { $0.path == secondURL })
        let third = try #require(store.inventory.items(in: .derivedData).first { $0.path == thirdURL })
        let totalInitialBytes = first.sizeBytes + second.sizeBytes + third.sizeBytes
        #expect(store.inventory.totalBytes == totalInitialBytes)

        // Batch 1: delete first and second, suspending between them inside FileTrashing.
        store.requestDelete(items: [first, second])
        let batch1 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch1Done: Void = store.confirmDeletion(batch1)

        let call1 = try await trasher.nextPendingCall()
        #expect(call1.url == firstURL)
        #expect(store.isDeleting)
        #expect(!store.canRefresh)
        #expect(!store.canDelete)
        #expect(store.deletionProgress?.completedCount == 0)
        #expect(store.deletionProgress?.totalCount == 2)

        await trasher.resume(id: call1.id)
        let call2 = try await trasher.nextPendingCall()
        #expect(call2.url == secondURL)

        // Item 1 must already be removed live and inventory totals decremented before batch 1 completes.
        #expect(store.isDeleting)
        #expect(Set(store.inventory.items(in: .derivedData).map(\.id)) == [second.id, third.id])
        #expect(store.inventory.totalBytes == second.sizeBytes + third.sizeBytes)
        #expect(store.deletionProgress?.completedCount == 1)
        #expect(store.deletionProgress?.removedBytes == first.sizeBytes)

        await trasher.resume(id: call2.id)
        await batch1Done

        #expect(store.operation == .idle)
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.inventory.items(in: .derivedData).map(\.id) == [third.id])
        #expect(store.inventory.totalBytes == third.sizeBytes)
        #expect(store.lastDeletionReport?.deletedCount == 2)

        // Batch 2: verify a subsequent batch runs cleanly with no leftover progress state.
        store.requestDelete(items: [third])
        let batch2 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch2Done: Void = store.confirmDeletion(batch2)

        let call3 = try await trasher.nextPendingCall()
        #expect(call3.url == thirdURL)
        #expect(store.isDeleting)
        #expect(store.deletionProgress?.totalCount == 1)
        await trasher.resume(id: call3.id)

        await batch2Done
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).isEmpty)
        #expect(store.inventory.totalBytes == 0)
        #expect(store.lastDeletionReport?.deletedCount == 1)
    }

    @Test(
        "Cancelling a multi-item batch keeps already-deleted items removed, leaves remaining items intact, and skips the completion alert",
        .timeLimit(.minutes(1))
    )
    func cancelledMultiItemStoreBatchExitsCleanlyWithoutAlert() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let firstURL = try fixture.addDerivedData(
            folderName: "Done-1",
            workspacePath: "/nonexistent/Done.xcodeproj",
            lastAccessed: now
        )
        let secondURL = try fixture.addDerivedData(
            folderName: "Parked-2",
            workspacePath: "/nonexistent/Parked.xcodeproj",
            lastAccessed: now
        )
        let thirdURL = try fixture.addDerivedData(
            folderName: "Untouched-3",
            workspacePath: "/nonexistent/Untouched.xcodeproj",
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
        let first = try #require(store.inventory.items(in: .derivedData).first { $0.path == firstURL })
        let second = try #require(store.inventory.items(in: .derivedData).first { $0.path == secondURL })
        let third = try #require(store.inventory.items(in: .derivedData).first { $0.path == thirdURL })

        store.requestDelete(items: [first, second, third])
        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let batchTask = Task { @MainActor in
            await store.confirmDeletion(pending)
        }
        defer { batchTask.cancel() }

        // Complete item 1, then cancel while item 2 is parked.
        let call1 = try await trasher.nextPendingCall()
        #expect(call1.url == firstURL)
        await trasher.resume(id: call1.id)

        let call2 = try await trasher.nextPendingCall()
        #expect(call2.url == secondURL)
        batchTask.cancel()
        await batchTask.value

        #expect(store.operation == .idle)
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.lastDeletionReport == nil)
        #expect(store.errorMessage == nil)
        #expect(await trasher.trashedURLs == [firstURL])
        #expect(Set(store.inventory.items(in: .derivedData).map(\.id)) == [second.id, third.id])
    }

    @Test(
        "A cancelled initial scan leaves the store unscanned so refreshIfNeeded scans on the next appearance",
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

        // Given: an initial scan parked on both simctl commands
        let refreshTask = Task { await store.refreshIfNeeded() }
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()

        // When
        refreshTask.cancel()
        await refreshTask.value

        // Then: deterministic teardown guarantees no stray updates, no error, and unscanned state
        #expect(store.inventory.scannedAt == nil)
        #expect(!store.hasCompletedScan)
        #expect(store.errorMessage == nil)
        #expect(store.scanWarnings.isEmpty)
        #expect(store.operation == .idle)
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
                await controller.resume(id: call.id, with: .success(
                    CommandOutput(stdout: Data(#"{"devices":{}}"#.utf8), stderr: Data(), terminationStatus: 0)
                ))
            } else {
                await controller.resume(id: call.id, with: .failure(TestTrashError(message: "runtime list failed")))
            }
        }
        await firstScan.value
        let completedInventory = store.inventory
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
            await store.inventory.items(in: .derivedData).count == 2
        }
        rescan.cancel()
        await rescan.value

        // Then
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).map(\.name) == ["Kept"])
        #expect(store.inventory == completedInventory)
        #expect(store.scanWarnings == completedWarnings)
        #expect(store.completedCategories == Set(StorageCategory.allCases))
    }

    @Test(
        "Strictly enforces mutual exclusion: delete is blocked while scanning, and scan is blocked while deleting",
        .timeLimit(.minutes(1))
    )
    func mutualExclusionBlocksOverlappingScanAndDelete() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let trasher = ControllableFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: trasher
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        try fixture.addDerivedData(
            folderName: "Target-1",
            workspacePath: "/nonexistent/Target.xcodeproj",
            lastAccessed: Date.distantPast
        )

        // Seed one completed scan.
        let firstScan = Task { await store.refresh() }
        try await answerSimctl(controller)
        await firstScan.value
        let target = try #require(store.inventory.items(in: .derivedData).first)

        // 1. Start a rescan and park it in simctl; deletion must be completely rejected.
        let rescan = Task { await store.refresh() }
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()

        #expect(store.isScanning)
        #expect(!store.canDelete)
        store.requestDelete(items: [target])
        #expect(store.pendingDeletion == nil)
        await store.confirmDeletion(DeletionPlan(selection: [target]))
        #expect(await trasher.trashedURLs.isEmpty)

        rescan.cancel()
        await rescan.value
        #expect(store.operation == .idle)

        // 2. Start a deletion and park it in FileTrashing; refresh must be rejected.
        store.requestDelete(items: [target])
        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let deleteTask = Task { await store.confirmDeletion(pending) }
        let trashCall = try await trasher.nextPendingCall()

        #expect(store.isDeleting)
        #expect(!store.canRefresh)
        await store.refresh() // must no-op immediately while deleting
        #expect(await !controller.hasParkedCall)

        await trasher.resume(id: trashCall.id)
        await deleteTask.value
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).isEmpty)
    }

    /// Verifies switching sidebar destinations starts the new one with no leftover filter, search, or selection.
    /// To replicate: in DerivedData choose Unused, type a search, select a row → click Simulator Devices.
    @Test("Navigating to another destination resets category state")
    func navigate_toDifferentDestination_resetsFilterSearchAndSelection() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        store.navigate(to: .category(.derivedData))
        store.statusFilter = .stale
        store.searchText = "Sample"
        store.selectedItemIDs = Set(store.inventory.items(in: .derivedData).map(\.id))

        store.navigate(to: .category(.simulatorDevices))

        #expect(store.sidebarSelection == .category(.simulatorDevices))
        #expect(store.statusFilter == .all)
        #expect(store.searchText.isEmpty)
        #expect(store.selectedItemIDs.isEmpty)
    }

    /// Verifies re-selecting the current destination keeps the user's filter, search, and selection.
    /// To replicate: in DerivedData choose Unused and select a row → click DerivedData in the sidebar again.
    @Test("Navigating to the current destination keeps category state")
    func navigate_toSameDestination_keepsFilterSearchAndSelection() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        store.navigate(to: .category(.derivedData))
        store.statusFilter = .stale
        store.searchText = "Sample"
        let selection = Set(store.inventory.items(in: .derivedData).map(\.id))
        store.selectedItemIDs = selection

        store.navigate(to: .category(.derivedData))

        #expect(store.statusFilter == .stale)
        #expect(store.searchText == "Sample")
        #expect(store.selectedItemIDs == selection)
    }

    /// Verifies "Review Cleanable" lands on the category with Recommended applied, no stale search, and candidates
    /// selected.
    /// To replicate: in Simulator Devices type a search → go to Overview → click "Review N Cleanable" on DerivedData.
    @Test("Opening a category for cleanup applies Recommended and selects candidates")
    func openCategoryAndSelectReclaimable_fromAnotherCategory_appliesRecommendedAndSelects() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        store.navigate(to: .category(.simulatorDevices))
        store.searchText = "iPhone"

        store.openCategoryAndSelectReclaimable(.derivedData)

        let candidates = store.inventory.items(in: .derivedData).filter(\.isReclaimableCandidate)
        #expect(!candidates.isEmpty)
        #expect(store.sidebarSelection == .category(.derivedData))
        #expect(store.statusFilter == .reclaimable)
        #expect(store.searchText.isEmpty)
        #expect(store.selectedItemIDs == Set(candidates.map(\.id)))
    }

    private func makeScannedStore() async throws -> (XcodeSweepStore, TempXcodeFixture) {
        let fixture = try TempXcodeFixture()
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        _ = try fixture.addDerivedData(
            folderName: "SampleApp-old",
            workspacePath: "/nonexistent/SampleApp-old.xcodeproj",
            lastAccessed: now
        )
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        await store.refresh()
        return (store, fixture)
    }

    private func answerSimctl(_ controller: ControllableCommandRunner) async throws {
        for _ in 0 ..< 2 {
            let call = try await controller.nextPendingCall()
            let json = call.arguments.contains("devices") ? #"{"devices":{}}"# : "{}"
            await controller.resume(id: call.id, with: .success(
                CommandOutput(stdout: Data(json.utf8), stderr: Data(), terminationStatus: 0)
            ))
        }
    }
}
