import AppKit
import SwiftUI

struct StorageItemInspectorView: View {
    let selectedItems: [StorageItem]
    let canDelete: Bool
    let onDelete: ([StorageItem]) -> Void

    var body: some View {
        if selectedItems.isEmpty {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right",
                description: Text("Select an item to inspect its path, status, and cleanup method.")
            )
        } else if selectedItems.count == 1, let item = selectedItems.first {
            SingleItemInspectorContent(item: item, canDelete: canDelete, onDelete: { onDelete([item]) })
        } else {
            MultiItemInspectorContent(items: selectedItems, canDelete: canDelete, onDelete: { onDelete(selectedItems) })
        }
    }
}

// MARK: - Supporting Views

private struct SingleItemInspectorContent: View {
    let item: StorageItem
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.category.systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            StatusBadgeView(status: item.status)
                            Text(item.sizeBytes, format: .byteCount(style: .file))
                                .font(.callout.bold().monospacedDigit())
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledInspectorRow(
                        label: "Cleanup Action",
                        value: cleanupDescription(for: item.deletionMethod)
                    )

                    if let lastUsed = item.lastUsedDate {
                        LabeledInspectorRow(
                            label: "Last Used",
                            value: lastUsed.formatted(date: .abbreviated, time: .shortened)
                        )
                    }

                    ForEach(item.metadata) { entry in
                        LabeledInspectorRow(label: entry.key, value: entry.value)
                    }
                }

                Divider()

                VStack(spacing: 8) {
                    if let path = item.path {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([path])
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if item.isDeletable {
                        Button(role: .destructive, action: onDelete) {
                            Label(
                                item.deletionMethod.isPermanent ? "Delete via simctl…" : "Move to Trash…",
                                systemImage: "trash"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(!canDelete)
                    }
                }
            }
            .padding(16)
        }
    }

    private func cleanupDescription(for method: DeletionMethod) -> String {
        switch method {
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

private struct MultiItemInspectorContent: View {
    let items: [StorageItem]
    let canDelete: Bool
    let onDelete: () -> Void

    private var deletableItems: [StorageItem] {
        items.filter(\.isDeletable)
    }

    private var totalBytes: Int64 {
        deletableItems.reduce(0) { $0 + $1.sizeBytes }
    }

    private var trashCount: Int {
        deletableItems.filter { !$0.deletionMethod.isPermanent }.count
    }

    private var simctlCount: Int {
        deletableItems.filter { $0.deletionMethod.isPermanent }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count) Items Selected")
                    .font(.headline)
                Text(totalBytes, format: .byteCount(style: .file))
                    .font(.title2.bold().monospacedDigit())
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if trashCount > 0 {
                    LabeledInspectorRow(label: "Move to Trash", value: "\(trashCount) items (reversible)")
                }
                if simctlCount > 0 {
                    LabeledInspectorRow(label: "xcrun simctl delete", value: "\(simctlCount) items (permanent)")
                }
                let protectedCount = items.count - deletableItems.count
                if protectedCount > 0 {
                    LabeledInspectorRow(label: "Protected (Skipped)", value: "\(protectedCount) items")
                }
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label("Remove \(deletableItems.count) Items…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(deletableItems.isEmpty || !canDelete)
        }
        .padding(16)
    }
}

private struct LabeledInspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
