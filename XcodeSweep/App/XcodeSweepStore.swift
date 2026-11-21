import Foundation
import Observation

/// Single mutually-exclusive lifecycle state for `XcodeSweepStore`.
enum OperationState: Equatable, Sendable {
    case idle
    case scanning(completed: Set<StorageCategory>)
    case deleting(DeletionProgress?)

    var isBusy: Bool {
        self != .idle
    }

    var isScanning: Bool {
        if case .scanning = self {
            true
        } else {
            false
        }
    }

    var isDeleting: Bool {
        if case .deleting = self {
            true
        } else {
            false
        }
    }

    var deletionProgress: DeletionProgress? {
        if case let .deleting(progress) = self {
            progress
        } else {
            nil
        }
    }

    /// Whether `category` is still waiting for its results in the current scan.
    func isScanning(_ category: StorageCategory) -> Bool {
        if case let .scanning(completed) = self {
            return !completed.contains(category)
        }
        return false
    }
}

/// The app's observable state: the scanned inventory, navigation, selection, and the scan and deletion flows.
///
/// Scans and deletions never overlap; `operation` tracks which one, if any, is running.
@MainActor
@Observable
final class XcodeSweepStore {
    // MARK: - Stored UI State

    private(set) var sidebarSelection: SidebarSelection = .overview

