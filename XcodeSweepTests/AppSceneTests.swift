import SwiftUI
import Testing
import Vision
@testable import XcodeSweep

@Suite("App scenes")
@MainActor
struct AppSceneTests {
    /// A second `WindowGroup` window would share the store's selection, search, and dialog state.
    @Test("The main scene is a single Window, not a WindowGroup")
    func mainSceneIsSingleWindow() {
        let sceneType = String(reflecting: type(of: XcodeSweepApp().body))
        #expect(sceneType.contains("SwiftUI.Window<"))
        #expect(!sceneType.contains("WindowGroup"))
    }

    /// The main window's first appearance scans the real `~/Library/Developer`, which a test run must not touch.
    @Test("Running as the test host opens no main window")
    func testHostOpensNoMainWindow() {
        let mainWindows = NSApplication.shared.windows.filter { $0.identifier?.rawValue == "main" }
        #expect(mainWindows.isEmpty)
    }

    /// An empty category whose folder couldn't be read must not claim nothing is there.
    /// To replicate: make a category's folder unreadable → scan → open the category.
    @Test("An empty category that couldn't be scanned says so instead of Nothing Found")
    func emptyFailedCategorySaysItCouldntScan() throws {
        let failed = try recognizedText(in: CategoryEmptyStateView(
            category: .deviceSupport, isScanning: false, failure: "Permission denied",
            hasActiveFilter: false, onResetFilters: {}
        ).frame(width: 500, height: 300))
        let empty = try recognizedText(in: CategoryEmptyStateView(
            category: .deviceSupport, isScanning: false, failure: nil,
            hasActiveFilter: false, onResetFilters: {}
        ).frame(width: 500, height: 300))

        #expect(failed.contains { $0.contains("Scan Device Support") }, "Recognized: \(failed)")
        #expect(!failed.contains { $0.contains("Nothing Found") }, "Recognized: \(failed)")
        #expect(empty.contains { $0.contains("Nothing Found") }, "Recognized: \(empty)")
    }

    @Test("A category row in the sidebar marks a failed scan")
    func sidebarRowMarksFailedScan() throws {
        let metrics = CategoryMetrics(category: .deviceSupport, itemCount: 0, totalBytes: 0, reclaimableCount: 0, reclaimableBytes: 0)

        let failed = try recognizedText(in: SidebarCategoryRow(metrics: metrics, isScanning: false, failure: "Permission denied")
            .frame(width: 260))
        let clean = try recognizedText(in: SidebarCategoryRow(metrics: metrics, isScanning: false, failure: nil)
            .frame(width: 260))

        #expect(failed.contains { $0.contains("Scan incomplete") }, "Recognized: \(failed)")
        #expect(!clean.contains { $0.contains("Scan incomplete") }, "Recognized: \(clean)")
    }

    /// The alert lists only the first four failures; this list is where the rest are seen.
    /// To replicate: clean up six items where five or more fail → Show All Failures → scroll the list.
    @Test("The failure list shows every failure with its reason")
    func failureListShowsEveryFailure() throws {
        // Words, not numbered names: fast recognition misreads digits.
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"]
        let failures = names.map { DeletionFailure(itemID: $0, itemName: $0, reason: "Locked by \($0)") }

        let lines = try recognizedText(in: FailureRowsView(failures: failures).frame(width: 420))

        for name in names {
            #expect(lines.contains { $0 == name }, "Recognized: \(lines)")
            #expect(lines.contains { $0.contains("Locked by \(name)") }, "Recognized: \(lines)")
        }
    }

    /// Reads the rendered pixels, since SwiftUI exposes no view tree to inspect and the footer
    /// once showed a hard-coded name.
    @Test("The sidebar footer shows the scanned volume's name")
    func diskFooterShowsVolumeName() throws {
        let lines = try recognizedText(in: DiskFooterView(
            volume: DiskVolume(name: "Probe Volume", availableBytes: 1_000, totalBytes: 4_000)
        )
        .frame(width: 260))

        #expect(lines.contains { $0.contains("Probe Volume") }, "Recognized: \(lines)")
    }

    private func recognizedText(in view: some View) throws -> [String] {
        // Opaque, since recognition finds nothing on a transparent render.
        let renderer = ImageRenderer(content: view.background(.white).environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
