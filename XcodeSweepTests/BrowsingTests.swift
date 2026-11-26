import Foundation
import Testing
@testable import XcodeSweep

@Suite("Browsing")
struct BrowsingTests {
    private let oldBuild = makeStorageItem(id: "dd-old", name: "SampleApp", status: .stale)
    private let otherBuild = makeStorageItem(id: "dd-other", name: "OtherApp", status: .active)
    private let worktreeBuild = makeStorageItem(id: "dd-worktree", name: "SampleApp-wt", status: .worktree)
    private let deadDevice = makeStorageItem(id: "sim-dead", category: .simulatorDevices, status: .unavailable)
    private let lockedRuntime = makeStorageItem(
        id: "runtime-locked",
        category: .simulatorRuntimes,
        status: .stale,
        method: .notDeletable(reason: "System managed")
    )

    private var inventory: StorageInventory {
        StorageInventory(
            itemsByCategory: [
                .derivedData: [oldBuild, otherBuild, worktreeBuild],
                .simulatorDevices: [deadDevice],
                .simulatorRuntimes: [lockedRuntime],
            ],
            scannedAt: nil,
            volume: nil
        )
    }

    /// Verifies moving to another category starts it with no filter, search, or selection.
    /// To replicate: in DerivedData choose Unused, type a search, select a row → click Simulator Devices.
    @Test("Navigating to another destination resets filter, search, and selection")
    func navigate_toDifferentDestination_resetsFilterSearchAndSelection() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.derivedData))
        browsing.statusFilter = .stale
        browsing.searchText = "Sample"
        browsing.selectedItemIDs = [oldBuild.id]

        browsing.navigate(to: .category(.simulatorDevices))

        #expect(browsing.destination == .category(.simulatorDevices))
        #expect(browsing.activeCategory == .simulatorDevices)
        #expect(browsing.statusFilter == .all)
        #expect(browsing.searchText.isEmpty)
        #expect(browsing.selectedItemIDs.isEmpty)
    }

    /// Verifies re-selecting the current destination keeps the user's filter, search, and selection.
    /// To replicate: in DerivedData choose Unused and select a row → click DerivedData in the sidebar again.
    @Test("Navigating to the current destination keeps filter, search, and selection")
    func navigate_toSameDestination_keepsFilterSearchAndSelection() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.derivedData))
        browsing.statusFilter = .stale
        browsing.searchText = "Sample"
        browsing.selectedItemIDs = [oldBuild.id]

        browsing.navigate(to: .category(.derivedData))

        #expect(browsing.statusFilter == .stale)
        #expect(browsing.searchText == "Sample")
        #expect(browsing.selectedItemIDs == [oldBuild.id])
    }

    /// Verifies "Review Recommended" lands on the category with Recommended applied, no stale search, and only that
    /// category's reclaimable items selected.
    /// To replicate: in Simulator Devices type a search → go to Overview → click "Review N Recommended" on
    /// DerivedData.
    @Test("Opening a category for cleanup applies Recommended and selects only its reclaimable items")
    func openCategoryAndSelectReclaimable_fromAnotherCategory_selectsOnlyThatCategory() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.simulatorDevices))
        browsing.searchText = "iPhone"

        browsing.openCategoryAndSelectReclaimable(.derivedData, in: inventory)

        #expect(browsing.destination == .category(.derivedData))
        #expect(browsing.statusFilter == .reclaimable)
        #expect(browsing.searchText.isEmpty)
        #expect(browsing.selectedItemIDs == [oldBuild.id])
    }

    @Test("Select helpers act only on visible items in the active category")
    func selectHelpers_actOnVisibleItemsOnly() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.derivedData))
        browsing.searchText = "Sample"

        browsing.selectAllDeletableInActiveCategory(in: inventory)
        #expect(browsing.selectedItemIDs == [oldBuild.id, worktreeBuild.id])

        browsing.selectReclaimableInActiveCategory(in: inventory)
        #expect(browsing.selectedItemIDs == [oldBuild.id])

        browsing.clearSelection()
        #expect(browsing.selectedItemIDs.isEmpty)
    }

    @Test("Select helpers skip items that can't be deleted")
    func selectAllDeletable_skipsProtectedItems() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.simulatorRuntimes))

        browsing.selectAllDeletableInActiveCategory(in: inventory)

        #expect(browsing.selectedItemIDs.isEmpty)
    }

    @Test("Select helpers do nothing on the overview")
    func selectHelpers_onOverview_selectNothing() {
        var browsing = Browsing()

        browsing.selectAllDeletableInActiveCategory(in: inventory)
        browsing.selectReclaimableInActiveCategory(in: inventory)

        #expect(browsing.selectedItemIDs.isEmpty)
        #expect(browsing.selectedItems(in: inventory).isEmpty)
    }

    /// Filtering keeps the selected IDs, so a hidden row is selected again when it reappears.
    @Test("Rows hidden by search or filter are left out of the selected items until they reappear")
    func hiddenSelectedRows_areExcludedUntilShownAgain() {
        // Given: two DerivedData rows selected
        var browsing = Browsing()
        browsing.navigate(to: .category(.derivedData))
        browsing.selectedItemIDs = [oldBuild.id, otherBuild.id]

        // When: a search hides one of them
        browsing.searchText = "OtherApp"

        // Then: only the visible row counts as selected
        #expect(browsing.selectedItems(in: inventory).map(\.id) == [otherBuild.id])

        // A status filter hiding every selected row leaves nothing selected.
        browsing.searchText = ""
        browsing.statusFilter = .worktree
        #expect(browsing.selectedItems(in: inventory).isEmpty)

        // Clearing the filter brings the hidden rows back, still selected.
        browsing.statusFilter = .all
        #expect(Set(browsing.selectedItems(in: inventory).map(\.id)) == [oldBuild.id, otherBuild.id])
    }

    @Test("Visible items follow the sort order")
    func visibleItems_followSortOrder() {
        var browsing = Browsing()
        browsing.sortOrder = [KeyPathComparator(\.name)]

        let names = browsing.visibleItems(for: .derivedData, in: inventory).map(\.name)

        #expect(names == ["OtherApp", "SampleApp", "SampleApp-wt"])
    }

    /// Selection only ever holds items in the active category, which is what lets one reconcile cover both a
    /// finished scan and each deleted item.
    @Test("Reconciling keeps only selected items still in the active category")
    func reconcile_dropsItemsNoLongerInActiveCategory() {
        var browsing = Browsing()
        browsing.navigate(to: .category(.derivedData))
        browsing.selectedItemIDs = [oldBuild.id, otherBuild.id]

        browsing.reconcile(with: inventory.removingItems(withIDs: [oldBuild.id]))

        #expect(browsing.selectedItemIDs == [otherBuild.id])
    }

    @Test("Reconciling on the overview clears the selection")
    func reconcile_onOverview_clearsSelection() {
        var browsing = Browsing()
        browsing.selectedItemIDs = [oldBuild.id]

        browsing.reconcile(with: inventory)

        #expect(browsing.selectedItemIDs.isEmpty)
    }
}
