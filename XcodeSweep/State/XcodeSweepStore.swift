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

    func isScanning(_ category: StorageCategory) -> Bool {
        if case let .scanning(completed) = self {
            return !completed.contains(category)
        }
        return false
    }
}

@MainActor
@Observable
final class XcodeSweepStore {
    // MARK: - Stored UI State

    var sidebarSelection: SidebarSelection = .overview {
        didSet {
            if oldValue != sidebarSelection {
                selectedItemIDs.removeAll()
                statusFilter = .all
                searchText = ""
            }
        }
    }

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
    var pendingDeletion: DeletionPlan?
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

    var canRefresh: Bool {
        operation == .idle
    }

    var canDelete: Bool {
        operation == .idle
    }

    var hasCompletedScan: Bool {
        inventory.scannedAt != nil
    }

    var deletionProgress: DeletionProgress? {
        operation.deletionProgress
    }

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

    func refreshIfNeeded() async {
        guard !hasCompletedScan else { return }
        await refresh()
    }

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

    func visibleItems(for category: StorageCategory) -> [StorageItem] {
        inventory.items(in: category, matching: statusFilter, search: searchText, sortedBy: sortOrder)
    }

    var activeCategory: StorageCategory? {
        if case let .category(category) = sidebarSelection {
            return category
        }
        return nil
    }

    var selectedItems: [StorageItem] {
        guard let category = activeCategory else { return [] }
        return selectedItemIDs.compactMap { inventory.item(withID: $0) }.filter { $0.category == category }
    }

    var selectionPlan: DeletionPlan {
        DeletionPlan(selection: selectedItems)
    }

    func isCategoryScanning(_ category: StorageCategory) -> Bool {
        operation.isScanning(category)
    }

    // MARK: - Selection Helpers

    func openCategoryAndSelectReclaimable(_ category: StorageCategory) {
        sidebarSelection = .category(category)
        statusFilter = .reclaimable
        let candidates = inventory.items(in: category).filter(\.isReclaimableCandidate)
        selectedItemIDs = Set(candidates.map(\.id))
    }

    func selectReclaimableInActiveCategory() {
        guard let category = activeCategory else { return }
        let candidates = visibleItems(for: category).filter(\.isReclaimableCandidate)
        selectedItemIDs = Set(candidates.map(\.id))
    }

    func selectAllDeletableInActiveCategory() {
        guard let category = activeCategory else { return }
        let deletable = visibleItems(for: category).filter(\.isDeletable)
        selectedItemIDs = Set(deletable.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    // MARK: - Deletion Flow

    func requestDeleteSelected() {
        requestDelete(items: selectedItems)
    }

    func requestDelete(items: [StorageItem]) {
        guard canDelete else { return }
        let plan = DeletionPlan(selection: items)
        guard !plan.isEmpty else { return }
        pendingDeletion = plan
    }

    func confirmDeletion(_ plan: DeletionPlan) async {
        guard canDelete, !plan.isEmpty else { return }

        pendingDeletion = nil
        operation = .deleting(nil)
        defer { operation = .idle }

        do {
            for try await event in xcodeStorage.delete(items: plan.deletableItems) {
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
