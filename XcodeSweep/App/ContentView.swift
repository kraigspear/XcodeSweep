import SwiftUI

struct ContentView: View {
    let store: XcodeSweepStore
    /// The report whose failures the full list shows; non-nil presents it.
    @State private var failureListReport: DeletionReport?

    var body: some View {
        @Bindable var bindableStore = store

        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let progress = store.operation.deletionProgress {
                    DeletionProgressBar(
                        progress: progress,
                        onCancel: { store.cancelOperation() }
                    )
                    Divider()
                }
                DetailRouterView(store: store)
            }
        }
        .inspector(isPresented: $bindableStore.inspectorPresented) {
            StorageItemInspectorView(
                selectedItems: store.selectedItems,
                canDelete: !store.operation.isBusy,
                onDelete: { store.requestDelete(items: $0) }
            )
            .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.operation.isScanning {
                    Button {
                        store.cancelOperation()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop scanning (⌘.)")
                } else {
                    Button {
                        store.startRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.operation.isBusy)
                    .help("Rescan Xcode storage (⌘R)")
                }

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
            Button(pending.actionTitle, role: .destructive) {
                store.startDeletion(pending)
            }
            Button("Cancel", role: .cancel) {
                store.pendingDeletion = nil
            }
        } message: { pending in
            Text(pending.confirmationMessage)
        }
        .alert(
            store.lastDeletionReport?.wasCancelled == true ? "Cleanup Stopped" : "Cleanup Complete",
            item: $bindableStore.lastDeletionReport
        ) { report in
            if report.hasFailures {
                Button("Show All Failures") {
                    failureListReport = report
                }
            }
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(report.summary)
        }
        .sheet(item: $failureListReport) { report in
            FailureListView(failures: report.failures)
        }
        .task {
            await store.refreshIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
    }
}

// MARK: - Supporting Views

private struct DetailRouterView: View {
    let store: XcodeSweepStore

    var body: some View {
        switch store.browsing.destination {
        case .overview:
            OverviewView(store: store)
        case let .category(category):
            CategoryDetailView(category: category, store: store)
        }
    }
}

private struct DeletionProgressBar: View {
    let progress: DeletionProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(statusLine)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if progress.removedBytes > 0 {
                    Text("\(progress.removedBytes, format: .byteCount(style: .file)) removed")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text("\(progress.completedCount) / \(progress.totalCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Stop removing remaining items (⌘.)")
            }

            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusLine: String {
        if progress.currentItemName.isEmpty {
            return "Removing items…"
        }
        return "Removing \(progress.currentItemName)…"
    }
}

#if DEBUG && canImport(SwiftUI)
    #Preview("Overview") {
        ContentView(store: .preview())
            .frame(width: 1180, height: 760)
    }

    #Preview("DerivedData with selection") {
        ContentView(store: .preview(destination: .category(.derivedData), selectedItemIDs: ["dd-orphan"]))
            .frame(width: 1180, height: 760)
    }
#endif
