import Foundation
import Testing
@testable import XcodeSweep

@Suite("StorageCategory")
struct StorageCategoryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Verifies an item becomes Unused only once it passes its category's age limit, not on the limit itself.
    /// To replicate: not reachable from the UI on demand (needs a folder last used exactly 30 days before a scan, to
    /// the second); covered only here.
    @Test("Age status flips to stale only after the category's limit", arguments: [
        (StorageCategory.derivedData, 30),
        (.simulatorDevices, 30),
        (.simulatorRuntimes, 45),
        (.deviceSupport, 45),
        (.previews, 45),
    ])
    func ageStatus_atAndPastLimit_staysActiveThenStale(category: StorageCategory, days: Int) {
        let atLimit = now.addingTimeInterval(-TimeInterval(days) * 86400)

        #expect(category.ageStatus(lastUsed: atLimit, now: now) == .active)
        #expect(category.ageStatus(lastUsed: atLimit.addingTimeInterval(-1), now: now) == .stale)
        #expect(category.ageStatus(lastUsed: nil, now: now) == .active)
    }

    /// Verifies Archives & Caches never ages into Unused; a years-old archive stays Active.
    /// To replicate: keep an .xcarchive from years ago → open Archives & Caches → it shows Active.
    @Test("Archives & Caches never ages into stale")
    func ageStatus_archivesAndCaches_neverStale() {
        #expect(StorageCategory.archivesAndCaches.ageStatus(lastUsed: .distantPast, now: now) == .active)
    }

    /// Verifies each category offers a filter for exactly the filterable statuses its scan can assign.
    /// To replicate: open each category → the filter bar lists only statuses that can appear in it.
    @Test("Filters follow the statuses each category can produce", arguments: [
        (StorageCategory.derivedData, [ItemFilter.all, .reclaimable, .orphaned, .worktree, .stale]),
        (.simulatorDevices, [.all, .reclaimable, .unavailable, .stale]),
        (.simulatorRuntimes, [.all, .reclaimable, .stale]),
        (.deviceSupport, [.all, .reclaimable, .stale]),
        (.previews, [.all, .reclaimable, .unavailable, .stale]),
        (.archivesAndCaches, [.all, .reclaimable, .stale]),
    ])
    func availableFilters_matchPossibleStatuses(category: StorageCategory, expected: [ItemFilter]) {
        #expect(category.availableFilters == expected)
    }

    /// Verifies each single-status filter shows exactly the rows with its status.
    /// To replicate: in DerivedData choose Orphaned, then Worktrees → each lists only rows with that badge.
    @Test("Single-status filters select only their status", arguments: [
        (ItemFilter.orphaned, ItemStatus.orphaned),
        (.worktree, .worktree),
        (.unavailable, .unavailable),
        (.stale, .stale),
    ])
    func matches_singleStatusFilter_selectsOnlyThatStatus(filter: ItemFilter, status: ItemStatus) {
        for candidate in ItemStatus.allCases {
            let item = makeStorageItem(id: candidate.rawValue, status: candidate)
            #expect(filter.matches(item) == (candidate == status), "\(filter) vs \(candidate)")
        }
    }
}
