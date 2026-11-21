import AppKit
import SwiftUI

struct CategoryDetailView: View {
    let category: StorageCategory
    let store: XcodeSweepStore

    var body: some View {
        @Bindable var bindableStore = store
        let visibleItems = store.visibleItems(for: category)

        VStack(spacing: 0) {
            CategoryFilterBar(
                category: category,
                selectedFilter: $bindableStore.statusFilter,
                totalVisibleCount: visibleItems.count,
                totalVisibleBytes: visibleItems.reduce(0) { $0 + $1.sizeBytes },
                isScanning: store.isCategoryScanning(category)
            )

            Divider()

            if visibleItems.isEmpty {
                CategoryEmptyStateView(
                    category: category,
                    isScanning: store.isCategoryScanning(category),
                    hasActiveFilter: store.statusFilter != .all || !store.searchText.isEmpty,
                    onResetFilters: {
                        store.statusFilter = .all
                        store.searchText = ""
                    }
                )
            } else {
                Table(
                    visibleItems,
                    selection: $bindableStore.selectedItemIDs,
                    sortOrder: $bindableStore.sortOrder
                ) {
                    TableColumn("Name", value: \.name) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.body)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                    }
                    .width(min: 220, ideal: 340)

                    TableColumn("Status", value: \.statusSortRank) { item in
                        StatusBadgeView(status: item.status)
                    }
                    .width(min: 88, ideal: 105, max: 130)

                    TableColumn("Last Used", value: \.sortableTimestamp) { item in
                        if let date = item.lastUsedDate {
                            Text(date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Unknown")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 110, ideal: 140, max: 180)

                    TableColumn("Size", value: \.sizeBytes) { item in
                        Text(item.sizeBytes, format: .byteCount(style: .file))
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 84, ideal: 100, max: 130)
                }
                .contextMenu(forSelectionType: StorageItem.ID.self) { selectedIDs in
                    let targetItems = visibleItems.filter { selectedIDs.contains($0.id) }
                    ItemContextMenuContent(
                        items: targetItems,
                        canDelete: store.canDelete,
                        onDelete: { store.requestDelete(items: targetItems) }
                    )
                }
            }

            Divider()

            SelectionActionFooter(
                selectionPlan: store.selectionPlan,
                operation: store.operation,
                onSelectRecommended: { store.selectReclaimableInActiveCategory() },
                onSelectAll: { store.selectAllDeletableInActiveCategory() },
                onClearSelection: { store.clearSelection() },
                onRequestDelete: { store.requestDeleteSelected() }
            )
        }
        .navigationTitle(category.title)
        .searchable(text: $bindableStore.searchText, prompt: "Filter \(category.title)…")
    }
}

// MARK: - Supporting Views

private struct CategoryFilterBar: View {
    let category: StorageCategory
    @Binding var selectedFilter: ItemFilter
    let totalVisibleCount: Int
    let totalVisibleBytes: Int64
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $selectedFilter) {
                ForEach(category.availableFilters) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(
                    "\(totalVisibleCount) \(totalVisibleCount == 1 ? "item" : "items") • \(totalVisibleBytes, format: .byteCount(style: .file))"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct CategoryEmptyStateView: View {
    let category: StorageCategory
    let isScanning: Bool
    let hasActiveFilter: Bool
    let onResetFilters: () -> Void

    var body: some View {
        Group {
            if isScanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning \(category.title)…")
                        .foregroundStyle(.secondary)
                }
            } else if hasActiveFilter {
                ContentUnavailableView {
                    Label("No Matching Items", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No items in \(category.title) match the current filter or search query.")
                } actions: {
                    Button("Clear Filters", action: onResetFilters)
                }
            } else {
                ContentUnavailableView(
                    "Nothing Found in \(category.title)",
                    systemImage: category.systemImage,
                    description: Text(category.summaryDescription)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemContextMenuContent: View {
    let items: [StorageItem]
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        if items.count == 1, let item = items.first {
            if let path = item.path {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([path])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path.path, forType: .string)
                }
            }
            if let workspacePath = item.workspacePath {
                Button("Copy Workspace Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(workspacePath, forType: .string)
                }
            }
            Divider()
        }

        let plan = DeletionPlan(selection: items)
        if !plan.isEmpty {
            Button(plan.requestTitle, role: .destructive) {
                onDelete()
            }
            .disabled(!canDelete)
        }
    }
}

private struct SelectionActionFooter: View {
    let selectionPlan: DeletionPlan
    let operation: OperationState
    let onSelectRecommended: () -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Select Recommended", action: onSelectRecommended)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(operation.isDeleting)

            Button("Select All", action: onSelectAll)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(operation.isDeleting)

            if !selectionPlan.isEmpty, !operation.isDeleting {
                Button("Clear", action: onClearSelection)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            Spacer()

            if case let .deleting(progress?) = operation {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Removing \(progress.completedCount) of \(progress.totalCount)…")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if !selectionPlan.isEmpty {
                Text(
                    "\(selectionPlan.deletableItems.count) selected • \(selectionPlan.totalBytes, format: .byteCount(style: .file))"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive, action: onRequestDelete) {
                Label(selectionPlan.requestTitle, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectionPlan.isEmpty || operation.isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

#if DEBUG && canImport(SwiftUI)
    #Preview("Simulator Runtimes") {
        CategoryDetailView(category: .simulatorRuntimes, store: .preview(destination: .category(.simulatorRuntimes)))
            .frame(width: 900, height: 500)
    }

    #Preview("Empty category") {
        CategoryDetailView(category: .derivedData, store: .preview(inventory: .empty))
            .frame(width: 900, height: 500)
    }
#endif
