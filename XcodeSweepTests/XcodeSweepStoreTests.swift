import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeSweepStore")
@MainActor
struct XcodeSweepStoreTests {
    @Test("Aggregates category metrics and selects reclaimable items for deletion")
    func scanFilterSelectAndDelete() async throws {
        let orphaned = makeItem(
            id: "d1",
            category: .derivedData,
            name: "SampleApp-old",
            size: 1_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/d1"))
        )
        let active = makeItem(
            id: "d2",
            category: .derivedData,
            name: "SampleApp-main",
            size: 2_000_000_000,
            status: .active,
            method: .trashFile(URL(fileURLWithPath: "/tmp/d2"))
        )
        let unavailableSim = makeItem(
            id: "s1",
            category: .simulatorDevices,
            name: "iPhone 15",
            size: 3_000_000_000,
            status: .unavailable,
            method: .simctlDevice(udid: "SIM-1", isBooted: false)
        )

        let scanner = MockScanner(
            snapshot: ScanSnapshot(
                itemsByCategory: [
                    .derivedData: [active, orphaned],
                    .simulatorDevices: [unavailableSim],
                ],
                diskAvailableBytes: 500_000_000_000,
                diskTotalBytes: 1_000_000_000_000,
                warnings: []
            )
        )
        let deleter = MockDeleter()
        let store = XcodeSweepStore(scanner: scanner, deleter: deleter)

        await store.refresh()

        #expect(store.summary.totalBytes == 6_000_000_000)
        #expect(store.summary.reclaimableBytes == 4_000_000_000)
        #expect(store.summary.reclaimableItemCount == 2)

        store.openCategoryAndSelectReclaimable(.derivedData)
        #expect(store.sidebarSelection == .category(.derivedData))
        #expect(store.statusFilter == .reclaimable)
        #expect(store.selectedItemIDs == ["d1"])
        #expect(store.selectedTotalBytes == 1_000_000_000)

        store.requestDeleteSelected()
        let pending = try #require(store.pendingDeletion)
        #expect(pending.items.map(\.id) == ["d1"])

        // Simulate SwiftUI `.confirmationDialog(item:)` clearing the binding before the button's Task runs.
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(store.items(for: .derivedData).map(\.id) == ["d2"])
        #expect(store.summary.totalBytes == 5_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.reclaimedBytes == 1_000_000_000)
        #expect(store.deletionProgress == nil)
    }

