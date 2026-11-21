import Foundation
import Testing
@testable import XcodeSweep

@Suite("StorageInventory")
struct StorageInventoryTests {
    private let scannedAt = testISO8601Date("2026-11-21T10:00:00Z")

    /// Verifies Overview totals count only deletable, cleanup-recommended items as reclaimable.
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
        #expect(updated.diskAvailableBytes == inventory.diskAvailableBytes)
    }

    /// Verifies a category arriving mid-scan replaces only that category and keeps the last scan date.
    /// To replicate: press ⌘R → watch categories fill in one at a time while other sidebar sizes stay put.
    @Test("Replacing one category leaves the others and the scan date intact")
    func replacingItems_updatesOnlyThatCategory() {
        let inventory = makeInventory([
            makeStorageItem(id: "old", sizeBytes: 100),
            makeStorageItem(id: "sim", category: .simulatorDevices, sizeBytes: 5),
        ])

        let updated = inventory.replacingItems(in: .derivedData, with: [makeStorageItem(id: "new", sizeBytes: 7)])

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
    @Test("Cleanup summary lists recommended statuses")
    func cleanupRecommendationSummary_listsRecommendedStatuses() {
        #expect(ItemStatus.cleanupRecommendationSummary == "orphaned, unavailable, or unused")
    }

    private func makeInventory(_ items: [StorageItem]) -> StorageInventory {
        StorageInventory(
            itemsByCategory: Dictionary(grouping: items, by: \.category),
            scannedAt: scannedAt,
            diskAvailableBytes: 500,
            diskTotalBytes: 1000
        )
    }
}
