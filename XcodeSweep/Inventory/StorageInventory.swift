import Foundation

/// Scanned items with their derived totals and each category's scan failure.
///
/// Every change returns a new value with totals recomputed, so totals can never go stale relative to items. Failures
/// live in the same value, so restoring an inventory restores both.
struct StorageInventory: Equatable, Sendable {
    let scannedAt: Date?
    let volume: DiskVolume?
    let categoryMetrics: [CategoryMetrics]
    let totalBytes: Int64
    let reclaimableBytes: Int64
    let totalItemCount: Int
    let reclaimableItemCount: Int

    private let itemsByCategory: [StorageCategory: [StorageItem]]
    private let itemsByID: [StorageItem.ID: StorageItem]
    private let scanFailures: [StorageCategory: String]

    static let empty = StorageInventory(
        itemsByCategory: [:],
        scannedAt: nil,
        volume: nil
    )

    init(
        itemsByCategory: [StorageCategory: [StorageItem]],
        scannedAt: Date?,
        volume: DiskVolume?,
        scanFailures: [StorageCategory: String] = [:]
    ) {
        self.itemsByCategory = itemsByCategory
        self.scannedAt = scannedAt
        self.volume = volume
        self.scanFailures = scanFailures

        categoryMetrics = StorageCategory.allCases.map { category in
            let items = itemsByCategory[category] ?? []
            let reclaimable = items.filter(\.isReclaimable)
            return CategoryMetrics(
                category: category,
                itemCount: items.count,
                totalBytes: items.reduce(0) { $0 + $1.sizeBytes },
                reclaimableCount: reclaimable.count,
                reclaimableBytes: reclaimable.reduce(0) { $0 + $1.sizeBytes },
                failure: scanFailures[category]
            )
        }
        totalBytes = categoryMetrics.reduce(0) { $0 + $1.totalBytes }
        reclaimableBytes = categoryMetrics.reduce(0) { $0 + $1.reclaimableBytes }
        totalItemCount = categoryMetrics.reduce(0) { $0 + $1.itemCount }
        reclaimableItemCount = categoryMetrics.reduce(0) { $0 + $1.reclaimableCount }
        itemsByID = Dictionary(
            itemsByCategory.values.joined().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    init(snapshot: ScanSnapshot) {
        self.init(
            itemsByCategory: snapshot.itemsByCategory,
            scannedAt: snapshot.scannedAt,
            volume: snapshot.volume,
            scanFailures: snapshot.failures
        )
    }

    // MARK: - Queries

    func items(in category: StorageCategory) -> [StorageItem] {
        itemsByCategory[category] ?? []
    }

    /// Why `category`'s last scan is incomplete, or `nil` if it was fully read.
    func scanFailure(in category: StorageCategory) -> String? {
        scanFailures[category]
    }

    func item(withID id: StorageItem.ID) -> StorageItem? {
        itemsByID[id]
    }

    /// Items in `category` passing `filter` whose name, subtitle, or workspace path contains `search`.
    func items(
        in category: StorageCategory,
        matching filter: ItemFilter,
        search: String,
        sortedBy sortOrder: [KeyPathComparator<StorageItem>],
        locale: Locale = .current
    ) -> [StorageItem] {
        // Lowercase first: under tr_TR, a case-insensitive "I" does not match "i".
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func contains(_ text: String?) -> Bool {
            text?.range(of: query, options: .caseInsensitive, locale: locale) != nil
        }
        return items(in: category)
            .filter { item in
                guard filter.matches(item) else { return false }
                guard !query.isEmpty else { return true }
                return contains(item.name) || contains(item.subtitle) || contains(item.workspacePath)
            }
            .sorted(using: sortOrder)
    }

    // MARK: - Changes

    /// Replaces one category's items and failure, as each category arrives during a scan; the last scan date is kept.
    func replacingItems(
        in category: StorageCategory,
        with items: [StorageItem],
        failure: String?
    ) -> StorageInventory {
        var updatedItems = itemsByCategory
        updatedItems[category] = items
        var updatedFailures = scanFailures
        updatedFailures[category] = failure
        return with(items: updatedItems, scanFailures: updatedFailures)
    }

    /// Drops every failure while keeping items, so a scan can show the last results until each category reports.
    func clearingFailures() -> StorageInventory {
        with(items: itemsByCategory, scanFailures: [:])
    }

    func removingItems(withIDs removedIDs: Set<StorageItem.ID>) -> StorageInventory {
        with(
            items: itemsByCategory.mapValues { $0.filter { !removedIDs.contains($0.id) } },
            scanFailures: scanFailures
        )
    }

    private func with(
        items: [StorageCategory: [StorageItem]],
        scanFailures: [StorageCategory: String]
    ) -> StorageInventory {
        StorageInventory(
            itemsByCategory: items,
            scannedAt: scannedAt,
            volume: volume,
            scanFailures: scanFailures
        )
    }
}

/// Aggregated statistics for a single storage category.
struct CategoryMetrics: Identifiable, Equatable, Hashable, Sendable {
    let category: StorageCategory
    let itemCount: Int
    let totalBytes: Int64
    let reclaimableCount: Int
    let reclaimableBytes: Int64
    /// Why this category's last scan is incomplete, or `nil` if it was fully read.
    let failure: String?

    var id: StorageCategory {
        category
    }
}