    var selectedItemIDs: Set<StorageItem.ID> = []
    var searchText = ""
    var statusFilter: ItemFilter = .all
    var sortOrder: [KeyPathComparator<StorageItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse),
    ]
    var inspectorPresented = true

    private(set) var operation: OperationState = .idle
    private(set) var inventory: StorageInventory = .empty
    private(set) var scanWarnings: [String] = []
    /// The plan awaiting the user's confirmation; non-nil presents the confirmation dialog.
    var pendingDeletion: DeletionPlan?
    /// The outcome of the last finished deletion; non-nil presents the completion alert.
    var lastDeletionReport: DeletionReport?
    var errorMessage: String?

    private let xcodeStorage: XcodeStorage

    // MARK: - Derived Lifecycle Queries

    var isScanning: Bool {
        operation.isScanning
    }

    var isDeleting: Bool {
        operation.isDeleting
    }

    /// Whether a scan can start; `false` while a scan or deletion is running.
    var canRefresh: Bool {
        operation == .idle
    }

    /// Whether a deletion can start; `false` while a scan or deletion is running.
    var canDelete: Bool {
        operation == .idle
    }

    var hasCompletedScan: Bool {
        inventory.scannedAt != nil
    }

    var deletionProgress: DeletionProgress? {
        operation.deletionProgress
    }

    /// Categories whose results are in: those finished so far during a scan, otherwise every
    /// category once any scan has completed.
    var completedCategories: Set<StorageCategory> {
        switch operation {
        case let .scanning(completed):
            completed
        case .idle, .deleting:
            hasCompletedScan ? Set(StorageCategory.allCases) : []
        }
    }

    // MARK: - Initialization

    init(xcodeStorage: XcodeStorage = XcodeStorage()) {
        self.xcodeStorage = xcodeStorage
    }

    // MARK: - Scanning

    /// Scans unless a scan has already completed.
    func refreshIfNeeded() async {
        guard !hasCompletedScan else { return }
        await refresh()
    }

    /// Rescans all categories, updating the inventory as each category finishes.
    ///
    /// Does nothing while busy. If the scan fails or is cancelled, the previous inventory is restored;
    /// only a failure sets `errorMessage`.
    func refresh() async {
        guard canRefresh else { return }

        let previousInventory = inventory
        let previousWarnings = scanWarnings

        pendingDeletion = nil
        operation = .scanning(completed: [])
        scanWarnings = []
        errorMessage = nil
        defer { operation = .idle }

        do {
            var completed: Set<StorageCategory> = []
            for try await event in xcodeStorage.scan() {
                switch event {
                case let .categoryScanned(category, items):
                    inventory = inventory.replacingItems(in: category, with: items)
                    completed.insert(category)
                    operation = .scanning(completed: completed)

                case let .completed(snapshot):
                    inventory = StorageInventory(snapshot: snapshot)
                    scanWarnings = snapshot.warnings
                    pruneStaleSelection()
                    return
                }
            }
        } catch is CancellationError {
            // Interrupted, not failed: restore the last completed result and report nothing.
            inventory = previousInventory
            scanWarnings = previousWarnings
        } catch {
            inventory = previousInventory
            scanWarnings = previousWarnings
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Querying

    /// Items in `category` after the current status filter, search text, and sort order.
    func visibleItems(for category: StorageCategory) -> [StorageItem] {
        inventory.items(in: category, matching: statusFilter, search: searchText, sortedBy: sortOrder)
    }

    /// The category shown in the detail column; `nil` on the overview.
    var activeCategory: StorageCategory? {
        if case let .category(category) = sidebarSelection {
            return category
        }
        return nil
    }

    /// Selected items that belong to the active category.
    var selectedItems: [StorageItem] {
        guard let category = activeCategory else { return [] }
        return selectedItemIDs.compactMap { inventory.item(withID: $0) }.filter { $0.category == category }
    }

    /// The deletion plan for the current selection.
    var selectionPlan: DeletionPlan {
        DeletionPlan(selection: selectedItems)
    }

    func isCategoryScanning(_ category: StorageCategory) -> Bool {
        operation.isScanning(category)
    }

    // MARK: - Navigation

    /// Moves to `destination`.
    ///
    /// A new destination starts with no selection, filter, or search; re-selecting the current one
    /// keeps what the user set.
    func navigate(to destination: SidebarSelection) {
        guard destination != sidebarSelection else { return }
        sidebarSelection = destination
        selectedItemIDs.removeAll()
        statusFilter = .all
        searchText = ""
    }

    // MARK: - Selection Helpers

    /// Opens `category` filtered to reclaimable items, with all of them selected.
    func openCategoryAndSelectReclaimable(_ category: StorageCategory) {
        navigate(to: .category(category))
        statusFilter = .reclaimable
        let candidates = inventory.items(in: category).filter(\.isReclaimableCandidate)
        selectedItemIDs = Set(candidates.map(\.id))
    }

    /// Selects the visible reclaimable items in the active category.
    func selectReclaimableInActiveCategory() {
        guard let category = activeCategory else { return }
        let candidates = visibleItems(for: category).filter(\.isReclaimableCandidate)
        selectedItemIDs = Set(candidates.map(\.id))
    }

    /// Selects every visible deletable item in the active category.
    func selectAllDeletableInActiveCategory() {
        guard let category = activeCategory else { return }
        let deletable = visibleItems(for: category).filter(\.isDeletable)
        selectedItemIDs = Set(deletable.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    // MARK: - Deletion Flow

    /// Asks the user to confirm deleting the selected items.
    func requestDeleteSelected() {
        requestDelete(items: selectedItems)
    }

    /// Asks the user to confirm deleting `items` by setting `pendingDeletion`.
    ///
    /// Does nothing while busy or when none of `items` is deletable.
    func requestDelete(items: [StorageItem]) {
        guard canDelete else { return }
        let plan = DeletionPlan(selection: items)
        guard !plan.isEmpty else { return }
        pendingDeletion = plan
    }

    /// Deletes the plan's items, removing each from the inventory as it goes.
    ///
    /// Sets `lastDeletionReport` on completion. If cancelled, items already deleted stay removed
    /// and no report is set.
    func confirmDeletion(_ plan: DeletionPlan) async {
        guard canDelete, !plan.isEmpty else { return }

        pendingDeletion = nil
        operation = .deleting(nil)
        defer { operation = .idle }

        do {
            for try await event in xcodeStorage.delete(plan) {
                switch event {
                case let .starting(progress):
                    operation = .deleting(progress)

                case let .deleted(itemID, progress):
                    operation = .deleting(progress)
                    removeItems(withIDs: [itemID])

                case let .failed(_, progress):
                    operation = .deleting(progress)

                case let .completed(report):
                    lastDeletionReport = report
                    return
                }
            }
        } catch is CancellationError {
            // Interrupted, not failed: already-deleted items stay removed and no completion alert is shown.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeItems(withIDs removedIDs: Set<StorageItem.ID>) {
        inventory = inventory.removingItems(withIDs: removedIDs)
        selectedItemIDs.subtract(removedIDs)
    }

    // MARK: - Selection Pruning

    private func pruneStaleSelection() {
        guard let category = activeCategory else {
            selectedItemIDs.removeAll()
            return
        }
        let validIDs = Set(inventory.items(in: category).map(\.id))
        selectedItemIDs.formIntersection(validIDs)
    }
}

#if DEBUG && canImport(SwiftUI)
    extension XcodeSweepStore {
        /// A store already holding `inventory`, backed by `XcodeStorage.preview`.
        static func preview(
            inventory: StorageInventory = .preview,
            destination: SidebarSelection = .overview,
            selectedItemIDs: Set<StorageItem.ID> = []
        ) -> XcodeSweepStore {
            let store = XcodeSweepStore(xcodeStorage: .preview)
            store.inventory = inventory
            store.navigate(to: destination)
            store.selectedItemIDs = selectedItemIDs
            return store
        }
    }
#endif
