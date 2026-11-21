import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeSweepStore")
@MainActor
struct XcodeSweepStoreTests {
    @Test("Aggregates category metrics and selects reclaimable items for deletion")
    func scanFilterSelectAndDelete() async {
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
        #expect(store.pendingDeletion?.items.map(\.id) == ["d1"])

        await store.confirmPendingDeletion()

        #expect(store.items(for: .derivedData).map(\.id) == ["d2"])
        #expect(store.summary.totalBytes == 5_000_000_000)
        #expect(store.lastDeletionReport?.deletedCount == 1)
        #expect(store.lastDeletionReport?.reclaimedBytes == 1_000_000_000)
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
            lastUsedDate: Date(),
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
    func delete(
        items: [StorageItem],
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async -> DeletionReport {
        var bytes: Int64 = 0
        for (index, item) in items.enumerated() {
            onProgress(index + 1, items.count, item.name)
            bytes += item.sizeBytes
        }
        return DeletionReport(
            deletedCount: items.count,
            trashedCount: items.filter { !$0.deletionMethod.isPermanent }.count,
            simctlDeletedCount: items.filter { $0.deletionMethod.isPermanent }.count,
            reclaimedBytes: bytes,
            failures: []
        )
    }
}
