import Foundation
import os
import Testing
@testable import XcodeSweep

@Suite("Refreshing a stale scan")
@MainActor
struct StaleScanRefreshTests {
    private let scanTime = testISO8601Date("2026-11-21T10:00:00Z")

    @Test("An idle store whose scan is over 15 minutes old rescans")
    func rescansWhenOlderThanLimit() async throws {
        let (store, clock, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        let later = scanTime.addingTimeInterval(901)
        clock.withLock { $0 = later }

        let rescan = try #require(store.refreshIfStale())
        await rescan.value

        #expect(store.inventory.scannedAt == later)
    }

    @Test("A scan exactly 15 minutes old is kept")
    func keepsScanWithinLimit() async throws {
        let (store, clock, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        clock.withLock { $0 = scanTime.addingTimeInterval(900) }

        #expect(store.refreshIfStale() == nil)
        #expect(store.operation == .idle)
    }

    /// Starting a scan dismisses the confirmation, which would discard what the user is answering.
    @Test("A pending confirmation blocks the rescan and stays open")
    func pendingConfirmationBlocksRescan() async throws {
        let (store, clock, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        clock.withLock { $0 = scanTime.addingTimeInterval(901) }
        store.requestDelete(items: store.inventory.items(in: .derivedData))
        let pending = try #require(store.pendingDeletion)

        #expect(store.refreshIfStale() == nil)
        #expect(store.pendingDeletion == pending)
    }

    /// The launch scan covers that case; a scan the user stopped stays stopped.
    @Test("A store that never completed a scan doesn't start one")
    func noCompletedScanStartsNothing() {
        let storage = XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )
        let store = XcodeSweepStore(xcodeStorage: storage)

        #expect(store.refreshIfStale() == nil)
    }

    private func makeScannedStore() async throws
        -> (XcodeSweepStore, OSAllocatedUnfairLock<Date>, TempXcodeFixture)
    {
        let fixture = try TempXcodeFixture()
        _ = try fixture.addDerivedData(
            folderName: "SampleApp-old",
            workspacePath: "/nonexistent/SampleApp.xcodeproj",
            lastAccessed: scanTime
        )
        let clock = OSAllocatedUnfairLock(initialState: scanTime)
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(removingUnder: fixture.rootURL),
            now: { clock.withLock { $0 } }
        )
        let store = XcodeSweepStore(xcodeStorage: storage)
        await store.startRefresh()?.value
        #expect(store.inventory.scannedAt == scanTime)
        return (store, clock, fixture)
    }
}
