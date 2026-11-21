import Charts
import SwiftUI

struct OverviewView: View {
    let store: XcodeSweepStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OverviewKPIHeader(
                    totalBytes: store.inventory.totalBytes,
                    totalItems: store.inventory.totalItemCount,
                    reclaimableBytes: store.inventory.reclaimableBytes,
                    reclaimableItems: store.inventory.reclaimableItemCount,
                    diskAvailableBytes: store.inventory.diskAvailableBytes,
                    isScanning: store.isScanning
                )

                if !store.scanWarnings.isEmpty {
                    ScanWarningsBanner(warnings: store.scanWarnings)
                }

                StorageBreakdownChartCard(metrics: store.inventory.categoryMetrics)

                CategoryGridSection(
                    metrics: store.inventory.categoryMetrics,
                    isCategoryScanning: { store.isCategoryScanning($0) },
                    onOpenCategory: { category in
                        store.navigate(to: .category(category))
                    },
                    onSelectReclaimable: { category in
                        store.openCategoryAndSelectReclaimable(category)
                    }
                )
            }
            .padding(20)
        }
        .navigationTitle("Xcode Storage Overview")
    }
}

// MARK: - Supporting Views

private struct OverviewKPIHeader: View {
    let totalBytes: Int64
    let totalItems: Int
    let reclaimableBytes: Int64
    let reclaimableItems: Int
    let diskAvailableBytes: Int64?
    let isScanning: Bool

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                SummaryStatCard(
                    title: "Total Xcode Storage",
                    valueText: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
                    footnote: isScanning ? "Scanning…" : "\(totalItems) items scanned",
                    systemImage: "externaldrive.fill",
                    tint: .blue
                )

                SummaryStatCard(
                    title: "Recommended Cleanup",
                    valueText: ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file),
                    footnote: "\(reclaimableItems) \(ItemStatus.cleanupRecommendationSummary)",
                    systemImage: "sparkles",
                    tint: .orange
                )

                SummaryStatCard(
                    title: "Mac Available Space",
                    valueText: diskAvailableBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "—",
                    footnote: "Volume free capacity",
                    systemImage: "internaldrive",
                    tint: .green
                )
            }
        }
    }
}

private struct SummaryStatCard: View {
    let title: String
    let valueText: String
    let footnote: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(valueText)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(.primary)

            Text(footnote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct StorageBreakdownChartCard: View {
    let metrics: [CategoryMetrics]

    private var sortedMetrics: [CategoryMetrics] {
        metrics
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    private var maxDomainGigabytes: Double {
        let maxBytes = sortedMetrics.map(\.totalBytes).max() ?? 0
        let maxGB = Double(maxBytes) / 1_000_000_000
        return max(1, maxGB * 1.18)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Storage by Category")
                .font(.headline)

            if sortedMetrics.isEmpty {
                ContentUnavailableView(
                    "No Storage Data Yet",
                    systemImage: "chart.bar",
                    description: Text("Run a scan to visualize Xcode disk usage.")
                )
                .frame(height: 180)
            } else {
                Chart(sortedMetrics) { item in
                    BarMark(
                        x: .value("Size (GB)", Double(item.totalBytes) / 1_000_000_000),
                        y: .value("Category", item.category.title),
                        height: .fixed(18)
                    )
                    .foregroundStyle(by: .value("Category", item.category.title))
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading, spacing: 8) {
                        Text(item.totalBytes, format: .byteCount(style: .file))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: 0 ... maxDomainGigabytes)
                .chartYAxis {
                    AxisMarks(preset: .aligned, position: .leading) { _ in
                        AxisValueLabel()
                            .font(.callout)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .chartXAxisLabel("Gigabytes (GB)", alignment: .leading)
                .frame(height: CGFloat(max(200, sortedMetrics.count * 40)))
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CategoryGridSection: View {
    let metrics: [CategoryMetrics]
    let isCategoryScanning: (StorageCategory) -> Bool
    let onOpenCategory: (StorageCategory) -> Void
    let onSelectReclaimable: (StorageCategory) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 290, maximum: 480), spacing: 14),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(metrics) { metric in
                    CategoryCardView(
                        metrics: metric,
                        isScanning: isCategoryScanning(metric.category),
                        onOpen: { onOpenCategory(metric.category) },
                        onSelectReclaimable: { onSelectReclaimable(metric.category) }
                    )
                }
            }
        }
    }
}

private struct CategoryCardView: View {
    let metrics: CategoryMetrics
    let isScanning: Bool
    let onOpen: () -> Void
    let onSelectReclaimable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(metrics.category.title, systemImage: metrics.category.systemImage)
                    .font(.headline)
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(metrics.totalBytes, format: .byteCount(style: .file))
                        .font(.headline.monospacedDigit())
                }
            }

            Text(metrics.category.summaryDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            HStack {
                Text("\(metrics.itemCount) \(metrics.itemCount == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if metrics.reclaimableCount > 0 {
                    Button("Review \(metrics.reclaimableCount) Cleanable") {
                        onSelectReclaimable()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Open") {
                    onOpen()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ScanWarningsBanner: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Some scanners reported warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

#if DEBUG && canImport(SwiftUI)
    #Preview {
        OverviewView(store: .preview())
            .frame(width: 900, height: 760)
    }
#endif