    @Test("Removes only succeeded item IDs when duplicate names share a failure")
    func removesByIDNotNameWhenDuplicateNamesExist() async throws {
        let first = makeItem(
            id: "dup-1",
            category: .derivedData,
            name: "SampleApp",
            size: 1_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/dup-1"))
        )
        let second = makeItem(
            id: "dup-2",
            category: .derivedData,
            name: "SampleApp",
            size: 2_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/dup-2"))
        )

        let scanner = MockScanner(
            snapshot: ScanSnapshot(
                itemsByCategory: [.derivedData: [first, second]],
                diskAvailableBytes: 500_000_000_000,
                diskTotalBytes: 1_000_000_000_000,
                warnings: []
            )
        )
        let deleter = MockDeleter(failingIDs: ["dup-2"])
        let store = XcodeSweepStore(scanner: scanner, deleter: deleter)

        await store.refresh()
        store.openCategoryAndSelectReclaimable(.derivedData)
        store.requestDeleteSelected()

        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil
        await store.confirmDeletion(pending)

        #expect(store.items(for: .derivedData).map(\.id) == ["dup-2"])
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.failures.map(\.itemID) == ["dup-2"])
    }

    @Test(
        "Updates items and totals live while a batch is suspended, clears state on completion, and handles a follow-up batch",
        .timeLimit(.minutes(1))
    )
    func liveProgressUpdatesDuringSuspendedBatchAndClearsOnCompletion() async throws {
        let first = makeItem(
            id: "b1",
            category: .derivedData,
            name: "First",
            size: 1_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/b1"))
        )
        let second = makeItem(
            id: "b2",
            category: .derivedData,
            name: "Second",
            size: 2_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/b2"))
        )
        let third = makeItem(
            id: "b3",
            category: .derivedData,
            name: "Third",
            size: 3_000_000_000,
            status: .stale,
            method: .trashFile(URL(fileURLWithPath: "/tmp/b3"))
        )

        let scanner = MockScanner(
            snapshot: ScanSnapshot(
                itemsByCategory: [.derivedData: [first, second, third]],
                diskAvailableBytes: 500_000_000_000,
                diskTotalBytes: 1_000_000_000_000,
                warnings: []
            )
        )
        let deleter = SuspendingDeleter()
        let store = XcodeSweepStore(scanner: scanner, deleter: deleter)

        await store.refresh()
        #expect(store.summary.totalBytes == 6_000_000_000)

        // Batch 1: delete first and second, suspending between them.
        store.requestDelete(items: [first, second])
        let batch1 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch1Done: Void = store.confirmDeletion(batch1)

        // Wait until item 1 is paused in flight.
        let gate1 = try await deleter.nextItemGate()
        #expect(gate1.itemID == "b1")
        #expect(store.isDeleting)
        #expect(store.deletionProgress?.completedCount == 0)
        #expect(store.deletionProgress?.totalCount == 2)

        // Release item 1; pause when item 2 begins.
        await deleter.releaseGate(id: gate1.id)
        let gate2 = try await deleter.nextItemGate()
        #expect(gate2.itemID == "b2")

        // Item 1 must already be removed live and summary totals decremented before batch 1 completes.
        #expect(store.isDeleting)
        #expect(store.items(for: .derivedData).map(\.id) == ["b2", "b3"])
        #expect(store.summary.totalBytes == 5_000_000_000)
        #expect(store.deletionProgress?.completedCount == 1)
        #expect(store.deletionProgress?.removedBytes == 1_000_000_000)

        // Release item 2 and wait for batch 1 completion.
        await deleter.releaseGate(id: gate2.id)
        await batch1Done

        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == ["b3"])
        #expect(store.summary.totalBytes == 3_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 2)

        // Batch 2: verify a subsequent batch runs cleanly with no leftover progress state.
        store.requestDelete(items: [third])
        let batch2 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch2Done: Void = store.confirmDeletion(batch2)

        let gate3 = try await deleter.nextItemGate()
        #expect(gate3.itemID == "b3")
        #expect(store.isDeleting)
        #expect(store.deletionProgress?.totalCount == 1)
        await deleter.releaseGate(id: gate3.id)

        await batch2Done
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).isEmpty)
        #expect(store.summary.totalBytes == 0)
        #expect(store.lastDeletionReport?.deletedCount == 1)
    }

    @Test(
        "Rejects late progress callbacks from a completed batch when idle and during a subsequent batch",
        .timeLimit(.minutes(1))
    )
    func rejectsStaleProgressFromExpiredBatch() async throws {
        let first = makeItem(
            id: "e1",
            category: .derivedData,
            name: "First",
            size: 1_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/e1"))
        )
        let second = makeItem(
            id: "e2",
            category: .derivedData,
            name: "Second",
            size: 2_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/e2"))
        )

        let scanner = MockScanner(
            snapshot: ScanSnapshot(
                itemsByCategory: [.derivedData: [first, second]],
                diskAvailableBytes: 500_000_000_000,
                diskTotalBytes: 1_000_000_000_000,
                warnings: []
            )
        )
        let deleter = SuspendingDeleter(retainsCallbacks: true)
        let store = XcodeSweepStore(scanner: scanner, deleter: deleter)

        await store.refresh()
        store.sidebarSelection = .category(.derivedData)
        store.selectedItemIDs = ["e1", "e2"]

        // Complete batch 1 for `first`.
        store.requestDelete(items: [first])
        let batch1 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch1Done: Void = store.confirmDeletion(batch1)

        let gate1 = try await deleter.nextItemGate()
        await deleter.releaseGate(id: gate1.id)
        await batch1Done

        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == ["e2"])
        #expect(store.selectedItemIDs == ["e2"])

        // Invoke batch 1's retained callback after completion while store is idle.
        let staleUpdate = DeletionProgress(
            completedCount: 1,
            totalCount: 1,
            currentItemName: "Stale",
            removedBytes: 1_000_000_000,
            removedItemID: "e2"
        )
        await deleter.fireRetainedCallback(at: 0, progress: staleUpdate)

        // Store must ignore the stale callback: remain idle, keep `e2`, and preserve selection.
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == ["e2"])
        #expect(store.selectedItemIDs == ["e2"])

        // Start batch 2 for `second` and pause it in flight.
        store.requestDelete(items: [second])
        let batch2 = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        async let batch2Done: Void = store.confirmDeletion(batch2)

        let gate2 = try await deleter.nextItemGate()
        #expect(gate2.itemID == "e2")

        let expectedBatch2Progress = store.deletionProgress
        // Invoke batch 1's retained callback while batch 2 is active.
        await deleter.fireRetainedCallback(at: 0, progress: staleUpdate)

        // Batch 2's progress, rows, and selection must stay intact.
        #expect(store.deletionProgress == expectedBatch2Progress)
        #expect(store.items(for: .derivedData).map(\.id) == ["e2"])
        #expect(store.selectedItemIDs == ["e2"])

        await deleter.releaseGate(id: gate2.id)
        await batch2Done
        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).isEmpty)
    }

    @Test(
        "Cancelling an already-registered gate waiter exits immediately instead of hanging",
        .timeLimit(.minutes(1))
    )
    func cancelledRegisteredGateWaiterExitsImmediately() async throws {
        let deleter = SuspendingDeleter()
        let waiterTask = Task {
            try await deleter.nextItemGate()
        }
        defer { waiterTask.cancel() }

        // Wait (with cancellation + deadline) until the waiter is registered and parked before cancelling.
        try await waitUntil("gate waiter registered") {
            await deleter.hasRegisteredWaiter
        }
        waiterTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiterTask.value
        }
    }

    @Test(
        "Cancelling while awaiting a structured store batch parked on an unexpected gate exits immediately",
        .timeLimit(.minutes(1))
    )
    func cancelledStructuredStoreBatchOnUnexpectedGateExitsImmediately() async throws {
        let item = makeItem(
            id: "hang-1",
            category: .derivedData,
            name: "Parked",
            size: 1_000_000_000,
            status: .orphaned,
            method: .trashFile(URL(fileURLWithPath: "/tmp/hang-1"))
        )
        let scanner = MockScanner(
            snapshot: ScanSnapshot(
                itemsByCategory: [.derivedData: [item]],
                diskAvailableBytes: 500_000_000_000,
                diskTotalBytes: 1_000_000_000_000,
                warnings: []
            )
        )
        let deleter = SuspendingDeleter()
        let store = XcodeSweepStore(scanner: scanner, deleter: deleter)

        await store.refresh()
        store.requestDelete(items: [item])
        let pending = try #require(store.pendingDeletion)
        store.pendingDeletion = nil

        // Outer task simulates awaiting `async let batchDone` when an unexpected gate parks the worker.
        let outerTask = Task { @MainActor in
            async let batchDone: Void = store.confirmDeletion(pending)
            await batchDone
        }
        defer { outerTask.cancel() }

        try await waitUntil("store batch parked at gate") {
            await deleter.hasParkedGate
        }
        outerTask.cancel()
        await withTaskCancellationHandler {
            await outerTask.value
        } onCancel: {
            outerTask.cancel()
        }

        #expect(!store.isDeleting)
        #expect(store.deletionProgress == nil)
        #expect(store.items(for: .derivedData).map(\.id) == ["hang-1"])
    }

    // MARK: - Test Doubles

    private func makeItem(
        id: String,
        category: StorageCategory,
        name: String,
        size: Int64,
        status: ItemStatus,
        method: DeletionMethod
    ) -> StorageItem {
        StorageItem(
            id: id,
            category: category,
            name: name,
            subtitle: "Subtitle",
            sizeBytes: size,
            lastUsedDate: Date(timeIntervalSince1970: 1_700_000_000),
            path: URL(fileURLWithPath: "/tmp/\(id)"),
            workspacePath: nil,
            status: status,
            deletionMethod: method,
            metadata: []
        )
    }
}

