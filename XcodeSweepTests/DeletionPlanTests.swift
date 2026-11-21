import Foundation
import Testing
@testable import XcodeSweep

@Suite("DeletionPlan")
struct DeletionPlanTests {
    /// Verifies protected items never count toward what a cleanup will remove or reclaim.
    /// To replicate: not reachable as one UI selection (selection is per category); covered at the model level.
    @Test("Mixed selection partitions deletable items from protected ones")
    func init_withMixedSelection_excludesProtectedItemsFromCountsAndBytes() {
        // Given: A trash item, a booted device, a runtime, and a protected runtime
        let selection = [
            makeStorageItem(id: "dd", sizeBytes: 100, method: .trashFile(URL(filePath: "/tmp/dd"))),
            makeStorageItem(id: "sim", sizeBytes: 20, method: .simctlDevice(udid: "SIM-1", isBooted: true)),
            makeStorageItem(id: "rt", sizeBytes: 3, method: .simctlRuntime(identifier: "RT-1")),
            makeStorageItem(id: "sys", sizeBytes: 9000, method: .notDeletable(reason: "System")),
        ]

        // When
        let plan = DeletionPlan(selection: selection)

        // Then
        #expect(plan.deletableItems.map(\.id) == ["dd", "sim", "rt"])
        #expect(plan.protectedCount == 1)
        #expect(plan.totalBytes == 123)
        #expect(plan.trashCount == 1)
        #expect(plan.permanentCount == 2)
        #expect(plan.bootedDeviceCount == 1)
        #expect(!plan.isEmpty)
    }

    /// Verifies a selection of only protected items offers nothing to delete.
    /// To replicate: select only a system-managed runtime → the delete buttons stay disabled.
    @Test("Selection of only protected items is empty")
    func init_withOnlyProtectedItems_isEmpty() {
        let plan = DeletionPlan(selection: [makeStorageItem(id: "sys", method: .notDeletable(reason: "System"))])

        #expect(plan.isEmpty)
        #expect(plan.totalBytes == 0)
        #expect(plan.requestTitle == "Delete Selected…")
    }

    /// Verifies the action title names the removal method and count the user is about to confirm.
    /// To replicate: in one category, select one item, then several → press ⌘⌫ → read the confirmation button.
    @Test("Action title reflects removal method and count", arguments: [
        ([DeletionMethod.trashFile(URL(filePath: "/tmp/a"))], "Move 1 Item to Trash"),
        (
            [.trashFile(URL(filePath: "/tmp/a")), .trashFile(URL(filePath: "/tmp/b"))],
            "Move 2 Items to Trash"
        ),
        ([.simctlRuntime(identifier: "RT-1")], "Delete 1 Item"),
        ([.trashFile(URL(filePath: "/tmp/a")), .simctlRuntime(identifier: "RT-1")], "Remove 2 Items"),
        ([.trashFile(URL(filePath: "/tmp/a")), .notDeletable(reason: "System")], "Move 1 Item to Trash"),
    ])
    func actionTitle_matchesRemovalMethod(methods: [DeletionMethod], expected: String) {
        let selection = methods.enumerated().map { makeStorageItem(id: "\($0.offset)", method: $0.element) }

        let plan = DeletionPlan(selection: selection)

        #expect(plan.actionTitle == expected)
    }

    /// Verifies the confirmation warns about permanent deletion and booted-simulator shutdown.
    /// To replicate: select a booted simulator in Simulator Devices → press ⌘⌫ → read the dialog.
    @Test("Confirmation message describes every removal consequence")
    func confirmationMessage_withTrashAndBootedDevice_describesEachConsequence() {
        let plan = DeletionPlan(selection: [
            makeStorageItem(id: "dd", method: .trashFile(URL(filePath: "/tmp/dd"))),
            makeStorageItem(id: "sim", method: .simctlDevice(udid: "SIM-1", isBooted: true)),
        ])

        let message = plan.confirmationMessage

        #expect(message.contains("1 filesystem item will be moved to Trash"))
        #expect(message.contains("1 simulator item will be permanently deleted"))
        #expect(message.contains("1 booted simulator will be shut down first"))
    }

    /// Verifies a trash-only confirmation does not warn about permanent deletion.
    /// To replicate: select only DerivedData folders → press ⌘⌫ → the dialog mentions only Trash.
    @Test("Trash-only confirmation omits permanent-deletion warnings")
    func confirmationMessage_withTrashOnly_omitsSimctlWarnings() {
        let plan = DeletionPlan(selection: [makeStorageItem(id: "dd", method: .trashFile(URL(filePath: "/tmp/dd")))])

        let message = plan.confirmationMessage

        #expect(!message.contains("permanently"))
        #expect(!message.contains("shut down"))
    }

    /// Verifies the completion alert lists failures, capped so the alert stays readable.
    /// To replicate: delete a batch where several items fail → read the Cleanup Complete alert.
    @Test("Report summary lists counts and caps failure lines")
    func reportSummary_withManyFailures_capsListedFailures() {
        let failures = (1 ... 6).map { DeletionFailure(itemID: "f\($0)", itemName: "Item \($0)", reason: "Busy") }
        let report = DeletionReport(
            deletedCount: 3,
            trashedCount: 2,
            simctlDeletedCount: 1,
            reclaimedBytes: 0,
            removedItemIDs: [],
            failures: failures
        )

        let summary = report.summary

        #expect(summary.contains("Removed 3 items"))
        #expect(summary.contains("Moved 2 to Trash"))
        #expect(summary.contains("Deleted 1 via xcrun simctl"))
        #expect(summary.contains("Could not remove 6"))
        #expect(summary.contains("Item 4: Busy"))
        #expect(!summary.contains("Item 5"))
    }
}
