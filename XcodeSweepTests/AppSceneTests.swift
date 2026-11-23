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

    /// Reads the rendered pixels, since SwiftUI exposes no view tree to inspect and the footer
    /// once showed a hard-coded name.
    @Test("The sidebar footer shows the scanned volume's name")
    func diskFooterShowsVolumeName() throws {
        let renderer = ImageRenderer(content: DiskFooterView(
            volume: DiskVolume(name: "Probe Volume", availableBytes: 1_000, totalBytes: 4_000)
        )
        .frame(width: 260)
        .environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }

        #expect(lines.contains { $0.contains("Probe Volume") }, "Recognized: \(lines)")
    }
}
