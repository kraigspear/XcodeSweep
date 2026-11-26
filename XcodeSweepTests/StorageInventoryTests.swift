import Foundation
import Testing
@testable import XcodeSweep

@Suite("StorageInventory")
struct StorageInventoryTests {
    private let scannedAt = testISO8601Date("2026-11-21T10:00:00Z")

    /// Verifies Overview totals include every item, and reclaimable totals only reclaimable items.
    /// To replicate: scan with an orphaned DerivedData folder, an active one, and a protected runtime → read the
    /// Overview cards.
    @Test("Totals and category metrics derive from items")
    func init_derivesTotalsAndCategoryMetrics() throws {
        // Given: Reclaimable, active, and protected-but-stale items across two categories
        let inventory = makeInventory([
            makeStorageItem(id: "orphan", sizeBytes: 100, status: .orphaned),
            makeStorageItem(id: "active", sizeBytes: 10, status: .active),
            makeStorageItem(
                id: "system",
                category: .simulatorRuntimes,
                sizeBytes: 1000,
                status: .stale,
                method: .notDeletable(reason: "System")
            ),
        ])

        // Then: Protected items count toward size but never toward reclaimable
        #expect(inventory.totalBytes == 1110)
        #expect(inventory.totalItemCount == 3)
        #expect(inventory.reclaimableBytes == 100)
        #expect(inventory.reclaimableItemCount == 1)
        #expect(inventory.categoryMetrics.map(\.category) == StorageCategory.allCases)

        let derivedData = try #require(inventory.categoryMetrics.first { $0.category == .derivedData })
        #expect(derivedData.itemCount == 2)
        #expect(derivedData.totalBytes == 110)
        #expect(derivedData.reclaimableCount == 1)
    }

    /// Verifies a deletion updates the item list and every total in one step.
    /// To replicate: trash an orphaned DerivedData folder → the sidebar size and Overview totals drop together.
    @Test("Removing items updates items and totals together")
    func removingItems_updatesItemsAndTotalsAtomically() {
        let inventory = makeInventory([
            makeStorageItem(id: "a", sizeBytes: 100, status: .orphaned),
            makeStorageItem(id: "b", sizeBytes: 10, status: .orphaned),
            makeStorageItem(id: "sim", category: .simulatorDevices, sizeBytes: 5, status: .unavailable),
        ])

        let updated = inventory.removingItems(withIDs: ["a", "sim"])

        #expect(updated.items(in: .derivedData).map(\.id) == ["b"])
        #expect(updated.items(in: .simulatorDevices).isEmpty)
        #expect(updated.item(withID: "a") == nil)
        let expected = makeInventory([makeStorageItem(id: "b", sizeBytes: 10, status: .orphaned)])
        #expect(updated.categoryMetrics == expected.categoryMetrics)
        #expect(updated.totalBytes == 10)
        #expect(updated.totalItemCount == 1)
        #expect(updated.reclaimableBytes == 10)
        #expect(updated.reclaimableItemCount == 1)
        #expect(updated.scannedAt == scannedAt)
        #expect(updated.volume == inventory.volume)
    }

    /// Verifies a category arriving mid-scan replaces only that category and keeps the last scan date.
    /// To replicate: press ⌘R → watch categories fill in one at a time while other sidebar sizes stay put.
    @Test("Replacing one category leaves the others and the scan date intact")
    func replacingItems_updatesOnlyThatCategory() {
        let inventory = makeInventory([
            makeStorageItem(id: "old", sizeBytes: 100),
            makeStorageItem(id: "sim", category: .simulatorDevices, sizeBytes: 5),
        ])

        let updated = inventory.replacingItems(in: .derivedData, with: [makeStorageItem(id: "new", sizeBytes: 7)], failure: nil)

        #expect(updated.items(in: .derivedData).map(\.id) == ["new"])
        #expect(updated.item(withID: "new") != nil)
        #expect(updated.item(withID: "old") == nil)
        #expect(updated.items(in: .simulatorDevices).map(\.id) == ["sim"])
        #expect(updated.totalBytes == 12)
        #expect(updated.scannedAt == scannedAt)
    }

