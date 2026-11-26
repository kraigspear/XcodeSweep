import Foundation
import Observation
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

        let trasher = RecordingFileTrasher(removingUnder: fixture.rootURL)
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
        await store.startDeletion(pending)?.value

        #expect(await trasher.trashedURLs == [orphanedURL])
        #expect(store.inventory.items(in: .derivedData).map(\.id) == [activeItem.id])
        #expect(store.inventory.totalBytes == activeItem.sizeBytes + 3_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.reclaimedBytes == orphanedItem.sizeBytes)
        #expect(store.operation == .idle)
        #expect(store.operation.deletionProgress == nil)
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

        let trasher = RecordingFileTrasher(failingURLs: [secondURL], removingUnder: fixture.rootURL)
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.startRefresh()?.value
        #expect(store.inventory.items(in: .derivedData).allSatisfy { $0.name == "SampleApp" })

        store.openCategoryAndSelectReclaimable(.derivedData)
        store.requestDeleteSelected()

        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil
        await store.startDeletion(pending)?.value

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

        let trasher = ControllableFileTrasher(removingUnder: fixture.rootURL)
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.startRefresh()?.value

        let first = try #require(store.inventory.items(in: .derivedData).first { $0.path == firstURL })
        let second = try #require(store.inventory.items(in: .derivedData).first { $0.path == secondURL })
        let third = try #require(store.inventory.items(in: .derivedData).first { $0.path == thirdURL })
        let totalInitialBytes = first.sizeBytes + second.sizeBytes + third.sizeBytes
        #expect(store.inventory.totalBytes == totalInitialBytes)

        // Batch 1: delete first and second, suspending between them inside FileTrashing.
        store.requestDelete(items: [first, second])
        let batch1 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let batch1Task = store.startDeletion(batch1)

        let call1 = try await trasher.nextPendingCall()
        #expect(call1.url == firstURL)
        #expect(store.operation.isDeleting)
        #expect(store.operation.isBusy)
        #expect(store.operation.deletionProgress?.completedCount == 0)
        #expect(store.operation.deletionProgress?.totalCount == 2)

        await trasher.resume(id: call1.id)
        let call2 = try await trasher.nextPendingCall()
        #expect(call2.url == secondURL)

        // Item 1 must already be removed live and inventory totals decremented before batch 1 completes.
        #expect(store.operation.isDeleting)
        #expect(Set(store.inventory.items(in: .derivedData).map(\.id)) == [second.id, third.id])
        #expect(store.inventory.totalBytes == second.sizeBytes + third.sizeBytes)
        #expect(store.operation.deletionProgress?.completedCount == 1)
        #expect(store.operation.deletionProgress?.removedBytes == first.sizeBytes)

        await trasher.resume(id: call2.id)
        await batch1Task?.value

        #expect(store.operation == .idle)
        #expect(!store.operation.isDeleting)
        #expect(store.operation.deletionProgress == nil)
        #expect(store.inventory.items(in: .derivedData).map(\.id) == [third.id])
        #expect(store.inventory.totalBytes == third.sizeBytes)
        #expect(store.lastDeletionReport?.deletedCount == 2)

        // Batch 2: verify a subsequent batch runs cleanly with no leftover progress state.
        store.requestDelete(items: [third])
        let batch2 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let batch2Task = store.startDeletion(batch2)

        let call3 = try await trasher.nextPendingCall()
        #expect(call3.url == thirdURL)
        #expect(store.operation.isDeleting)
        #expect(store.operation.deletionProgress?.totalCount == 1)
        await trasher.resume(id: call3.id)

        await batch2Task?.value
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).isEmpty)
        #expect(store.inventory.totalBytes == 0)
        #expect(store.lastDeletionReport?.deletedCount == 1)
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
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        // Given: an initial scan parked on its simctl commands
        let refreshTask = Task { await store.refreshIfNeeded() }
        for _ in 0 ..< scanSimctlListCallCount {
            _ = try await controller.nextPendingCall()
        }

        // When
        refreshTask.cancel()
        await refreshTask.value

        // Then: deterministic teardown guarantees no stray updates, no error, and unscanned state
        #expect(store.inventory.scannedAt == nil)
        #expect(!store.hasCompletedScan)
        #expect(store.inventory.categoryMetrics.allSatisfy { $0.failure == nil })
        #expect(store.operation == .idle)
    }

    @Test(
        "Strictly enforces mutual exclusion: delete is blocked while scanning, and scan is blocked while deleting",
        .timeLimit(.minutes(1))
    )
    func mutualExclusionBlocksOverlappingScanAndDelete() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let trasher = ControllableFileTrasher(removingUnder: fixture.rootURL)
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
        let firstScan = store.startRefresh()
        try await answerSimctl(controller)
        await firstScan?.value
        let target = try #require(store.inventory.items(in: .derivedData).first)

        // 1. Start a rescan and park it in simctl; deletion must be completely rejected.
        let rescan = store.startRefresh()
        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()

        #expect(store.operation.isScanning)
        #expect(store.operation.isBusy)
        store.requestDelete(items: [target])
        #expect(store.pendingDeletion == nil)
        #expect(store.startDeletion(DeletionPlan(selection: [target])) == nil)
        #expect(await trasher.trashedURLs.isEmpty)

        store.cancelOperation()
        await rescan?.value
        #expect(store.operation == .idle)

        // 2. Start a deletion and park it in FileTrashing; refresh must be rejected.
        store.requestDelete(items: [target])
        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        let deleteTask = store.startDeletion(pending)
        let trashCall = try await trasher.nextPendingCall()

        #expect(store.operation.isDeleting)
        #expect(store.operation.isBusy)
        #expect(store.startRefresh() == nil) // must no-op immediately while deleting
        #expect(await !controller.hasParkedCall)

        await trasher.resume(id: trashCall.id)
        // The deletion's rescan runs next.
        try await answerSimctl(controller)
        await deleteTask?.value
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).isEmpty)
    }

    /// Verifies the store reports idle, not scanning, once a scan finishes.
    /// To replicate: open Overview → press ⌘R → "Scanning…" changes to the scanned item count.
    @Test("Scanning state clears after a completed scan")
    func refresh_afterCompletion_isNotScanning() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }

        #expect(!store.operation.isScanning)
        #expect(store.operation == .idle)
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

    /// Verifies "Review Recommended" lands on the category with Recommended applied, no stale search, and reclaimable
    /// items
    /// selected.
    /// To replicate: in Simulator Devices type a search → go to Overview → click "Review N Recommended" on DerivedData.
    @Test("Opening a category for cleanup applies Recommended and selects reclaimable items")
    func openCategoryAndSelectReclaimable_fromAnotherCategory_appliesReclaimableFilterAndSelects() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        store.navigate(to: .category(.simulatorDevices))
        store.searchText = "iPhone"

        store.openCategoryAndSelectReclaimable(.derivedData)

        let reclaimableItems = store.inventory.items(in: .derivedData).filter(\.isReclaimable)
        #expect(!reclaimableItems.isEmpty)
        #expect(store.sidebarSelection == .category(.derivedData))
        #expect(store.statusFilter == .reclaimable)
        #expect(store.searchText.isEmpty)
        #expect(store.selectedItemIDs == Set(reclaimableItems.map(\.id)))
    }

    @Test(
        "startRefresh owns the scan task, ignores overlapping starts, and cancelOperation restores the last completed scan",
        .timeLimit(.minutes(1))
    )
    func startRefreshAndCancelOperationRestoresLastScanAndAllowsRetry() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        try fixture.addDerivedData(
            folderName: "Kept-1",
            workspacePath: "/nonexistent/Kept.xcodeproj",
            lastAccessed: Date.distantPast
        )

        // Seed one completed scan with one category failure.
        let initialScan = store.startRefresh()
        for _ in 0 ..< scanSimctlListCallCount {
            let call = try await controller.nextPendingCall()
            if call.arguments.contains("devices") {
                await controller.resume(id: call.id, with: .success(
                    CommandOutput(stdout: Data(#"{"devices":{}}"#.utf8), stderr: Data(), terminationStatus: 0)
                ))
            } else {
                await controller.resume(id: call.id, with: .failure(TestTrashError(message: "runtime list failed")))
            }
        }
        await initialScan?.value
        // Equality covers the failures too, so the restore below brings back the runtime failure.
        let completedInventory = store.inventory
        #expect(completedInventory.scanFailure(in: .simulatorRuntimes) != nil)

        // Add another folder, start a rescan via startRefresh, and cancel via cancelOperation.
        try fixture.addDerivedData(
            folderName: "Added-2",
            workspacePath: "/nonexistent/Added.xcodeproj",
            lastAccessed: Date.distantPast
        )

        store.startRefresh()
        #expect(store.operation.isScanning)
        #expect(store.operation.isBusy)

        // Overlapping startRefresh while busy must be ignored.
        store.startRefresh()

        var rescanCalls: [ParkedCall<[String]>] = []
        for _ in 0 ..< scanSimctlListCallCount {
            try await rescanCalls.append(controller.nextPendingCall())
        }
        try await waitUntil("rescan reported new DerivedData") {
            await store.inventory.items(in: .derivedData).count == 2
        }
        // Runtimes is still parked, so its failure from the last scan must not show beside "Scanning…".
        #expect(store.inventory.scanFailure(in: .simulatorRuntimes) == nil)

        store.cancelOperation()

        for call in rescanCalls {
            try await controller.waitForCancellation(id: call.id)
        }
        try await waitUntil("store returns to idle after cancelOperation") {
            await store.operation == .idle
        }

        #expect(store.inventory == completedInventory)
        #expect(await controller.recordedArguments.count == 2 * scanSimctlListCallCount)

        // A follow-up refresh after cancellation completes cleanly and picks up Added-2.
        let followUp = store.startRefresh()
        try await answerSimctl(controller)
        await followUp?.value
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).count == 2)
    }

    @Test(
        "cancelOperation stops an initial refreshIfNeeded scan and leaves the store unscanned",
        .timeLimit(.minutes(1))
    )
    func cancelOperationStopsInitialRefreshIfNeeded() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        let initialTask = Task { await store.refreshIfNeeded() }
        let call1 = try await controller.nextPendingCall()
        let call2 = try await controller.nextPendingCall()

        store.cancelOperation()
        await initialTask.value

        try await controller.waitForCancellation(id: call1.id)
        try await controller.waitForCancellation(id: call2.id)
        #expect(store.operation == .idle)
        #expect(!store.hasCompletedScan)
    }

    @Test(
        "startDeletion owns the deletion task, and cancelOperation stops mid-batch and reports what was removed",
        .timeLimit(.minutes(1))
    )
    func startDeletionAndCancelOperationStopsMidBatch() async throws {
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

        let trasher = ControllableFileTrasher(removingUnder: fixture.rootURL)
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        await store.startRefresh()?.value
        let first = try #require(store.inventory.items(in: .derivedData).first { $0.path == firstURL })
        let second = try #require(store.inventory.items(in: .derivedData).first { $0.path == secondURL })
        let third = try #require(store.inventory.items(in: .derivedData).first { $0.path == thirdURL })

        store.requestDelete(items: [first, second, third])
        let pending = try #require(store.pendingDeletion)

        store.startDeletion(pending)
        #expect(store.pendingDeletion == nil)
        #expect(store.operation.isDeleting)

        let call1 = try await trasher.nextPendingCall()
        #expect(call1.url == firstURL)
        await trasher.resume(id: call1.id)

        let call2 = try await trasher.nextPendingCall()
        #expect(call2.url == secondURL)

        store.cancelOperation()

        try await trasher.waitForCancellation(id: call2.id)
        try await waitUntil("deletion returns to idle after cancelOperation") {
            await store.operation == .idle
        }

        let report = try #require(store.lastDeletionReport)
        #expect(report.wasCancelled)
        #expect(report.deletedCount == 1)
        #expect(report.failures.isEmpty)
        #expect(await trasher.trashedURLs == [firstURL])
        #expect(Set(store.inventory.items(in: .derivedData).map(\.id)) == [second.id, third.id])
    }

    @Test("cancelOperation is a safe no-op when idle")
    func cancelOperationWhenIdleIsNoOp() async throws {
        let (store, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }

        store.cancelOperation()

        #expect(store.operation == .idle)
    }

    @Test("Rows hidden by search or filter are never part of the selection plan")
    func hiddenSelectedRowsAreExcludedFromDeletion() async throws {
        let (store, fixture) = try await makeScannedStore(extraDerivedDataFolders: ["OtherApp-new"])
        defer { fixture.cleanup() }

        // Given: both DerivedData rows selected
        store.navigate(to: .category(.derivedData))
        store.selectAllDeletableInActiveCategory()
        #expect(store.selectedItemIDs.count == 2)
        let originalIDs = store.selectedItemIDs

        // When: a search hides one of them
        store.searchText = "SampleApp"

        // Then: only the visible row is acted on
        let visibleIDs = store.visibleItems(for: .derivedData).map(\.id)
        #expect(visibleIDs.count == 1)
        #expect(store.selectedItems.map(\.id) == visibleIDs)
        #expect(store.selectionPlan.deletableItems.map(\.id) == visibleIDs)
        store.requestDeleteSelected()
        #expect(store.pendingDeletion?.deletableItems.map(\.id) == visibleIDs)

        // A status filter hiding every selected row leaves nothing to delete.
        store.searchText = ""
        store.statusFilter = .worktree
        #expect(store.selectedItems.isEmpty)
        #expect(store.selectionPlan.isEmpty)

        // Clearing the filter brings the hidden rows back, still selected.
        store.statusFilter = .all
        #expect(Set(store.selectedItems.map(\.id)) == originalIDs)
    }

    /// Stop can't let the next operation in while the stopped one is still tearing down, such as a
    /// cancelled simctl child that hasn't exited yet.
    @Test("Stays busy until a stopped scan finishes tearing down", .timeLimit(.minutes(1)))
    func stoppedScanBlocksNewOperationsUntilTeardownEnds() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let runner = SlowExitCommandRunner()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        ))
        let target = makeStorageItem(id: "dd", method: .trashFile(fixture.rootURL.appendingPathComponent("dd")))

        // Given: a scan whose three simctl list commands are all in flight
        let scan = store.startRefresh()
        try await waitUntil("simctl list commands started") { await runner.startedCount == scanSimctlListCallCount }

        // When: Stop is pressed but the commands haven't exited yet
        store.cancelOperation()

        // Then: nothing new can start until they do
        #expect(store.operation.isScanning)
        #expect(store.startRefresh() == nil)
        #expect(store.startDeletion(DeletionPlan(selection: [target])) == nil)

        await runner.finishExiting()
        let result = try await awaitResult(of: Task { await scan?.value }, within: .seconds(10))
        _ = try result.get()
        #expect(store.operation == .idle)
        #expect(store.startRefresh() != nil)
    }

    @Test("Stays busy until a cancelled deletion's simctl command has exited", .timeLimit(.minutes(1)))
    func cancelledDeletionBlocksNewOperationsUntilTeardownEnds() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let runner = SlowExitCommandRunner()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        ))
        let device = makeStorageItem(
            id: "sim",
            category: .simulatorDevices,
            method: .simctlDevice(udid: "UDID-1")
        )

        // Given: a deletion whose simctl delete is in flight
        let deletion = store.startDeletion(DeletionPlan(selection: [device]))
        try await waitUntil("simctl delete started") { await runner.startedCount == 1 }
        #expect(await runner.parkedArguments == [["simctl", "delete", "UDID-1"]])

        // When
        store.cancelOperation()

        // Then
        #expect(store.operation.isDeleting)
        #expect(store.startRefresh() == nil)
        #expect(store.startDeletion(DeletionPlan(selection: [device])) == nil)

        await runner.finishExiting()
        let result = try await awaitResult(of: Task { await deletion?.value }, within: .seconds(10))
        _ = try result.get()
        #expect(store.operation == .idle)
        #expect(store.lastDeletionReport == nil)
    }

    @Test(
        "An operation started on a store that is then released never runs",
        .timeLimit(.minutes(1)),
        arguments: StoreOperation.allCases
    )
    func releasedStoreBeforeTaskEntryRunsNothing(operation: StoreOperation) async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let runner = SlowExitCommandRunner()
        weak var weakStore: XcodeSweepStore?
        var task: Task<Void, Never>?
        do {
            let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
                xcodeRootURL: fixture.xcodeRootURL,
                commandRunner: runner,
                fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
            ))
            weakStore = store
            // The task can't start until this test suspends, so the store goes first.
            task = operation.start(on: store)
        }

        #expect(task != nil)
        #expect(weakStore == nil)
        let result = try await awaitResult(of: Task { await task?.value }, within: .seconds(10))
        _ = try result.get()
        #expect(await runner.startedCount == 0)
    }

    @Test(
        "A cancelled operation does not keep its store alive once teardown ends",
        .timeLimit(.minutes(1)),
        arguments: StoreOperation.allCases
    )
    func cancelledOperationReleasesStore(operation: StoreOperation) async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let runner = SlowExitCommandRunner()
        weak var weakStore: XcodeSweepStore?
        var task: Task<Void, Never>?
        do {
            let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
                xcodeRootURL: fixture.xcodeRootURL,
                commandRunner: runner,
                fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
            ))
            weakStore = store
            task = operation.start(on: store)
            try await waitUntil("commands started") { await runner.startedCount == operation.commandCount }
            store.cancelOperation()
        }

        await runner.finishExiting()
        let result = try await awaitResult(of: Task { await task?.value }, within: .seconds(10))
        _ = try result.get()
        task = nil
        // Releases happen as the task's frames unwind, so poll briefly instead of asserting at once.
        for _ in 0 ..< 100 where weakStore != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(weakStore == nil)
    }

    /// To replicate: delete several items where an early one fails → press Cancel → the alert
    /// still lists that failure.
    @Test("A cancelled deletion still reports the failures recorded before the cancel", .timeLimit(.minutes(1)))
    func cancelledDeletionKeepsEarlierFailures() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let failingURL = try fixture.addDerivedData(folderName: "Fails-1", workspacePath: "/nonexistent/Fails.xcodeproj", lastAccessed: now)
        let parkedURL = try fixture.addDerivedData(folderName: "Parked-2", workspacePath: "/nonexistent/Parked.xcodeproj", lastAccessed: now)
        let trasher = ControllableFileTrasher(removingUnder: fixture.rootURL)
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        ))
        await store.startRefresh()?.value
        let items = store.inventory.items(in: .derivedData)
        let failing = try #require(items.first { $0.path == failingURL })
        let parked = try #require(items.first { $0.path == parkedURL })

        // Given: the first item fails and the second is in flight
        let deletion = store.startDeletion(DeletionPlan(selection: [failing, parked]))
        let first = try await trasher.nextPendingCall()
        await trasher.resume(id: first.id, with: .failure(TestTrashError(message: "Item is locked")))
        let second = try await trasher.nextPendingCall()
        #expect(second.url == parkedURL)

        // When
        store.cancelOperation()
        _ = try await awaitResult(of: Task { await deletion?.value }, within: .seconds(10)).get()

        // Then
        let report = try #require(store.lastDeletionReport)
        #expect(report.wasCancelled)
        #expect(report.deletedCount == 0)
        #expect(report.failures.map(\.itemID) == [failing.id])
        #expect(report.summary.contains("Item is locked"))
    }

    /// ADR 0001: a cancelled simctl delete may have taken effect. The rescan that follows every
    /// deletion, except one stopped to quit, settles it, so the inventory shows what is really on disk.
    @Test("Rescans after a cancelled simctl delete so a device it removed disappears", .timeLimit(.minutes(1)))
    func rescanAfterCancelledDeleteDropsRemovedDevice() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let runner = DeleteTakesEffectThenParksRunner(udid: "GONE-1")
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        ))
        await store.startRefresh()?.value
        let device = try #require(store.inventory.items(in: .simulatorDevices).first)

        // Given: simctl delete removed the device, but its result hasn't come back
        let deletion = store.startDeletion(DeletionPlan(selection: [device]))
        try await waitUntil("simctl delete in flight") { await runner.deleteInFlight }

        // When
        store.cancelOperation()
        _ = try await awaitResult(of: Task { await deletion?.value }, within: .seconds(10)).get()

        // Then: the rescan, not the cancelled delete, removed it from the inventory
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .simulatorDevices).isEmpty)
        #expect(store.lastDeletionReport == nil)
    }

    @Test("Stays busy from deletion through its rescan, and Stop ends the rescan", .timeLimit(.minutes(1)))
    func stopDuringPostDeletionRescanKeepsPostDeletionInventory() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let goneURL = try fixture.addDerivedData(folderName: "Gone-1", workspacePath: "/nonexistent/Gone.xcodeproj", lastAccessed: now)
        let keptURL = try fixture.addDerivedData(folderName: "Kept-2", workspacePath: "/nonexistent/Kept.xcodeproj", lastAccessed: now)
        let controller = ControllableCommandRunner()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL),
            now: { now }
        ))
        let initialScan = store.startRefresh()
        try await answerSimctl(controller)
        await initialScan?.value
        let gone = try #require(store.inventory.items(in: .derivedData).first { $0.path == goneURL })

        // Given: the deletion finished and its rescan is parked on simctl
        let history = OperationHistory(store)
        let deletion = store.startDeletion(DeletionPlan(selection: [gone]))
        let call1 = try await controller.nextPendingCall()
        let call2 = try await controller.nextPendingCall()
        #expect(store.operation.isScanning)
        #expect(store.lastDeletionReport?.deletedCount == 1)

        // The store went from deleting to scanning without passing through idle.
        let values = history.values + [store.operation]
        let deletingAt = try #require(values.firstIndex { $0.isDeleting })
        let scanningAt = try #require(values[deletingAt...].firstIndex { $0.isScanning })
        #expect(!values[deletingAt ..< scanningAt].contains(.idle), "Operation history: \(values)")

        // When
        store.cancelOperation()
        let cancelled = Task {
            try await controller.waitForCancellation(id: call1.id)
            try await controller.waitForCancellation(id: call2.id)
        }
        defer { cancelled.cancel() }
        _ = try await awaitResult(of: cancelled, within: .seconds(10)).get()
        _ = try await awaitResult(of: Task { await deletion?.value }, within: .seconds(10)).get()

        // Then: the rescan stopped; the acknowledged removal and the report stay
        #expect(store.operation == .idle)
        #expect(store.inventory.items(in: .derivedData).map(\.path) == [keptURL])
        #expect(store.lastDeletionReport?.deletedCount == 1)
    }

    /// A category that failed must say so as soon as its result arrives, not when the slowest category ends.
    @Test("A category's failure is shown while the rest of the scan is still running", .timeLimit(.minutes(1)))
    func categoryFailureAppearsBeforeScanEnds() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let controller = ControllableCommandRunner()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL)
        ))

        let scan = store.startRefresh()
        var parked: [ParkedCall<[String]>] = []
        for _ in 0 ..< scanSimctlListCallCount {
            try await parked.append(controller.nextPendingCall())
        }
        let devices = try #require(parked.first { $0.arguments == ["simctl", "list", "devices", "-j"] })
        await controller.resume(id: devices.id, with: .failure(TestTrashError(message: "simctl unavailable")))

        try await waitUntil("device failure shown") { await store.inventory.scanFailure(in: .simulatorDevices) != nil }
        #expect(store.operation.isScanning)

        for call in parked where call.id != devices.id {
            let json = call.arguments.contains("devices") ? #"{"devices":{}}"# : "{}"
            await controller.resume(id: call.id, with: .success(
                CommandOutput(stdout: Data(json.utf8), stderr: Data(), terminationStatus: 0)
            ))
        }
        _ = try await awaitResult(of: Task { await scan?.value }, within: .seconds(10)).get()
        #expect(store.inventory.scanFailure(in: .simulatorDevices) == "simctl unavailable")
    }

    private func makeScannedStore(
        extraDerivedDataFolders: [String] = []
    ) async throws -> (XcodeSweepStore, TempXcodeFixture) {
        let fixture = try TempXcodeFixture()
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        for folderName in ["SampleApp-old"] + extraDerivedDataFolders {
            _ = try fixture.addDerivedData(
                folderName: folderName,
                workspacePath: "/nonexistent/\(folderName).xcodeproj",
                lastAccessed: now
            )
        }
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL),
            now: { now }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        await store.startRefresh()?.value
        return (store, fixture)
    }

    private func answerSimctl(_ controller: ControllableCommandRunner) async throws {
        for _ in 0 ..< scanSimctlListCallCount {
            let call = try await controller.nextPendingCall()
            let json = call.arguments.contains("devices") ? #"{"devices":{}}"# : "{}"
            await controller.resume(id: call.id, with: .success(
                CommandOutput(stdout: Data(json.utf8), stderr: Data(), terminationStatus: 0)
            ))
        }
    }
}

