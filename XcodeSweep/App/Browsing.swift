import Foundation

/// Where the user is and what they've narrowed to: destination, search, filter, sort, and selection.
///
/// Selection only ever holds items in the active category; `reconcile(with:)` relies on that.
struct Browsing: Equatable {
    private(set) var destination: SidebarSelection = .overview

    var selectedItemIDs: Set<StorageItem.ID> = []
    var searchText = ""
    var statusFilter: ItemFilter = .all
    var sortOrder: [KeyPathComparator<StorageItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse),
    ]

    /// The category shown in the detail column; `nil` on the overview.
    var activeCategory: StorageCategory? {
        if case let .category(category) = destination {
            return category
        }
        return nil
    }

    // MARK: - Queries

    /// Items in `category` after the current status filter, search text, and sort order.
    func visibleItems(for category: StorageCategory, in inventory: StorageInventory) -> [StorageItem] {
        inventory.items(in: category, matching: statusFilter, search: searchText, sortedBy: sortOrder)
    }

    /// Selected items currently visible in the active category, in table order.
    ///
    /// Filtering keeps the selected IDs, so a hidden row is selected again when it reappears.
    /// Hidden rows are left out of the inspector and of any deletion plan built while they are hidden.
    func selectedItems(in inventory: StorageInventory) -> [StorageItem] {
        // The footer, inspector, and menu read this constantly; don't sort a category for nothing.
        guard !selectedItemIDs.isEmpty, let category = activeCategory else { return [] }
        return visibleItems(for: category, in: inventory).filter { selectedItemIDs.contains($0.id) }
    }

    // MARK: - Navigation

    /// Moves to `destination`.
    ///
    /// A new destination starts with no selection, filter, or search; re-selecting the current one
    /// keeps what the user set.
    mutating func navigate(to destination: SidebarSelection) {
        guard destination != self.destination else { return }
        self.destination = destination
        selectedItemIDs.removeAll()
        statusFilter = .all
        searchText = ""
    }

    /// Opens `category` filtered to reclaimable items, with all of them selected.
    mutating func openCategoryAndSelectReclaimable(_ category: StorageCategory, in inventory: StorageInventory) {
        navigate(to: .category(category))
        statusFilter = .reclaimable
        selectedItemIDs = Set(inventory.items(in: category).filter(\.isReclaimable).map(\.id))
    }

    // MARK: - Selection

    /// Selects the visible reclaimable items in the active category.
    mutating func selectReclaimableInActiveCategory(in inventory: StorageInventory) {
        selectVisibleItemsInActiveCategory(in: inventory, where: \.isReclaimable)
    }

    /// Selects every visible deletable item in the active category.
    mutating func selectAllDeletableInActiveCategory(in inventory: StorageInventory) {
        selectVisibleItemsInActiveCategory(in: inventory, where: \.isDeletable)
    }

    mutating func clearSelection() {
        selectedItemIDs.removeAll()
    }

    /// Drops selected items that `inventory` no longer holds in the active category.
    mutating func reconcile(with inventory: StorageInventory) {
        guard let category = activeCategory else {
            selectedItemIDs.removeAll()
            return
        }
        selectedItemIDs.formIntersection(inventory.items(in: category).map(\.id))
    }

    private mutating func selectVisibleItemsInActiveCategory(
        in inventory: StorageInventory,
        where isIncluded: (StorageItem) -> Bool
    ) {
        guard let category = activeCategory else { return }
        selectedItemIDs = Set(visibleItems(for: category, in: inventory).filter(isIncluded).map(\.id))
    }
}
