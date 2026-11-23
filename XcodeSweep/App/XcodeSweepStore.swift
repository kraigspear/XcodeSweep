import Foundation
import Observation

/// Single mutually-exclusive lifecycle state for `XcodeSweepStore`.
enum OperationState: Equatable, Sendable {
    case idle
    case scanning(completed: Set<StorageCategory>)
    case deleting(DeletionProgress?)

    /// Whether a scan or deletion is running.
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

    /// The scan or deletion in progress; a new one starts only while this is `.idle`.
    private(set) var operation: OperationState = .idle
    private(set) var inventory: StorageInventory = .empty
    private(set) var scanWarnings: [String] = []
    /// The plan awaiting the user's confirmation; non-nil presents the confirmation dialog.
    var pendingDeletion: DeletionPlan?
    /// The outcome of the last finished deletion; non-nil presents the completion alert.
    var lastDeletionReport: DeletionReport?

    private let xcodeStorage: XcodeStorage
    @ObservationIgnored
    private var operationTask: Task<Void, Never>?
    /// Set once the app is quitting: a stopped deletion then skips its rescan, which nothing would show.
    @ObservationIgnored
    private var isTerminating = false

    // MARK: - Derived Lifecycle Queries

    var hasCompletedScan: Bool {
        inventory.scannedAt != nil
    }

    // MARK: - Initialization

    init(xcodeStorage: XcodeStorage = XcodeStorage()) {
        self.xcodeStorage = xcodeStorage
    }

    // MARK: - Operations

    /// Cancels the running scan or deletion, if any.
    ///
    /// The store stays busy until teardown completes, keeping scans and deletions mutually exclusive.
    func cancelOperation() {
        operationTask?.cancel()
    }

    /// Stops the running scan or deletion for good, returning once it has torn down.
    ///
    /// For quitting: unlike `cancelOperation()`, a stopped deletion isn't followed by a rescan.
    /// The store doesn't expect to run another operation afterward.
    func stopForTermination() async {
        isTerminating = true
        guard let task = operationTask else { return }
        task.cancel()
        await task.value
    }

    // MARK: - Scanning

    /// Scans unless a scan has already completed, and cancels that scan if the caller is cancelled.
    func refreshIfNeeded() async {
        guard !hasCompletedScan, !Task.isCancelled, let task = startRefresh() else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// How old a scan can get before `refreshIfStale()` replaces it.
    ///
    /// A rescan takes seconds and blocks cleanup, so a quick switch to Finder or Xcode shouldn't
    /// trigger one. But a build changes DerivedData within minutes, so a user returning after one,
    /// or after a break, should see current sizes and statuses.
    private static let staleScanAge: TimeInterval = 15 * 60

    /// Rescans when the last completed scan is older than `staleScanAge`.
    ///
    /// Does nothing while busy, while a deletion awaits confirmation, or before any scan has
    /// completed, which the launch scan handles.
    ///
    /// - Returns: The scan's task; `nil` if nothing started.
    @discardableResult
    func refreshIfStale() -> Task<Void, Never>? {
        guard pendingDeletion == nil,
              let scannedAt = inventory.scannedAt,
              xcodeStorage.now().timeIntervalSince(scannedAt) > Self.staleScanAge
        else { return nil }
        return startRefresh()
    }

    /// Starts rescanning all categories, updating the inventory as each category finishes.
    ///
    /// A scan can only be cancelled, not fail; a cancelled scan restores the inventory from when
    /// it began. Call `cancelOperation()` to stop it.
    ///
    /// - Returns: The scan's task, for callers that wait on it; `nil` if busy, and nothing started.
    @discardableResult
    func startRefresh() -> Task<Void, Never>? {
        guard !operation.isBusy else { return nil }
        return beginRefresh()
    }

    /// Takes over the operation slot for a scan, whatever holds it now; callers guarantee no other
    /// operation is running, as `startRefresh()` does and a finishing deletion does for its rescan.
    private func beginRefresh() -> Task<Void, Never> {
        let previousInventory = inventory
        let previousWarnings = scanWarnings

        pendingDeletion = nil
        operation = .scanning(completed: [])
        scanWarnings = []

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefresh(
                previousInventory: previousInventory,
                previousWarnings: previousWarnings
            )
        }
        operationTask = task
        return task
    }

