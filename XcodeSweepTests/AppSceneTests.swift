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
