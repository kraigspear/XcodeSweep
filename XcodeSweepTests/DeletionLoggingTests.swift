import Foundation
import OSLog
import Testing
@testable import XcodeSweep

@Suite("Deletion logging")
struct DeletionLoggingTests {
    @Test("Every removal and failure is logged with its path")
    func logsRemovalsAndFailures() async throws {
        let goodURL = uniqueURL("Good")
        let badURL = uniqueURL("Locked")
        let storage = XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(failingURLs: [badURL])
        )
        let plan = DeletionPlan(selection: [
            makeStorageItem(id: "good", name: "Good", sizeBytes: 2048, method: .trashFile(goodURL)),
            makeStorageItem(id: "bad", name: "Locked", method: .trashFile(badURL)),
        ])

        for try await _ in storage.delete(plan) {}

        let good = try deletionLogEntries(endingWith: goodURL.path)
        let bad = try deletionLogEntries(endingWith: badURL.path, orReason: "Permission denied for Locked")
        #expect(good.map(\.level) == [.notice])
        #expect(good.map(\.composedMessage) == ["outcome=removed method=trash bytes=2048 target=\(goodURL.path)"])
        #expect(bad.map(\.level) == [.error])
        #expect(bad.map(\.composedMessage) == [
            "outcome=failed method=trash target=\(badURL.path) reason=Permission denied for Locked",
        ])
    }

    /// The store's report leaves out an item stopped mid-removal, so the log is its only record.
    @Test("An item in flight at a stop is logged as possibly removed", .timeLimit(.minutes(1)))
    func logsItemInFlightAtStop() async throws {
        let url = uniqueURL("InFlight")
        let trasher = ControllableFileTrasher()
        let storage = XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher
        )
        let plan = DeletionPlan(selection: [makeStorageItem(id: "in-flight", method: .trashFile(url))])

        let deletion = Task {
            for try await _ in storage.delete(plan) {}
        }
        _ = try await trasher.nextPendingCall()
        _ = try await cancelAndAwaitResult(of: deletion, within: .seconds(10))

        let entries = try deletionLogEntries(endingWith: url.path)
        #expect(entries.map(\.level) == [.notice])
        #expect(entries.map(\.composedMessage) == ["outcome=unknown method=trash target=\(url.path)"])
    }

    @Test("A simulator delete stopped mid-command is logged as possibly removed", .timeLimit(.minutes(1)))
    func logsInterruptedSimulatorDelete() async throws {
        let udid = "UDID-\(UUID().uuidString)"
        let runner = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: URL(filePath: "/nonexistent"),
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )
        let plan = DeletionPlan(selection: [makeStorageItem(
            id: "sim",
            category: .simulatorDevices,
            method: .simctlDevice(udid: udid)
        )])

        let deletion = Task {
            for try await _ in storage.delete(plan) {}
        }
        let shutdown = try await runner.nextPendingCall()
        await runner.resume(id: shutdown.id, with: .success(
            CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
        ))
        let delete = try await runner.nextPendingCall()
        #expect(delete.argument == ["simctl", "delete", udid])
        _ = try await cancelAndAwaitResult(of: deletion, within: .seconds(10))

        let entries = try deletionLogEntries(endingWith: udid)
        #expect(entries.map(\.composedMessage) == ["outcome=unknown method=simctlDevice target=\(udid)"])
    }

    private func uniqueURL(_ name: String) -> URL {
        URL(filePath: "/nonexistent/\(UUID().uuidString)/\(name)")
    }
}

/// This process's deletion log entries whose message ends with `target=<target>`, or with
/// `target=<target> reason=<reason>` when a reason is given.
///
/// Reads every entry since the process started rather than from a time, which a clock change
/// could move past the entries; each test's unique target tells them apart.
func deletionLogEntries(endingWith target: String, orReason reason: String? = nil) throws -> [OSLogEntryLog] {
    let suffix = reason.map { "target=\(target) reason=\($0)" } ?? "target=\(target)"
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    return try store.getEntries()
        .compactMap { $0 as? OSLogEntryLog }
        .filter {
            $0.subsystem == "com.kraigspear.XcodeSweep" && $0.category == "🗑️deletion"
                && $0.composedMessage.hasSuffix(suffix)
        }
}