    private func runRefresh(
        previousInventory: StorageInventory,
        previousWarnings: [String]
    ) async {
        defer {
            operation = .idle
            operationTask = nil
        }

        do throws(CancellationError) {
            guard !Task.isCancelled else { throw CancellationError() }
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
        } catch {
            // Interrupted, not failed: restore the inventory from when this scan began, and report nothing.
            inventory = previousInventory
            scanWarnings = previousWarnings
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

    /// Selected items currently visible in the active category, in table order.
    ///
    /// Filtering keeps the selected IDs, so a hidden row is selected again when it reappears.
    /// Hidden rows are left out of the inspector and of any deletion plan built while they are hidden.
    var selectedItems: [StorageItem] {
        // The footer, inspector, and menu read this constantly; don't sort a category for nothing.
        guard !selectedItemIDs.isEmpty, let category = activeCategory else { return [] }
        return visibleItems(for: category).filter { selectedItemIDs.contains($0.id) }
    }

    /// The deletion plan for the current selection.
    var selectionPlan: DeletionPlan {
        DeletionPlan(selection: selectedItems)
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
        let reclaimableItems = inventory.items(in: category).filter(\.isReclaimable)
        selectedItemIDs = Set(reclaimableItems.map(\.id))
    }

    /// Selects the visible reclaimable items in the active category.
    func selectReclaimableInActiveCategory() {
        guard let category = activeCategory else { return }
        let reclaimableItems = visibleItems(for: category).filter(\.isReclaimable)
        selectedItemIDs = Set(reclaimableItems.map(\.id))
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
        guard !operation.isBusy else { return }
        let plan = DeletionPlan(selection: items)
        guard !plan.isEmpty else { return }
        pendingDeletion = plan
    }

    /// Starts deleting the plan's items, removing each from the inventory as it goes, then rescans.
    ///
    /// Sets `lastDeletionReport` when the run completes, or when it is cancelled after removing or
    /// failing at least one item. The rescan runs however the deletion ends: a cancelled `simctl`
    /// delete may have taken effect, and free space and simulator availability have changed.
    /// Call `cancelOperation()` to stop either phase.
    ///
    /// - Returns: The task for the deletion and its rescan, for callers that wait on it; `nil` if
    ///   busy or the plan is empty, and nothing started.
    @discardableResult
    func startDeletion(_ plan: DeletionPlan) -> Task<Void, Never>? {
        guard !operation.isBusy, !plan.isEmpty else { return nil }

        pendingDeletion = nil
        operation = .deleting(nil)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeletion(plan)
            guard !self.isTerminating else {
                self.operation = .idle
                self.operationTask = nil
                return
            }
            // Hand the slot straight to the rescan, so the store is never idle between the phases.
            await self.beginRefresh().value
        }
        operationTask = task
        return task
    }

    /// Leaves `operation` as `.deleting`; the rescan that follows takes the slot from there.
    private func runDeletion(_ plan: DeletionPlan) async {
        var removed: [StorageItem] = []
        var failures: [DeletionFailure] = []
        do throws(CancellationError) {
            guard !Task.isCancelled else { throw CancellationError() }
            for try await event in xcodeStorage.delete(plan) {
                switch event {
                case let .starting(progress):
                    operation = .deleting(progress)

                case let .deleted(itemID, progress):
                    operation = .deleting(progress)
                    if let item = plan.deletableItems.first(where: { $0.id == itemID }) {
                        removed.append(item)
                    }
                    removeItems(withIDs: [itemID])

                case let .failed(failure, progress):
                    operation = .deleting(progress)
                    failures.append(failure)

                case let .completed(report):
                    lastDeletionReport = report
                    return
                }
            }
        } catch {
            // Interrupted, not failed: report what happened before the stop, if anything did.
            if !removed.isEmpty || !failures.isEmpty {
                lastDeletionReport = DeletionReport(removed: removed, failures: failures, wasCancelled: true)
            }
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
