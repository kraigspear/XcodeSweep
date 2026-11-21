import Foundation

/// Aggregated statistics for a single storage category.
struct CategoryMetrics: Identifiable, Equatable, Hashable, Sendable {
    let category: StorageCategory
    let itemCount: Int
    let totalBytes: Int64
    let reclaimableCount: Int
    let reclaimableBytes: Int64

    var id: StorageCategory { category }
}

/// Snapshot of disk capacity and scanned Xcode storage totals.
struct ScanSummary: Equatable, Sendable {
    let scannedAt: Date
    let totalBytes: Int64
    let reclaimableBytes: Int64
    let totalItemCount: Int
    let reclaimableItemCount: Int
    let diskAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let categoryMetrics: [CategoryMetrics]

    static let empty = ScanSummary(
        scannedAt: .distantPast,
        totalBytes: 0,
        reclaimableBytes: 0,
        totalItemCount: 0,
        reclaimableItemCount: 0,
        diskAvailableBytes: nil,
        diskTotalBytes: nil,
        categoryMetrics: StorageCategory.allCases.map {
            CategoryMetrics(
                category: $0,
                itemCount: 0,
                totalBytes: 0,
                reclaimableCount: 0,
                reclaimableBytes: 0
            )
        }
    )
}

/// Outcome of a batch deletion operation.
struct DeletionReport: Equatable, Identifiable, Sendable {
    let id = UUID()
    let deletedCount: Int
    let trashedCount: Int
    let simctlDeletedCount: Int
    let reclaimedBytes: Int64
    let failures: [DeletionFailure]

    var hasFailures: Bool {
        !failures.isEmpty
    }
}

struct DeletionFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let itemName: String
    let reason: String
}
