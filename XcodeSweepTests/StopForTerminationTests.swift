import AppKit
import Foundation
import os
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
        let (store, urls, trasher, runner, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        let commandsBeforeDeletion = await runner.calls.count
        store.startDeletion(plan(of: store, inOrder: urls))
        let first = try await trasher.nextPendingCall()
        await trasher.resume(id: first.id)
        let second = try await trasher.nextPendingCall()

        // When: the app stops the store to quit
        let teardown = try #require(store.stopForTermination())
        _ = try await awaitResult(of: Task { await teardown.value }, within: .seconds(10)).get()

        // Then: idle, only the first item moved, the third never requested, and no rescan ran
        #expect(store.operation == .idle)
        #expect([first.argument, second.argument] == Array(urls.prefix(2)))
        #expect(await trasher.recordedArguments.count == 2)
        #expect(await trasher.completedArguments == [urls[0]])
        #expect(await runner.calls.count == commandsBeforeDeletion)
    }

    @Test("Keep Running cancels the quit and the cleanup carries on", .timeLimit(.minutes(1)))
    func keepRunningCancelsQuit() async throws {
        let (store, urls, trasher, _, fixture) = try await makeScannedStore()
        defer { fixture.cleanup() }
        store.startDeletion(plan(of: store, inOrder: urls))
        let first = try await trasher.nextPendingCall()
        let delegate = AppDelegate()
        delegate.xcodeSweepStore = store
        delegate.confirmStopAndQuit = { false }
        var replies: [Bool] = []
        delegate.replyToTermination = { replies.append($0) }

        let answer = delegate.applicationShouldTerminate(NSApplication.shared)
        await trasher.resume(id: first.id)
        let second = try await trasher.nextPendingCall()

        #expect(answer == .terminateCancel)
        #expect(second.argument == urls[1])
        #expect(replies.isEmpty)
        await trasher.resume(id: second.id)
    }

    /// AppKit must hear "quit" exactly once, and only after the cleanup has torn down.
    @Test("Stop and Quit stops the cleanup at once and replies only after teardown", .timeLimit(.minutes(1)))
    func stopAndQuitRepliesAfterTeardown() async throws {
        // Given: a cleanup whose first Trash move ignores cancellation until released
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let urls = try ["Done-1", "Next-2"].map {
            try fixture.addDerivedData(folderName: $0, workspacePath: "/nonexistent/\($0).xcodeproj", lastAccessed: now)
        }
        let trasher = HeldFileTrasher()
        let store = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher,
            now: { now }
        ))
        await store.startRefresh()?.value
        store.startDeletion(plan(of: store, inOrder: urls))
        await trasher.waitUntilStarted()
        let delegate = AppDelegate()
        delegate.xcodeSweepStore = store
        delegate.confirmStopAndQuit = { true }
        let replies = OSAllocatedUnfairLock<[(answer: Bool, wasIdle: Bool)]>(initialState: [])
        delegate.replyToTermination = { answer in
            let wasIdle = store.operation == .idle
            replies.withLock { $0.append((answer, wasIdle)) }
        }

        // When: the user chooses Stop and Quit while the move is still running
        let answer = delegate.applicationShouldTerminate(NSApplication.shared)
        try await Task.sleep(for: .milliseconds(100))
        let repliesWhileHeld = replies.withLock { $0.count }
        await trasher.release()
        try await waitUntil("termination reply") { !replies.withLock { $0.isEmpty } }

        // Then: quitting waited for the move, and no later item started
        #expect(answer == .terminateLater)
        #expect(repliesWhileHeld == 0)
        #expect(replies.withLock { $0.map(\.answer) } == [true])
        #expect(replies.withLock { $0.first?.wasIdle } == true)
        #expect(await trasher.requestedURLs == [urls[0]])
    }

    @Test("Quitting with no cleanup running needs no question")
    func quittingWhileIdleIsImmediate() {
        let delegate = AppDelegate()
        delegate.xcodeSweepStore = XcodeSweepStore(xcodeStorage: XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        ))
        delegate.confirmStopAndQuit = {
            Issue.record("Asked while idle")
            return false
        }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    private func makeScannedStore() async throws
        -> (XcodeSweepStore, [URL], ControllableFileTrasher, RecordingCommandRunner, TempXcodeFixture)
    {
        let fixture = try TempXcodeFixture()
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
        return (store, urls, trasher, runner, fixture)
    }

    /// A plan of the scanned DerivedData items in the order of `urls`, since equal sizes leave scan order open.
    private func plan(of store: XcodeSweepStore, inOrder urls: [URL]) -> DeletionPlan {
        let items = store.inventory.items(in: .derivedData)
        return DeletionPlan(selection: urls.compactMap { url in items.first { $0.path == url } })
    }
}

/// A Trash move that ignores cancellation until released, as a real move does once started.
private actor HeldFileTrasher: FileTrashing {
    private(set) var requestedURLs: [URL] = []
    private let started = AsyncSignal()
    private let released = AsyncSignal()

    func trashItem(at url: URL) async throws {
        requestedURLs.append(url)
        await started.signal()
        await released.wait()
    }

    func waitUntilStarted() async {
        await started.wait()
    }

    func release() async {
        await released.signal()
    }
}
