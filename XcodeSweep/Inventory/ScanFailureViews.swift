import SwiftUI

/// A compact "Scan incomplete" mark for a category whose scan couldn't read everything.
struct ScanFailureBadge: View {
    let failure: String

    var body: some View {
        Label("Scan incomplete", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .help(failure)
    }
}

/// Explains, above a category's items, why some may be missing.
struct CategoryScanFailureBanner: View {
    let category: StorageCategory
    let failure: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Couldn't fully scan \(category.title)", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(failure)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}