private struct MockScanner: StorageScanning {
    let snapshot: ScanSnapshot

    func scanAll(
        onProgress: @escaping @Sendable (StorageCategory, [StorageItem]) -> Void
    ) async throws -> ScanSnapshot {
        for (category, items) in snapshot.itemsByCategory {
            onProgress(category, items)
        }
        return snapshot
    }
}

private struct MockDeleter: StorageDeleting {
    var failingIDs: Set<StorageItem.ID> = []

    func delete(
        items: [StorageItem],
        onProgress: @escaping @Sendable (DeletionProgress) async -> Void
    ) async -> DeletionReport {
        var bytes: Int64 = 0
        var removedIDs: Set<StorageItem.ID> = []
        var failures: [DeletionFailure] = []

        for (index, item) in items.enumerated() {
            if failingIDs.contains(item.id) {
                failures.append(DeletionFailure(itemID: item.id, itemName: item.name, reason: "Permission denied"))
                await onProgress(
                    DeletionProgress(
                        completedCount: index + 1,
                        totalCount: items.count,
                        currentItemName: item.name,
                        removedBytes: bytes,
                        removedItemID: nil
                    )
                )
            } else {
                bytes += item.sizeBytes
                removedIDs.insert(item.id)
                await onProgress(
                    DeletionProgress(
                        completedCount: index + 1,
                        totalCount: items.count,
                        currentItemName: item.name,
                        removedBytes: bytes,
                        removedItemID: item.id
                    )
                )
            }
        }

        let succeeded = items.filter { removedIDs.contains($0.id) }
        return DeletionReport(
            deletedCount: succeeded.count,
            trashedCount: succeeded.filter { !$0.deletionMethod.isPermanent }.count,
            simctlDeletedCount: succeeded.filter { $0.deletionMethod.isPermanent }.count,
            reclaimedBytes: bytes,
            removedItemIDs: removedIDs,
            failures: failures
        )
    }
}

