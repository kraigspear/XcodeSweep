import Foundation

/// How a storage item is removed when the user confirms deletion.
enum DeletionMethod: Equatable, Hashable, Sendable {
    /// Moves the filesystem path to the user's Trash (reversible).
    case trashFile(URL)
    /// Deletes a simulator device via `xcrun simctl delete <udid>` (permanent).
    case simctlDevice(udid: String, isBooted: Bool)
    /// Deletes a simulator runtime disk image via `xcrun simctl runtime delete <identifier>` (permanent).
    case simctlRuntime(identifier: String)
    /// Cannot be deleted (for example, a system-managed non-deletable runtime).
    case notDeletable(reason: String)

    var isDeletable: Bool {
        if case .notDeletable = self {
            return false
        }
        return true
    }

    var isPermanent: Bool {
        switch self {
        case .trashFile, .notDeletable:
            false
        case .simctlDevice, .simctlRuntime:
            true
        }
    }
}

/// Status badge surfaced in the table and used for quick filters.
enum ItemStatus: String, Equatable, Hashable, Sendable {
    case active
    case orphaned
    case worktree
    case unavailable
    case booted
    case stale
    case systemManaged

    var label: String {
        switch self {
        case .active:
            "Active"
        case .orphaned:
            "Orphaned"
        case .worktree:
            "Worktree"
        case .unavailable:
            "Unavailable"
        case .booted:
            "Booted"
        case .stale:
            "Unused"
        case .systemManaged:
            "System"
        }
    }

    var isRecommendedForCleanup: Bool {
        switch self {
        case .orphaned, .unavailable, .stale:
            true
        case .active, .worktree, .booted, .systemManaged:
            false
        }
    }
}

/// A single inspectable and (optionally) deletable Xcode storage artifact.
struct StorageItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let category: StorageCategory
    let name: String
    let subtitle: String
    let sizeBytes: Int64
    let lastUsedDate: Date?
    let path: URL?
    let workspacePath: String?
    let status: ItemStatus
    let deletionMethod: DeletionMethod
    let metadata: [MetadataEntry]

    var isDeletable: Bool {
        deletionMethod.isDeletable
    }

    var isReclaimableCandidate: Bool {
        isDeletable && status.isRecommendedForCleanup
    }

    /// Sortable timestamp fallback so nil dates sort consistently.
    var sortableTimestamp: TimeInterval {
        lastUsedDate?.timeIntervalSince1970 ?? 0
    }

    var statusSortRank: Int {
        switch status {
        case .orphaned: 0
        case .unavailable: 1
        case .stale: 2
        case .worktree: 3
        case .active: 4
        case .booted: 5
        case .systemManaged: 6
        }
    }
}

struct MetadataEntry: Identifiable, Equatable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let value: String
}
