import Foundation

/// What a cleanup of a raw selection will remove, and the copy every deletion surface shows for it.
///
/// Protected items are partitioned out here so no caller has to pre-filter the selection.
struct DeletionPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let deletableItems: [StorageItem]
    let protectedCount: Int

    init(selection: [StorageItem]) {
        deletableItems = selection.filter(\.isDeletable)
        protectedCount = selection.count - deletableItems.count
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

    var permanentCount: Int {
        deletableItems.filter(\.deletionMethod.isPermanent).count
    }

    var bootedDeviceCount: Int {
        deletableItems.filter {
            if case .simctlDevice(_, isBooted: true) = $0.deletionMethod {
                return true
            }
            return false
        }.count
    }

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
        if bootedDeviceCount > 0 {
            parts.append(
                "\(bootedDeviceCount) booted \(plural("simulator", bootedDeviceCount)) will be shut down first."
            )
        }

        return "Estimated space to reclaim: \(formattedSize).\n\n" + parts.joined(separator: " ")
    }
}

extension DeletionMethod {
    var cleanupDescription: String {
        switch self {
        case .trashFile:
            "Moves folder to Trash (reversible)"
        case let .simctlDevice(_, isBooted):
            isBooted
                ? "Shuts down simulator, then permanently deletes via xcrun simctl"
                : "Permanently deletes via xcrun simctl delete"
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
        var lines = ["Removed \(deletedCount) \(plural("item", deletedCount)) (~\(reclaimed))."]

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
