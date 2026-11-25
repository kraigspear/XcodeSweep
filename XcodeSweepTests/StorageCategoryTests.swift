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
    func ageAssessment_atAndPastLimit_staysActiveThenStale(category: StorageCategory, days: Int) {
        let atLimit = now.addingTimeInterval(-TimeInterval(days) * 86400)

        #expect(category.ageAssessment(lastUsed: atLimit, now: now).status == .active)
        let justPast = category.ageAssessment(lastUsed: atLimit.addingTimeInterval(-1), now: now)
        #expect(justPast.status == .stale)
        #expect(
            justPast.explanation
                == "Last used more than \(days) days ago, past the \(days)-day limit for \(category.title)."
        )
        #expect(category.ageAssessment(lastUsed: nil, now: now).status == .active)
    }

    /// Verifies the reason shown for an Unused item gives the days since its last use and the limit it passed.
    /// To replicate: select a simulator runtime last used 47 days ago → read the line under its badge in the inspector.
    @Test("An unused item's explanation names the days since use and the category's limit")
    func ageAssessment_pastLimit_explainsDaysAndLimit() {
        let assessment = StorageCategory.simulatorRuntimes.ageAssessment(
            lastUsed: now.addingTimeInterval(-47 * 86400),
            now: now
        )

        #expect(assessment.explanation == "Last used 47 days ago, past the 45-day limit for Simulator Runtimes.")
    }

    /// Verifies an Active item's reason says which limit it is within, or that its last use isn't known.
    /// To replicate: select a DerivedData folder built today, then one with no Last Used date → read the inspector line.
    @Test("An active item's explanation names the limit it is within, or says last use is unknown")
    func ageAssessment_withinLimitOrUnknown_explainsWhyActive() {
        let category = StorageCategory.derivedData

        #expect(
            category.ageAssessment(lastUsed: now.addingTimeInterval(-86400), now: now).explanation
                == "Used within the 30-day limit for DerivedData."
        )
        #expect(
            category.ageAssessment(lastUsed: nil, now: now).explanation
                == "Last use is unknown, so it isn't counted as unused."
        )
    }

    /// Verifies the Archives & Caches age rule never makes an item Unused; a years-old archive stays
    /// Active. The module cache is the exception: it ages by DerivedData's rule.
    /// To replicate: keep an .xcarchive from years ago → open Archives & Caches → it shows Active.
    @Test("Archives & Caches' own age rule never makes an item stale")
    func ageAssessment_archivesAndCaches_neverStale() {
        let assessment = StorageCategory.archivesAndCaches.ageAssessment(lastUsed: .distantPast, now: now)

        #expect(assessment.status == .active)
        #expect(assessment.explanation == "Never counts as unused, whatever its age.")
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
