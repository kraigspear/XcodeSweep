import Foundation

/// How a storage item is removed when the user confirms deletion.
enum DeletionMethod: Equatable, Hashable, Sendable {
    /// Moves the filesystem path to the user's Trash (reversible).
    case trashFile(URL)
    /// Deletes a simulator device via `xcrun simctl [--set previews] delete <udid>` (permanent).
    case simctlDevice(udid: String, deviceSet: SimulatorDeviceSet = .standard)
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

/// A set of simulator devices that CoreSimulator manages.
enum SimulatorDeviceSet: Hashable, Sendable {
    /// The set Simulator.app and `simctl` use by default.
    case standard
    /// Xcode's SwiftUI preview devices, in `UserData/Previews/Simulator Devices`.
    case previews

    /// The arguments that select this set, placed right after `simctl`.
    var simctlArguments: [String] {
        switch self {
        case .standard: []
        case .previews: ["--set", "previews"]
        }
    }
}

/// Status badge surfaced in the table and used for quick filters.
enum ItemStatus: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Not unused by age: used within `staleAfterDays`, last use unknown, or a category that never ages.
    case active
    /// DerivedData with no recorded workspace, or whose workspace is provably gone.
    case orphaned
    /// DerivedData whose workspace path looks like a git worktree: it contains "worktree" or sits under a `.git` file.
    case worktree
    /// A simulator device that `simctl` reports as unavailable.
    case unavailable
    /// A simulator device that was running at scan time.
    case booted
    /// Last used more than the category's `staleAfterDays` ago (DerivedData's, for the module cache); shown as "Unused".
    case stale
    /// A simulator runtime that Xcode or macOS manages and `simctl` won't delete.
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

    /// Plain-language list of the reclaimable statuses, such as "orphaned, unavailable, or unused".
    static var reclaimableStatusSummary: String {
        let labels = allCases.filter(\.isReclaimable).map { $0.label.lowercased() }
        guard labels.count > 1, let last = labels.last else { return labels.first ?? "" }
        return labels.dropLast().joined(separator: ", ") + ", or " + last
    }

    /// Whether a deletable item with this status is reclaimable.
    var isReclaimable: Bool {
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
    /// A key stable across scans, such as `simDevice:<udid>` or `derivedData:<path>`.
    let id: String
    let category: StorageCategory
    let name: String
    /// Secondary line under the name, such as the runtime and state or the workspace location.
    var subtitle: String
    let sizeBytes: Int64
    let lastUsedDate: Date?
    let path: URL?
    /// The project or workspace a DerivedData folder was built from.
    let workspacePath: String?
    let status: ItemStatus
    let deletionMethod: DeletionMethod
    let metadata: [MetadataEntry]

    var isDeletable: Bool {
        deletionMethod.isDeletable
    }

    /// Whether the item is deletable and its status is reclaimable.
    var isReclaimable: Bool {
        isDeletable && status.isReclaimable
    }

    /// `lastUsedDate` as seconds since 1970; items never used sort as 0.
    var sortableTimestamp: TimeInterval {
        lastUsedDate?.timeIntervalSince1970 ?? 0
    }

    /// Sort position for the status column, most reclaimable first.
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

/// One labeled detail row in the inspector.
struct MetadataEntry: Identifiable, Equatable, Hashable, Sendable {
    var id: String {
        key
    }

    let key: String
    let value: String
}