/// The two operations the store runs, for tests that must cover both task paths.
enum StoreOperation: CaseIterable, Sendable {
    case scan
    case simctlDeletion

    /// Commands parked before cancellation: the scan's list commands, or the device's delete.
    var commandCount: Int {
        switch self {
        case .scan: scanSimctlListCallCount
        case .simctlDeletion: 1
        }
    }

    @MainActor
    func start(on store: XcodeSweepStore) -> Task<Void, Never>? {
        switch self {
        case .scan:
            store.startRefresh()
        case .simctlDeletion:
            store.startDeletion(DeletionPlan(selection: [makeStorageItem(
                id: "sim",
                category: .simulatorDevices,
                method: .simctlDevice(udid: "UDID-1")
            )]))
        }
    }
}

/// Lists one device until `simctl delete` runs; the delete removes it, then stays in flight until
/// cancelled, as a delete that took effect before its result reached Swift.
private actor DeleteTakesEffectThenParksRunner: CommandRunning {
    let udid: String
    private(set) var deleteInFlight = false
    private var deleted = false

    init(udid: String) {
        self.udid = udid
    }

    func run(executableURL _: URL, arguments: [String], timeout _: Duration?) async throws -> CommandOutput {
        switch arguments {
        case ["simctl", "list", "devices", "-j"]:
            let devices = deleted ? "" : #"{"udid":"\#(udid)","isAvailable":true,"state":"Shutdown","name":"iPhone 17"}"#
            let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[\#(devices)]}}"#
            return CommandOutput(stdout: Data(json.utf8), stderr: Data(), terminationStatus: 0)
        case ["simctl", "delete", udid]:
            deleted = true
            deleteInFlight = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        default:
            return CommandOutput(stdout: Data(#"{}"#.utf8), stderr: Data(), terminationStatus: 0)
        }
    }
}

/// Every value `store.operation` held, in order. Observation calls back just before each write,
/// so reading the property there captures the value being replaced, even one held for no time.
@MainActor
private final class OperationHistory {
    private(set) var values: [OperationState] = []
    private let store: XcodeSweepStore

    init(_ store: XcodeSweepStore) {
        self.store = store
        track()
    }

    private func track() {
        withObservationTracking {
            _ = self.store.operation
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.values.append(self.store.operation)
                self.track()
            }
        }
    }
}