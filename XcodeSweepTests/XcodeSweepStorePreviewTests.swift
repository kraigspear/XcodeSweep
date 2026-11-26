#if DEBUG && canImport(SwiftUI)
    import Foundation
    import Testing
    @testable import XcodeSweep

    @Suite("XcodeSweepStore.preview")
    @MainActor
    struct XcodeSweepStorePreviewTests {
        private let refusal = "Previews don't run commands or move files to Trash."

        /// Verifies Refresh in a preview never loads the developer's Xcode storage or runs simctl.
        /// To replicate: open the ContentView preview in Xcode's canvas → click Refresh.
        @Test("Refresh scans no Xcode folder and runs no command")
        func refresh_scansNoXcodeFolderAndRunsNoCommand() async {
            let store = XcodeSweepStore.preview()

            await store.startRefresh()?.value

            let scanRoot = XcodeStorage.preview.xcodeRootURL
            #expect(
                scanRoot.deletingLastPathComponent().standardizedFileURL
                    == FileManager.default.temporaryDirectory.standardizedFileURL
            )
            #expect(!FileManager.default.fileExists(atPath: scanRoot.path(percentEncoded: false)))
            #expect(store.inventory.totalItemCount == 0)
            let failures = store.inventory.categoryMetrics.compactMap(\.failure)
            #expect(!failures.isEmpty)
            #expect(failures.allSatisfy { $0.contains(refusal) })
        }

        /// Verifies a confirmed cleanup in a preview leaves real files and simulators alone.
        /// To replicate: in the DerivedData ContentView preview, click the inspector's delete button → confirm.
        @Test("Confirmed cleanup refuses every Trash move and simctl command")
        func startDeletion_refusesTrashAndSimctl() async throws {
            // Given: A real file and a simulator the user selected in a preview
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("XcodeSweepPreviewTests-\(UUID().uuidString)")
            try Data("keep".utf8).write(to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let plan = DeletionPlan(selection: [
                makeStorageItem(id: "file", method: .trashFile(fileURL)),
                makeStorageItem(id: "sim", method: .simctlDevice(udid: "PREVIEW-UDID")),
            ])
            let store = XcodeSweepStore.preview()

            // When
            await store.startDeletion(plan)?.value

            // Then: Both items were refused by the preview adapter and the file is still in place
            let report = try #require(store.lastDeletionReport)
            #expect(report.deletedCount == 0)
            #expect(report.failures.map(\.itemID) == ["file", "sim"])
            #expect(report.failures.allSatisfy { $0.reason.contains(refusal) })
            #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        }
    }
#endif
