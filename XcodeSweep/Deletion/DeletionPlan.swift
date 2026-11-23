import Foundation

/// The items a deletion will remove, and the text every deletion control shows for them.
///
/// Pass the raw selection: protected items are counted in `protectedCount` and never deleted.
/// Plans with the same deletable items in the same order and the same protected count are equal;
/// identity is the contents, so SwiftUI sees no change when an unchanged selection mints a new plan.
struct DeletionPlan: Identifiable, Hashable, Sendable {
    let deletableItems: [StorageItem]
    /// Selected items that can't be deleted.
    let protectedCount: Int

    init(selection: [StorageItem]) {
        deletableItems = selection.filter(\.isDeletable)
        protectedCount = selection.count - deletableItems.count
    }

    var id: Self {
        self
    }

    var isEmpty: Bool {
        deletableItems.isEmpty
    }

    var totalBytes: Int64 {
        deletableItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var trashCount: Int {
        deletableItems.count - permanentCount
    }

    /// Items deleted with `simctl`, which can't be undone.
    var permanentCount: Int {
        deletableItems.filter(\.deletionMethod.isPermanent).count
    }

    /// Simulator devices, which deletion tries to shut down first.
    var deviceCount: Int {
        deletableItems.filter {
            if case .simctlDevice = $0.deletionMethod {
                return true
            }
            return false
        }.count
    }

    /// The counted button title, such as "Move 2 Items to Trash".
    ///
    /// The verb is "Delete" when every item is permanent and "Remove" for a mix.
    var actionTitle: String {
        let count = deletableItems.count
        let noun = count == 1 ? "Item" : "Items"
        if trashCount == 0 {
            return "Delete \(count) \(noun)"
        }
        if permanentCount == 0 {
            return "Move \(count) \(noun) to Trash"
        }
        return "Remove \(count) \(noun)"
    }

    /// Title for controls that open the confirmation rather than delete directly.
    var requestTitle: String {
        isEmpty ? "Delete Selected…" : "\(actionTitle)…"
    }

    /// Confirmation text giving the space reclaimed and what will be trashed, deleted permanently, or shut down.
    var confirmationMessage: String {
        let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        var parts: [String] = []

        if trashCount > 0 {
            parts.append("\(trashCount) filesystem \(plural("item", trashCount)) will be moved to Trash (reversible).")
        }
        if permanentCount > 0 {
            parts.append(
                "\(permanentCount) simulator \(plural("item", permanentCount)) will be permanently deleted using xcrun simctl."
            )
        }
        if deviceCount > 0 {
            parts.append(deviceCount == 1
                ? "XcodeSweep will try to shut the simulator down first."
                : "XcodeSweep will try to shut the simulators down first.")
        }

        return "Estimated space to reclaim: \(formattedSize).\n\n" + parts.joined(separator: " ")
    }
}

/// Live progress snapshot displayed during a batch deletion.
struct DeletionProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let currentItemName: String
    let removedBytes: Int64

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}

/// Outcome of a batch deletion operation, whether it finished or the user stopped it.
struct DeletionReport: Identifiable, Hashable, Sendable {
    let trashedCount: Int
    let simctlDeletedCount: Int
    let reclaimedBytes: Int64
    let failures: [DeletionFailure]
    /// The user stopped the run. The counts and failures are the acknowledged outcomes; an item in
    /// flight at the stop may still have been removed.
    let wasCancelled: Bool

    init(
        trashedCount: Int,
        simctlDeletedCount: Int,
        reclaimedBytes: Int64,
        failures: [DeletionFailure],
        wasCancelled: Bool = false
    ) {
        self.trashedCount = trashedCount
        self.simctlDeletedCount = simctlDeletedCount
        self.reclaimedBytes = reclaimedBytes
        self.failures = failures
        self.wasCancelled = wasCancelled
    }

    init(removed: [StorageItem], failures: [DeletionFailure], wasCancelled: Bool = false) {
        let permanentCount = removed.filter(\.deletionMethod.isPermanent).count
        self.init(
            trashedCount: removed.count - permanentCount,
            simctlDeletedCount: permanentCount,
            reclaimedBytes: removed.reduce(0) { $0 + $1.sizeBytes },
            failures: failures,
            wasCancelled: wasCancelled
        )
    }

    var id: Self {
        self
    }

    var deletedCount: Int {
        trashedCount + simctlDeletedCount
    }

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

/// An item that failed to delete, and why.
struct DeletionFailure: Hashable, Sendable {
    let itemID: StorageItem.ID
    let itemName: String
    let reason: String
}

extension DeletionMethod {
    /// How the item is removed, in words for the inspector.
    var cleanupDescription: String {
        switch self {
        case .trashFile:
            "Moves folder to Trash (reversible)"
        case .simctlDevice:
            "Tries to shut down simulator, then permanently deletes via xcrun simctl"
        case .simctlRuntime:
            "Permanently deletes runtime disk image via xcrun simctl runtime delete"
        case let .notDeletable(reason):
            "Protected: \(reason)"
        }
    }
}

extension DeletionReport {
    /// Completion alert text; failures are capped so the alert stays readable.
    var summary: String {
        let reclaimed = ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
        let removed = "\(deletedCount) \(plural("item", deletedCount)) (~\(reclaimed))"
        var lines = [wasCancelled ? "Stopped after removing \(removed)." : "Removed \(removed)."]

        if trashedCount > 0 {
            lines.append("Moved \(trashedCount) to Trash (empty Trash to free disk space immediately).")
        }
        if simctlDeletedCount > 0 {
            lines.append("Deleted \(simctlDeletedCount) via xcrun simctl.")
        }
        if hasFailures {
            let failureText = failures
                .prefix(4)
                .map { "• \($0.itemName): \($0.reason)" }
                .joined(separator: "\n")
            lines.append("\nCould not remove \(failures.count):\n\(failureText)")
        }

        return lines.joined(separator: "\n")
    }
}

private func plural(_ noun: String, _ count: Int) -> String {
    count == 1 ? noun : noun + "s"
}
