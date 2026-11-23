import Foundation
import Testing
@testable import XcodeSweep

@Suite("Stopping for termination")
@MainActor
struct StopForTerminationTests {
    /// Quitting mid-batch must not leave later items half-handled or start a rescan nothing will show.
    /// To replicate: start a multi-item cleanup → ⌘Q → Stop and Quit.
    @Test("A deletion stops after its in-flight item, without the rescan, and the store goes idle", .timeLimit(.minutes(1)))
    func stopsDeletionWithoutRescan() async throws {
        // Given: a cleanup of three items whose second Trash move is in flight
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let urls = try ["Done-1", "Parked-2", "Untouched-3"].map {
            try fixture.addDerivedData(folderName: $0, workspacePath: "/nonexistent/\($0).xcodeproj", lastAccessed: now)
        }
        let trasher = ControllableFileTrasher(removingUnder: fixture.rootURL)
        let runner = RecordingCommandRunner()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: trasher,
            now: { now }
        ))
        await store.startRefresh()?.value
        let commandsBeforeDeletion = await runner.calls.count
        store.startDeletion(DeletionPlan(selection: store.inventory.items(in: .derivedData)))
        let first = try await trasher.nextPendingCall()
        await trasher.resume(id: first.id)
        let second = try await trasher.nextPendingCall()

        // When: the app stops the store to quit
        let stop = Task { await store.stopForTermination() }
        _ = try await awaitResult(of: Task { try await trasher.waitForCancellation(id: second.id) }, within: .seconds(10)).get()
        _ = try await awaitResult(of: Task { await stop.value }, within: .seconds(10)).get()

        // Then: idle, only the first item moved, the third never requested, and no rescan ran
        #expect(store.operation == .idle)
        #expect(await trasher.recordedArguments.count == 2)
        #expect(await trasher.completedArguments.count == 1)
        #expect(await runner.calls.count == commandsBeforeDeletion)
        #expect(Set([first.argument, second.argument]) == Set(urls.prefix(2)))
    }

    @Test("Stopping an idle store returns at once")
    func stoppingIdleStoreReturns() async {
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        ))

        await store.stopForTermination()

        #expect(store.operation == .idle)
    }
}