    /// Verifies the category table's search matches name, subtitle, or workspace path, ignoring case and padding.
    /// To replicate: open DerivedData → type " SAMPLE " in the search field.
    @Test("Search matches name, subtitle, or workspace path")
    func items_withSearch_matchesNameSubtitleOrWorkspace() {
        let inventory = makeInventory([
            makeStorageItem(id: "byName", name: "SampleApp"),
            makeStorageItem(id: "bySubtitle", name: "Other", subtitle: "sampleapp-abc"),
            makeStorageItem(id: "byWorkspace", name: "Third", workspacePath: "/Users/me/Sample.xcodeproj"),
            makeStorageItem(id: "miss", name: "Unrelated"),
        ])

        let results = inventory.items(in: .derivedData, matching: .all, search: "  SAMPLE ", sortedBy: [])

        #expect(Set(results.map(\.id)) == ["byName", "bySubtitle", "byWorkspace"])
    }

    /// Verifies search, the Recommended filter, and sort order combine.
    /// To replicate: open DerivedData → choose Recommended → type "app" → sort by Size.
    @Test("Search, filter, and sort apply together")
    func items_withSearchFilterAndSort_returnsSortedMatches() {
        let inventory = makeInventory([
            makeStorageItem(id: "small", name: "SmallApp", sizeBytes: 1, status: .orphaned),
            makeStorageItem(id: "big", name: "BigApp", sizeBytes: 50, status: .stale),
            makeStorageItem(id: "otherName", name: "Tooling", sizeBytes: 70, status: .stale),
            makeStorageItem(id: "active", name: "ActiveApp", sizeBytes: 99, status: .active),
            makeStorageItem(
                id: "protected",
                name: "ProtectedApp",
                sizeBytes: 80,
                status: .stale,
                method: .notDeletable(reason: "System")
            ),
        ])

        let results = inventory.items(
            in: .derivedData,
            matching: .reclaimable,
            search: "app",
            sortedBy: [KeyPathComparator(\.sizeBytes, order: .reverse)]
        )

        #expect(results.map(\.id) == ["big", "small"])
    }

    /// Verifies an uppercase "I" still finds "iOS" under the Turkish locale, where dotted and dotless i differ.
    /// To replicate: set the Mac to Turkish (Türkiye) → open Simulator Runtimes → type "I".
    @Test("Uppercase I matches iOS regardless of locale")
    func items_withUppercaseI_matchesLowercaseIInTurkishLocale() {
        let inventory = makeInventory([makeStorageItem(id: "rt", category: .simulatorRuntimes, name: "iOS 26.4")])

        let results = inventory.items(
            in: .simulatorRuntimes,
            matching: .all,
            search: "I",
            sortedBy: [],
            locale: Locale(identifier: "tr_TR")
        )

        #expect(results.map(\.id) == ["rt"])
    }

    /// Verifies the Overview's Recommended Cleanup card names exactly the statuses that count as reclaimable.
    /// To replicate: open Overview → read the Recommended Cleanup footnote.
    @Test("Cleanup summary lists reclaimable statuses")
    func reclaimableStatusSummary_listsReclaimableStatuses() {
        #expect(ItemStatus.reclaimableStatusSummary == "orphaned, unavailable, or unused")
    }

    // MARK: - Scan failures

    /// Verifies each category's metrics carry its scan failure, so a view never joins failures from elsewhere.
    /// To replicate: make a disposable folder in iOS DeviceSupport unreadable (`chmod 000`) → scan → the sidebar
    /// row and Overview card both warn → restore its permissions.
    @Test("A snapshot's failures reach that category's metrics")
    func initFromSnapshot_carriesFailuresToCategoryMetrics() throws {
        let snapshot = ScanSnapshot(
            scannedAt: scannedAt,
            itemsByCategory: [:],
            volume: nil,
            failures: [.deviceSupport: "Permission denied"]
        )

        let inventory = StorageInventory(snapshot: snapshot)

        #expect(inventory.scanFailure(in: .deviceSupport) == "Permission denied")
        let deviceSupport = try #require(inventory.categoryMetrics.first { $0.category == .deviceSupport })
        #expect(deviceSupport.failure == "Permission denied")
        #expect(inventory.categoryMetrics.filter { $0.failure != nil }.map(\.category) == [.deviceSupport])
    }

