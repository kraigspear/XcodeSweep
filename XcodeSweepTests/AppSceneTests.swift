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

    @Test("The Overview banner and card name a failed category")
    func overviewShowsFailedCategory() throws {
        let metrics = CategoryMetrics(category: .deviceSupport, itemCount: 0, totalBytes: 0, reclaimableCount: 0, reclaimableBytes: 0)

        let banner = try recognizedText(in: ScanFailuresBanner(failures: [.deviceSupport: "Permission denied"])
            .frame(width: 600))
        let card = try recognizedText(in: CategoryCardView(
            metrics: metrics, isScanning: false, failure: "Permission denied", onOpen: {}, onSelectReclaimable: {}
        ).frame(width: 360))

        #expect(banner.contains { $0.contains("Device Support: Permission denied") }, "Recognized: \(banner)")
        #expect(card.contains { $0.contains("Scan incomplete") }, "Recognized: \(card)")
    }

    /// Verifies the Overview card and sidebar row name reclaimable items "Recommended", the word every other screen uses.
    /// To replicate: scan a Mac with an unused DerivedData folder → read the DerivedData card's button and sidebar row.
    @Test("The Overview card and sidebar row call reclaimable items Recommended")
    func reclaimableCountIsLabelledRecommended() throws {
        let metrics = CategoryMetrics(
            category: .simulatorDevices, itemCount: 59, totalBytes: 276_910_000_000,
            reclaimableCount: 30, reclaimableBytes: 2_000
        )

        // The narrowest card the Overview grid allows, and a row narrower than the narrowest sidebar
        // gives (about 185), so a label that doesn't fit is truncated or wrapped and fails here.
        let card = try recognizedText(in: CategoryCardView(
            metrics: metrics, isScanning: false, failure: nil, onOpen: {}, onSelectReclaimable: {}
        ).frame(width: 290))
        let row = try recognizedText(in: SidebarCategoryRow(metrics: metrics, isScanning: false, failure: nil)
            .frame(width: 180))

        #expect(card.contains { $0.contains("Recommended") }, "Recognized: \(card)")
        // The count and the word on one line; a wrapped caption reads as two.
        #expect(row.contains { $0.hasSuffix(" recommended") }, "Recognized: \(row)")
        #expect(!(card + row).contains { $0.localizedCaseInsensitiveContains("cleanable") }, "Recognized: \(card + row)")
    }

    /// Verifies a card's review button shows its whole label at the grid's narrowest card, even with a
    /// three-digit count; "Review 130 Recommended" once truncated there.
    /// To replicate: scan a Mac with 100+ unused DerivedData folders → narrow the window until the cards are
    /// one column at their minimum width → read the DerivedData card's buttons.
    @Test("A card's review button isn't truncated at the narrowest card width", arguments: [
        (159, 130),
        (1059, 999),
    ])
    func reviewButtonFitsNarrowestCard(itemCount: Int, reclaimableCount: Int) throws {
        let metrics = CategoryMetrics(
            category: .derivedData, itemCount: itemCount, totalBytes: 276_910_000_000,
            reclaimableCount: reclaimableCount, reclaimableBytes: 2_000
        )

        let card = try recognizedText(in: CategoryCardView(
            metrics: metrics, isScanning: false, failure: nil, onOpen: {}, onSelectReclaimable: {}
        ).frame(width: 290))

        #expect(card.contains("Review \(reclaimableCount) Recommended"), "Recognized: \(card)")
        #expect(card.contains("Open"), "Recognized: \(card)")
    }

    /// Verifies a footer that fits on one row stays there: the narrowest card fits "Review 30 Recommended"
    /// beside its item count with almost nothing to spare, so it is the first to drop a row by mistake.
    /// To replicate: scan a Mac with a few unused DerivedData folders → narrow the window to one column of cards.
    @Test("A card's footer keeps one row while its controls fit")
    func footerStaysOneRowWhenItFits() throws {
        func height(reclaimableCount: Int) throws -> Int {
            let metrics = CategoryMetrics(
                category: .derivedData, itemCount: 59, totalBytes: 276_910_000_000,
                reclaimableCount: reclaimableCount, reclaimableBytes: 2_000
            )
            // The locale is pinned because the labels' widths, and so whether the row fits, depend on it.
            let renderer = ImageRenderer(content: CategoryCardView(
                metrics: metrics, isScanning: false, failure: nil, onOpen: {}, onSelectReclaimable: {}
            )
            .frame(width: 290)
            .environment(\.locale, Locale(identifier: "en_US")))
            return try #require(renderer.cgImage).height
        }

        #expect(try height(reclaimableCount: 30) == height(reclaimableCount: 0))
    }

    /// Verifies the "N recommended" caption takes no room from the row's title: it once sat beside the title,
    /// so the longer word truncated titles that fit before.
    /// To replicate: scan a Mac with an unused simulator runtime → read its sidebar row at the default width.
    @Test("A sidebar row's recommended caption leaves its title the same room")
    func recommendedCaptionLeavesTitleItsRoom() throws {
        let width: CGFloat = 240
        let plain = CategoryMetrics(
            category: .simulatorRuntimes, itemCount: 59, totalBytes: 276_910_000_000,
            reclaimableCount: 0, reclaimableBytes: 0
        )
        let recommending = CategoryMetrics(
            category: .simulatorRuntimes, itemCount: 59, totalBytes: 276_910_000_000,
            reclaimableCount: 30, reclaimableBytes: 2_000
        )

        let plainRow = try recognizedText(in: SidebarCategoryRow(metrics: plain, isScanning: false, failure: nil)
            .frame(width: width))
        let recommendingRow = try recognizedText(in: SidebarCategoryRow(metrics: recommending, isScanning: false, failure: nil)
            .frame(width: width))

        #expect(plainRow.contains("Simulator Runtimes"), "Recognized: \(plainRow)")
        #expect(recommendingRow.contains("Simulator Runtimes"), "Recognized: \(recommendingRow)")
    }

    #if DEBUG && canImport(SwiftUI)
        /// A filter that hides every row must not hide why some rows may be missing.
        @Test("A filtered category view still explains a failed scan")
        func filteredCategoryShowsFailureBanner() throws {
            let store = XcodeSweepStore.preview(
                destination: .category(.deviceSupport),
                scanFailures: [.deviceSupport: "Permission denied"]
            )
            store.searchText = "no such item"

            let lines = try recognizedText(in: CategoryDetailView(category: .deviceSupport, store: store)
                .frame(width: 700, height: 400))

            #expect(lines.contains { $0.contains("fully scan Device Support") }, "Recognized: \(lines)")
        }
    #endif

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
        // Opaque, since recognition finds nothing on a transparent render. The locale is pinned because
        // sizes are formatted for it, and a longer size changes what fits beside it.
        let renderer = ImageRenderer(
            content: view.background(.white)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
