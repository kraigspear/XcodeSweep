import Foundation

/// Top-level storage categories managed by XcodeSweep.
enum StorageCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case derivedData
    case simulatorDevices
    case simulatorRuntimes
    case deviceSupport
    case previews
    case archivesAndCaches

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .derivedData:
            "DerivedData"
        case .simulatorDevices:
            "Simulator Devices"
        case .simulatorRuntimes:
            "Simulator Runtimes"
        case .deviceSupport:
            "Device Support"
        case .previews:
            "SwiftUI Previews"
        case .archivesAndCaches:
            "Archives & Caches"
        }
    }

    var systemImage: String {
        switch self {
        case .derivedData:
            "hammer"
        case .simulatorDevices:
            "iphone.gen3"
        case .simulatorRuntimes:
            "opticaldiscdrive"
        case .deviceSupport:
            "cpu"
        case .previews:
            "rectangle.on.rectangle"
        case .archivesAndCaches:
            "archivebox"
        }
    }

    // MARK: - Status Rules

    /// Days without use after which an item counts as unused; `nil` when age never makes an item unused.
    var staleAfterDays: Int? {
        switch self {
        case .derivedData, .simulatorDevices:
            30
        case .simulatorRuntimes, .deviceSupport, .previews:
            45
        case .archivesAndCaches:
            nil
        }
    }

    /// Every status a scan of this category can assign. Filters are offered only for these.
    var possibleStatuses: Set<ItemStatus> {
        switch self {
        case .derivedData:
            [.orphaned, .worktree, .stale, .active]
        case .simulatorDevices:
            [.unavailable, .booted, .stale, .active]
        case .simulatorRuntimes:
            [.systemManaged, .stale, .active]
        case .deviceSupport, .previews, .archivesAndCaches:
            [.stale, .active]
        }
    }

    /// `.stale` once `lastUsed` is more than `staleAfterDays` before `now`; otherwise `.active`.
    func ageStatus(lastUsed: Date?, now: Date) -> ItemStatus {
        guard let staleAfterDays, let lastUsed else { return .active }
        return now.timeIntervalSince(lastUsed) > TimeInterval(staleAfterDays) * 86400 ? .stale : .active
    }

    /// Status filters worth offering; statuses a category never produces are left out.
    var availableFilters: [ItemFilter] {
        ItemFilter.allCases.filter { filter in
            guard let status = filter.status else { return true }
            return possibleStatuses.contains(status)
        }
    }

    var summaryDescription: String {
        switch self {
        case .derivedData:
            "Per-project and per-worktree build artifacts in Xcode's DerivedData folder."
        case .simulatorDevices:
            "Simulator data containers in ~/Library/Developer/CoreSimulator/Devices."
        case .simulatorRuntimes:
            "Installed simulator runtime disk images managed by CoreSimulator."
        case .deviceSupport:
            "Debug symbols cached from physical iOS, watchOS, tvOS, and visionOS devices."
        case .previews:
            "Xcode SwiftUI Preview simulator devices in UserData/Previews."
        case .archivesAndCaches:
            "Xcode .xcarchive builds and the build caches Xcode shares in DerivedData."
        }
    }
}

/// Sidebar navigation destination.
enum SidebarSelection: Hashable, Identifiable, Sendable {
    case overview
    case category(StorageCategory)

    var id: String {
        switch self {
        case .overview:
            "overview"
        case let .category(category):
            category.rawValue
        }
    }
}
