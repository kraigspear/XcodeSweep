import SwiftUI

struct SidebarView: View {
    let store: XcodeSweepStore

    var body: some View {
        @Bindable var bindableStore = store

        List(selection: $bindableStore.sidebarSelection) {
            Section {
                SidebarOverviewRow(
                    totalBytes: store.inventory.totalBytes,
                    isScanning: store.isScanning
                )
                .tag(SidebarSelection.overview)
            }

            Section("Xcode Storage") {
                ForEach(store.inventory.categoryMetrics) { metrics in
                    SidebarCategoryRow(
                        metrics: metrics,
                        isScanning: store.isCategoryScanning(metrics.category)
                    )
                    .tag(SidebarSelection.category(metrics.category))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            DiskFooterView(
                availableBytes: store.inventory.diskAvailableBytes,
                totalBytes: store.inventory.diskTotalBytes
            )
        }
    }
}

// MARK: - Supporting Views

private struct SidebarOverviewRow: View {
    let totalBytes: Int64
    let isScanning: Bool

    var body: some View {
        HStack {
            Label("Overview", systemImage: "chart.bar.xaxis")
            Spacer()
            if isScanning && totalBytes == 0 {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(totalBytes, format: .byteCount(style: .file))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SidebarCategoryRow: View {
    let metrics: CategoryMetrics
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(metrics.category.title, systemImage: metrics.category.systemImage)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(metrics.totalBytes, format: .byteCount(style: .file))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(metrics.totalBytes > 0 ? .primary : .secondary)
                    if metrics.reclaimableCount > 0 {
                        Text("\(metrics.reclaimableCount) cleanable")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct DiskFooterView: View {
    let availableBytes: Int64?
    let totalBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let availableBytes, let totalBytes, totalBytes > 0 {
                let usedFraction = max(0, min(1, 1 - (Double(availableBytes) / Double(totalBytes))))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Macintosh HD")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(availableBytes, format: .byteCount(style: .file)) free")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    ProgressView(value: usedFraction)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 4)
            }
        }
        .background(.bar)
    }
}