private struct ItemGateHandle: Sendable {
    let id: UUID
    let itemID: StorageItem.ID
}

private struct StoreConditionTimeoutError: Error, CustomStringConvertible {
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
            throw StoreConditionTimeoutError(description: "Timed out waiting for: \(label)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor SuspendingDeleter: StorageDeleting {
    private let retainsCallbacks: Bool
    private var retainedCallbacks: [@Sendable (DeletionProgress) async -> Void] = []
    private var queuedGates: [ItemGateHandle] = []
    private var inFlightGates: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiters: [(id: UUID, continuation: CheckedContinuation<ItemGateHandle, any Error>)] = []

    var hasRegisteredWaiter: Bool {
        !waiters.isEmpty
    }

    var hasParkedGate: Bool {
        !inFlightGates.isEmpty
    }

    init(retainsCallbacks: Bool = false) {
        self.retainsCallbacks = retainsCallbacks
    }

    func delete(
        items: [StorageItem],
        onProgress: @escaping @Sendable (DeletionProgress) async -> Void
    ) async -> DeletionReport {
        if retainsCallbacks {
            retainedCallbacks.append(onProgress)
        }

        var bytes: Int64 = 0
        var removedIDs: Set<StorageItem.ID> = []

        for (index, item) in items.enumerated() {
            await onProgress(
                DeletionProgress(
                    completedCount: index,
                    totalCount: items.count,
                    currentItemName: item.name,
                    removedBytes: bytes,
                    removedItemID: nil
                )
            )

            do {
                try await pause(for: item.id)
            } catch {
                break
            }

            bytes += item.sizeBytes
            removedIDs.insert(item.id)
            await onProgress(
                DeletionProgress(
                    completedCount: index + 1,
                    totalCount: items.count,
                    currentItemName: item.name,
                    removedBytes: bytes,
                    removedItemID: item.id
                )
            )
        }

        let succeeded = items.filter { removedIDs.contains($0.id) }
        return DeletionReport(
            deletedCount: succeeded.count,
            trashedCount: succeeded.filter { !$0.deletionMethod.isPermanent }.count,
            simctlDeletedCount: succeeded.filter { $0.deletionMethod.isPermanent }.count,
            reclaimedBytes: bytes,
            removedItemIDs: removedIDs,
            failures: []
        )
    }

    func nextItemGate() async throws -> ItemGateHandle {
        if !queuedGates.isEmpty {
            return queuedGates.removeFirst()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !queuedGates.isEmpty {
                    continuation.resume(returning: queuedGates.removeFirst())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func releaseGate(id: UUID) {
        guard let continuation = inFlightGates.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    func fireRetainedCallback(at index: Int, progress: DeletionProgress) async {
        guard retainedCallbacks.indices.contains(index) else { return }
        await retainedCallbacks[index](progress)
    }

    private func pause(for itemID: StorageItem.ID) async throws {
        let gateID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightGates[gateID] = continuation
                let handle = ItemGateHandle(id: gateID, itemID: itemID)
                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.continuation.resume(returning: handle)
                } else {
                    queuedGates.append(handle)
                }
            }
        } onCancel: {
            Task { await self.cancelGate(id: gateID) }
        }
    }

    private func cancelGate(id: UUID) {
        queuedGates.removeAll { $0.id == id }
        guard let continuation = inFlightGates.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
