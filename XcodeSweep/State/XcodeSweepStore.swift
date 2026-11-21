import Foundation
import Observation

enum ItemFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    case reclaimable
    case orphaned
    case worktree
    case unavailable
    case stale

    var id: String { rawValue }

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
            parts.append("\(trashedCount) filesystem \(trashedCount == 1 ? "item" : "items") will be moved to Trash (reversible).")
        }
        if simctlCount > 0 {
            parts.append("\(simctlCount) simulator \(simctlCount == 1 ? "item" : "items") will be permanently deleted using xcrun simctl.")
        }
        if bootedDeviceCount > 0 {
            parts.append("\(bootedDeviceCount) booted \(bootedDeviceCount == 1 ? "simulator" : "simulators") will be shut down first.")
        }

        return "Estimated space to reclaim: \(formattedSize).\n\n" + parts.joined(separator: " ")
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
    var searchText: String = ""
    var statusFilter: ItemFilter = .all
    var sortOrder: [KeyPathComparator<StorageItem>] = [
        KeyPathComparator(\.sizeBytes, order: .reverse),
    ]
    var inspectorPresented: Bool = true

    private(set) var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
    private(set) var summary: ScanSummary = .empty
    private(set) var isScanning: Bool = false
    private(set) var completedCategories: Set<StorageCategory> = []
    private(set) var isDeleting: Bool = false
    private(set) var deletionProgressText: String?
    private(set) var scanWarnings: [String] = []
    var pendingDeletion: PendingDeletion?
    var lastDeletionReport: DeletionReport?
    var errorMessage: String?

    private var diskAvailableBytes: Int64?
    private var diskTotalBytes: Int64?

    private let scanner: any StorageScanning
    private let deleter: any StorageDeleting

    // MARK: - Initialization

    init(
        scanner: any StorageScanning = LiveStorageService(),
        deleter: any StorageDeleting = LiveStorageService()
    ) {
        self.scanner = scanner
        self.deleter = deleter
    }

    // MARK: - Scanning

    func refresh() async {
        guard !isScanning, !isDeleting else { return }

        isScanning = true
        completedCategories = []
        scanWarnings = []
        errorMessage = nil
        defer { isScanning = false }

        do {
            let snapshot = try await scanner.scanAll { [weak self] category, items in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.itemsByCategory[category] = items
                    self.completedCategories.insert(category)
                    self.rebuildSummary()
                }
            }

            itemsByCategory = snapshot.itemsByCategory
            diskAvailableBytes = snapshot.diskAvailableBytes
            diskTotalBytes = snapshot.diskTotalBytes
            scanWarnings = snapshot.warnings
            completedCategories = Set(StorageCategory.allCases)
            pruneStaleSelection()
            rebuildSummary()
        } catch {
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
        isScanning && !completedCategories.contains(category)
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
        let deletable = items.filter(\.isDeletable)
        guard !deletable.isEmpty else { return }
        pendingDeletion = PendingDeletion(items: deletable)
    }

    func confirmPendingDeletion() async {
        guard let pending = pendingDeletion, !isDeleting else { return }
        pendingDeletion = nil
        isDeleting = true
        deletionProgressText = "Preparing to remove \(pending.items.count) items…"

        let report = await deleter.delete(items: pending.items) { [weak self] completed, total, name in
            Task { @MainActor [weak self] in
                self?.deletionProgressText = "Removing \(completed) of \(total): \(name)"
            }
        }

        let failedNames = Set(report.failures.map(\.itemName))
        let removedIDs = Set(
            pending.items
                .filter { !failedNames.contains($0.name) }
                .map(\.id)
        )

        for category in StorageCategory.allCases {
            if var list = itemsByCategory[category] {
                list.removeAll { removedIDs.contains($0.id) }
                itemsByCategory[category] = list
            }
        }

        selectedItemIDs.subtract(removedIDs)
        rebuildSummary()

        isDeleting = false
        deletionProgressText = nil
        lastDeletionReport = report
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
            scannedAt: Date(),
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
