import Foundation
import Observation

enum ItemFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    case reclaimable
    case orphaned
    case worktree
    case unavailable
    case stale

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .reclaimable: "Recommended"
        case .orphaned: "Orphaned"
        case .worktree: "Worktrees"
        case .unavailable: "Unavailable"
        case .stale: "Unused"
        }
    }

    static func filters(for category: StorageCategory) -> [ItemFilter] {
        switch category {
        case .derivedData:
            [.all, .reclaimable, .orphaned, .worktree, .stale]
        case .simulatorDevices:
            [.all, .reclaimable, .unavailable, .stale]
        case .simulatorRuntimes, .deviceSupport, .previews, .archivesAndCaches:
            [.all, .reclaimable, .stale]
        }
    }

    func matches(_ item: StorageItem) -> Bool {
        switch self {
        case .all:
            true
        case .reclaimable:
            item.isReclaimableCandidate
        case .orphaned:
            item.status == .orphaned
        case .worktree:
            item.status == .worktree
        case .unavailable:
            item.status == .unavailable
        case .stale:
            item.status == .stale
        }
    }
}

struct PendingDeletion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [StorageItem]

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var trashedCount: Int {
        items.filter { !$0.deletionMethod.isPermanent && $0.isDeletable }.count
    }

    var simctlCount: Int {
        items.filter { $0.deletionMethod.isPermanent }.count
    }

    var bootedDeviceCount: Int {
        items.filter {
            if case let .simctlDevice(_, isBooted) = $0.deletionMethod {
                return isBooted
            }
            return false
        }.count
    }

    var actionButtonTitle: String {
        if simctlCount > 0 && trashedCount == 0 {
            return "Delete \(items.count) \(items.count == 1 ? "Item" : "Items")"
        }
        if trashedCount > 0 && simctlCount == 0 {
            return "Move \(items.count) \(items.count == 1 ? "Item" : "Items") to Trash"
        }
        return "Remove \(items.count) Items"
    }

    var confirmationMessage: String {
        let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        var parts: [String] = []

        if trashedCount > 0 {
            parts
                .append(
                    "\(trashedCount) filesystem \(trashedCount == 1 ? "item" : "items") will be moved to Trash (reversible)."
                )
        }
        if simctlCount > 0 {
            parts
                .append(
                    "\(simctlCount) simulator \(simctlCount == 1 ? "item" : "items") will be permanently deleted using xcrun simctl."
                )
        }
        if bootedDeviceCount > 0 {
            parts
                .append(
                    "\(bootedDeviceCount) booted \(bootedDeviceCount == 1 ? "simulator" : "simulators") will be shut down first."
                )
        }

        return "Estimated space to reclaim: \(formattedSize).\n\n" + parts.joined(separator: " ")
    }
}

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
    private(set) var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
    private(set) var summary: ScanSummary = .empty
    private(set) var scanWarnings: [String] = []
    var pendingDeletion: PendingDeletion?
    var lastDeletionReport: DeletionReport?
    var errorMessage: String?

    private var diskAvailableBytes: Int64?
    private var diskTotalBytes: Int64?
    private var lastScanCompletedAt: Date?

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
        summary.scannedAt != nil
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

        let previousItems = itemsByCategory
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
                    itemsByCategory[category] = items
                    completed.insert(category)
                    operation = .scanning(completed: completed)
                    rebuildSummary()

                case let .completed(snapshot):
                    itemsByCategory = snapshot.itemsByCategory
                    diskAvailableBytes = snapshot.diskAvailableBytes
                    diskTotalBytes = snapshot.diskTotalBytes
                    scanWarnings = snapshot.warnings
                    lastScanCompletedAt = snapshot.scannedAt
                    pruneStaleSelection()
                    rebuildSummary()
                    return
                }
            }
        } catch is CancellationError {
            // Interrupted, not failed: restore the last completed result and report nothing.
            itemsByCategory = previousItems
            scanWarnings = previousWarnings
            rebuildSummary()
        } catch {
            itemsByCategory = previousItems
            scanWarnings = previousWarnings
            rebuildSummary()
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Querying

    func items(for category: StorageCategory) -> [StorageItem] {
        itemsByCategory[category] ?? []
    }

    func visibleItems(for category: StorageCategory) -> [StorageItem] {
        let base = items(for: category)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = base.filter { item in
            guard statusFilter.matches(item) else { return false }
            guard !query.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || (item.workspacePath?.localizedCaseInsensitiveContains(query) ?? false)
        }

        return filtered.sorted(using: sortOrder)
    }

    var activeCategory: StorageCategory? {
        if case let .category(category) = sidebarSelection {
            return category
        }
        return nil
    }

    var selectedItems: [StorageItem] {
        guard let category = activeCategory else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: items(for: category).map { ($0.id, $0) })
        return selectedItemIDs.compactMap { lookup[$0] }
    }

    var deletableSelectedItems: [StorageItem] {
        selectedItems.filter(\.isDeletable)
    }

    var selectedTotalBytes: Int64 {
        deletableSelectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    func isCategoryScanning(_ category: StorageCategory) -> Bool {
        operation.isScanning(category)
    }

    // MARK: - Selection Helpers

    func openCategoryAndSelectReclaimable(_ category: StorageCategory) {
        sidebarSelection = .category(category)
        statusFilter = .reclaimable
        let candidates = items(for: category).filter(\.isReclaimableCandidate)
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
        requestDelete(items: deletableSelectedItems)
    }

    func requestDelete(items: [StorageItem]) {
        guard canDelete else { return }
        let deletable = items.filter(\.isDeletable)
        guard !deletable.isEmpty else { return }
        pendingDeletion = PendingDeletion(items: deletable)
    }

    func confirmDeletion(_ pending: PendingDeletion) async {
        guard canDelete, !pending.items.isEmpty else { return }

        pendingDeletion = nil
        operation = .deleting(nil)
        defer { operation = .idle }

        do {
            for try await event in xcodeStorage.delete(items: pending.items) {
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
        guard !removedIDs.isEmpty else { return }
        var changed = false
        for category in StorageCategory.allCases {
            guard var list = itemsByCategory[category] else { continue }
            let beforeCount = list.count
            list.removeAll { removedIDs.contains($0.id) }
            if list.count != beforeCount {
                itemsByCategory[category] = list
                changed = true
            }
        }
        selectedItemIDs.subtract(removedIDs)
        if changed {
            rebuildSummary()
        }
    }

    // MARK: - Summary Recomputation

    private func pruneStaleSelection() {
        guard let category = activeCategory else {
            selectedItemIDs.removeAll()
            return
        }
        let validIDs = Set(items(for: category).map(\.id))
        selectedItemIDs.formIntersection(validIDs)
    }

    private func rebuildSummary() {
        var totalBytes: Int64 = 0
        var reclaimableBytes: Int64 = 0
        var totalCount = 0
        var reclaimableCount = 0
        var metrics: [CategoryMetrics] = []

        for category in StorageCategory.allCases {
            let items = itemsByCategory[category] ?? []
            let catBytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let reclaimable = items.filter(\.isReclaimableCandidate)
            let catReclaimableBytes = reclaimable.reduce(Int64(0)) { $0 + $1.sizeBytes }

            totalBytes += catBytes
            reclaimableBytes += catReclaimableBytes
            totalCount += items.count
            reclaimableCount += reclaimable.count

            metrics.append(
                CategoryMetrics(
                    category: category,
                    itemCount: items.count,
                    totalBytes: catBytes,
                    reclaimableCount: reclaimable.count,
                    reclaimableBytes: catReclaimableBytes
                )
            )
        }

        summary = ScanSummary(
            scannedAt: lastScanCompletedAt,
            totalBytes: totalBytes,
            reclaimableBytes: reclaimableBytes,
            totalItemCount: totalCount,
            reclaimableItemCount: reclaimableCount,
            diskAvailableBytes: diskAvailableBytes,
            diskTotalBytes: diskTotalBytes,
            categoryMetrics: metrics
        )
    }
}
