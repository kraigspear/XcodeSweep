import SwiftUI

struct ContentView: View {
    let store: XcodeSweepStore

    var body: some View {
        @Bindable var bindableStore = store

        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            DetailRouterView(store: store)
                .overlay(alignment: .top) {
                    if let progressText = store.deletionProgressText {
                        DeletionProgressBanner(message: progressText)
                    }
                }
        }
        .inspector(isPresented: $bindableStore.inspectorPresented) {
            StorageItemInspectorView(
                selectedItems: store.selectedItems,
                onDelete: { store.requestDelete(items: $0) }
            )
            .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning || store.isDeleting)
                .help("Rescan Xcode storage (⌘R)")

                Button {
                    store.inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle Inspector (⌥⌘I)")
            }
        }
        .confirmationDialog(
            "Confirm Cleanup",
            item: $bindableStore.pendingDeletion
        ) { pending in
            Button(pending.actionButtonTitle, role: .destructive) {
                Task {
                    await store.confirmPendingDeletion()
                }
            }
            Button("Cancel", role: .cancel) {
                store.pendingDeletion = nil
            }
        } message: { pending in
            Text(pending.confirmationMessage)
        }
        .alert("Cleanup Complete", item: $bindableStore.lastDeletionReport) { _ in
        } message: { report in
            Text(deletionReportSummary(report))
        }
        .alert("Scan Error", item: $bindableStore.errorMessage) { _ in
        } message: { message in
            Text(message)
        }
        .task {
            if store.summary.scannedAt == .distantPast {
                await store.refresh()
            }
        }
    }

    private func deletionReportSummary(_ report: DeletionReport) -> String {
        let reclaimed = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
        var lines: [String] = []
        lines.append("Removed \(report.deletedCount) \(report.deletedCount == 1 ? "item" : "items") (~\(reclaimed)).")

        if report.trashedCount > 0 {
            lines.append("Moved \(report.trashedCount) to Trash (empty Trash to free disk space immediately).")
        }
        if report.simctlDeletedCount > 0 {
            lines.append("Deleted \(report.simctlDeletedCount) via xcrun simctl.")
        }
        if report.hasFailures {
            let failureText = report.failures
                .prefix(4)
                .map { "• \($0.itemName): \($0.reason)" }
                .joined(separator: "\n")
            lines.append("\nCould not remove \(report.failures.count):\n\(failureText)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Supporting Views

private struct DetailRouterView: View {
    let store: XcodeSweepStore

    var body: some View {
        switch store.sidebarSelection {
        case .overview:
            OverviewView(store: store)
        case let .category(category):
            CategoryDetailView(category: category, store: store)
        }
    }
}

private struct DeletionProgressBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
        .padding(.top, 10)
    }
}
