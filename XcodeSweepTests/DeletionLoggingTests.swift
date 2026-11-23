import Foundation
import OSLog
import Testing
@testable import XcodeSweep

@Suite("Deletion logging")
struct DeletionLoggingTests {
    @Test("Every removal and failure is logged with its path")
    func logsRemovalsAndFailures() async throws {
        let start = Date()
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

        let good = try deletionLog(since: start, mentioning: goodURL)
        let bad = try deletionLog(since: start, mentioning: badURL)
        #expect(good.map(\.level) == [.notice])
        #expect(good.first?.composedMessage.contains("outcome=removed method=trash bytes=2048") == true)
        #expect(bad.map(\.level) == [.error])
        #expect(bad.first?.composedMessage.contains("outcome=failed") == true)
    }

    /// The store's report leaves out an item stopped mid-removal, so the log is its only record.
    @Test("An item in flight at a stop is logged as possibly removed", .timeLimit(.minutes(1)))
    func logsItemInFlightAtStop() async throws {
        let start = Date()
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

        let entries = try deletionLog(since: start, mentioning: url)
        #expect(entries.map(\.level) == [.notice])
        #expect(entries.first?.composedMessage.contains("outcome=unknown") == true)
    }

    private func uniqueURL(_ name: String) -> URL {
        URL(filePath: "/nonexistent/\(UUID().uuidString)/\(name)")
    }

    private func deletionLog(since start: Date, mentioning url: URL) throws -> [OSLogEntryLog] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.category == LogContext.deletion.rawValue && $0.composedMessage.contains(url.path) }
    }
}
