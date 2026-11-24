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
            MultiItemInspectorContent(
                selectionCount: selectedItems.count,
                plan: DeletionPlan(selection: selectedItems),
                canDelete: canDelete,
                onDelete: { onDelete(selectedItems) }
            )
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

                Text(item.isReclaimable ? "Recommended: \(item.statusExplanation)" : item.statusExplanation)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    LabeledInspectorRow(
                        label: "Cleanup Action",
                        value: item.deletionMethod.cleanupDescription
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
                            Label(DeletionPlan(selection: [item]).requestTitle, systemImage: "trash")
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
}

private struct MultiItemInspectorContent: View {
    let selectionCount: Int
    let plan: DeletionPlan
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectionCount) Items Selected")
                    .font(.headline)
                Text(plan.totalBytes, format: .byteCount(style: .file))
                    .font(.title2.bold().monospacedDigit())
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if plan.trashCount > 0 {
                    LabeledInspectorRow(label: "Move to Trash", value: "\(plan.trashCount) items (reversible)")
                }
                if plan.permanentCount > 0 {
                    LabeledInspectorRow(label: "Delete with simctl", value: "\(plan.permanentCount) items (permanent)")
                }
                if plan.protectedCount > 0 {
                    LabeledInspectorRow(label: "Protected (Skipped)", value: "\(plan.protectedCount) items")
                }
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label(plan.requestTitle, systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(plan.isEmpty || !canDelete)
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

#if DEBUG && canImport(SwiftUI)
    #Preview("Single item") {
        StorageItemInspectorView(selectedItems: [StorageItem.previewItems[0]], canDelete: true, onDelete: { _ in })
            .frame(width: 300, height: 600)
    }

    #Preview("Multiple items") {
        StorageItemInspectorView(selectedItems: StorageItem.previewItems, canDelete: true, onDelete: { _ in })
            .frame(width: 300, height: 600)
    }

    #Preview("No selection") {
        StorageItemInspectorView(selectedItems: [], canDelete: true, onDelete: { _ in })
            .frame(width: 300, height: 600)
    }
#endif
