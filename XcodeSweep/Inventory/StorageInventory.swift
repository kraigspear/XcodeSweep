import Foundation

/// Scanned items with their derived totals.
///
/// Every change returns a new value with totals recomputed, so totals can never go stale relative to items.
struct StorageInventory: Equatable, Sendable {
    let scannedAt: Date?
    let diskAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let categoryMetrics: [CategoryMetrics]
    let totalBytes: Int64
    let reclaimableBytes: Int64
    let totalItemCount: Int
    let reclaimableItemCount: Int

    private let itemsByCategory: [StorageCategory: [StorageItem]]
    private let itemsByID: [StorageItem.ID: StorageItem]

    static let empty = StorageInventory(
        itemsByCategory: [:],
        scannedAt: nil,
        diskAvailableBytes: nil,
        diskTotalBytes: nil
    )

    init(
        itemsByCategory: [StorageCategory: [StorageItem]],
        scannedAt: Date?,
        diskAvailableBytes: Int64?,
        diskTotalBytes: Int64?
    ) {
        self.itemsByCategory = itemsByCategory
        self.scannedAt = scannedAt
        self.diskAvailableBytes = diskAvailableBytes
        self.diskTotalBytes = diskTotalBytes

        categoryMetrics = StorageCategory.allCases.map { category in
            let items = itemsByCategory[category] ?? []
            let reclaimable = items.filter(\.isReclaimable)
            return CategoryMetrics(
                category: category,
                itemCount: items.count,
                totalBytes: items.reduce(0) { $0 + $1.sizeBytes },
                reclaimableCount: reclaimable.count,
                reclaimableBytes: reclaimable.reduce(0) { $0 + $1.sizeBytes }
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
            diskAvailableBytes: snapshot.diskAvailableBytes,
            diskTotalBytes: snapshot.diskTotalBytes
        )
    }

    // MARK: - Queries

    func items(in category: StorageCategory) -> [StorageItem] {
        itemsByCategory[category] ?? []
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

    /// Replaces one category's items, as each category arrives during a scan; the last scan date is kept.
    func replacingItems(in category: StorageCategory, with items: [StorageItem]) -> StorageInventory {
        var updated = itemsByCategory
        updated[category] = items
        return withItems(updated)
    }

    func removingItems(withIDs removedIDs: Set<StorageItem.ID>) -> StorageInventory {
        withItems(itemsByCategory.mapValues { $0.filter { !removedIDs.contains($0.id) } })
    }

    private func withItems(_ items: [StorageCategory: [StorageItem]]) -> StorageInventory {
        StorageInventory(
            itemsByCategory: items,
            scannedAt: scannedAt,
            diskAvailableBytes: diskAvailableBytes,
            diskTotalBytes: diskTotalBytes
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

    var id: StorageCategory {
        category
    }
}
