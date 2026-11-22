import Foundation

/// Status filter offered above a category table.
enum ItemFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
    case all
    /// Reclaimable items; titled "Recommended".
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

    /// The single status this filter selects; `nil` for filters that aren't one status.
    var status: ItemStatus? {
        switch self {
        case .all, .reclaimable: nil
        case .orphaned: .orphaned
        case .worktree: .worktree
        case .unavailable: .unavailable
        case .stale: .stale
        }
    }

    func matches(_ item: StorageItem) -> Bool {
        switch self {
        case .all:
            true
        case .reclaimable:
            item.isReclaimable
        case .orphaned, .worktree, .unavailable, .stale:
            item.status == status
        }
    }
}