    /// Verifies a category arriving mid-scan sets its own failure, and a clean rescan of it clears the old one.
    /// To replicate: scan with simctl broken → fix simctl → rescan → the Simulator Devices warning goes away.
    @Test("Replacing a category sets or clears only its failure")
    func replacingItems_setsOrClearsOnlyThatCategorysFailure() {
        let inventory = makeInventory([], scanFailures: [.simulatorDevices: "simctl unavailable", .previews: "Busy"])

        let failed = inventory.replacingItems(in: .deviceSupport, with: [], failure: "Permission denied")
        let recovered = failed.replacingItems(in: .simulatorDevices, with: [], failure: nil)

        #expect(recovered.scanFailure(in: .deviceSupport) == "Permission denied")
        #expect(recovered.scanFailure(in: .simulatorDevices) == nil)
        #expect(recovered.scanFailure(in: .previews) == "Busy")
    }

    /// Verifies a scan starts with no warnings while the last results stay visible.
    /// To replicate: scan with a failure → press ⌘R → the warning disappears while sizes stay until each
    /// category reports.
    @Test("Clearing failures keeps items and totals")
    func clearingFailures_removesEveryFailureButKeepsItems() {
        let inventory = makeInventory(
            [makeStorageItem(id: "a", sizeBytes: 100, status: .orphaned)],
            scanFailures: [.deviceSupport: "Permission denied", .simulatorRuntimes: "Timed out"]
        )

        let cleared = inventory.clearingFailures()

        #expect(cleared.categoryMetrics.allSatisfy { $0.failure == nil })
        #expect(cleared.items(in: .derivedData).map(\.id) == ["a"])
        #expect(cleared.totalBytes == 100)
        #expect(cleared.scannedAt == scannedAt)
    }

    /// Verifies clearing then refilling one category cannot leave a failure on a category still scanning, which is
    /// why the Overview card doesn't check for scanning before showing a failure.
    /// To replicate: scan with two failing categories → press ⌘R → while the second still scans, it shows no warning.
    @Test("After clearing, only categories that report again carry a failure")
    func clearingThenReplacing_leavesUnreportedCategoriesWithoutFailure() {
        let inventory = makeInventory([], scanFailures: [.deviceSupport: "Old", .simulatorRuntimes: "Old"])

        let midScan = inventory.clearingFailures().replacingItems(in: .deviceSupport, with: [], failure: "New")

        #expect(midScan.scanFailure(in: .deviceSupport) == "New")
        #expect(midScan.scanFailure(in: .simulatorRuntimes) == nil)
    }

    /// Verifies a deletion leaves scan warnings in place until the rescan that follows it.
    /// To replicate: scan with a DeviceSupport failure → trash a DerivedData folder → the warning stays.
    @Test("Removing items keeps failures")
    func removingItems_keepsFailures() {
        let inventory = makeInventory(
            [makeStorageItem(id: "a", sizeBytes: 100, status: .orphaned)],
            scanFailures: [.deviceSupport: "Permission denied"]
        )

        let updated = inventory.removingItems(withIDs: ["a"])

        #expect(updated.scanFailure(in: .deviceSupport) == "Permission denied")
    }

    private func makeInventory(
        _ items: [StorageItem],
        scanFailures: [StorageCategory: String] = [:]
    ) -> StorageInventory {
        StorageInventory(
            itemsByCategory: Dictionary(grouping: items, by: \.category),
            scannedAt: scannedAt,
            volume: DiskVolume(name: "Test Volume", availableBytes: 500, totalBytes: 1000),
            scanFailures: scanFailures
        )
    }
}
