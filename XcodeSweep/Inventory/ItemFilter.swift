import Foundation

/// Status filter offered above a category table.
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
