import Foundation
import os
import Testing
@testable import XcodeSweep

// MARK: - Temporary Xcode Filesystem Fixture

struct TempXcodeFixture {
    let rootURL: URL
    let xcodeRootURL: URL
    let workspacesRootURL: URL

    init() throws {
        let rawRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        let canonicalPath = try rawRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? rawRoot.path
        let root = URL(fileURLWithPath: canonicalPath, isDirectory: true)
        let xcodeRoot = root.appendingPathComponent("Xcode", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        // As on a Mac that has run SwiftUI previews, so scans list the preview set.
        try FileManager.default.createDirectory(
            at: xcodeRoot.appendingPathComponent("UserData/Previews/Simulator Devices", isDirectory: true),
            withIntermediateDirectories: true
        )

        rootURL = root
        xcodeRootURL = xcodeRoot
        workspacesRootURL = workspacesRoot
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    func createWorkspace(
        folderName: String,
        projectName: String,
        isGitWorktree: Bool = false
    ) throws -> URL {
        let repoRoot = workspacesRootURL.appendingPathComponent(folderName, isDirectory: true)
        let projectURL = repoRoot.appendingPathComponent(projectName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        if isGitWorktree {
            try "gitdir: /somewhere/.git/worktrees/\(folderName)".write(
                to: repoRoot.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )
        }
        return projectURL
    }

    @discardableResult
    func addDerivedData(
        folderName: String,
        workspacePath: String?,
        lastAccessed: Date,
        payloadBytes: Int = 8192
    ) throws -> URL {
        let folderURL = xcodeRootURL
            .appendingPathComponent("DerivedData/\(folderName)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        if let workspacePath {
            let plist: [String: Any] = [
                "WorkspacePath": workspacePath,
                "LastAccessedDate": lastAccessed,
            ]
            try writePlist(plist, to: folderURL.appendingPathComponent("info.plist"))
        }

        if payloadBytes > 0 {
            try Data(repeating: 0xAA, count: payloadBytes)
                .write(to: folderURL.appendingPathComponent("build.bin"))
        }
        return folderURL
    }

    @discardableResult
    func addModuleCache(modifiedDate: Date, payloadBytes: Int = 4096) throws -> URL {
        let cacheURL = xcodeRootURL
            .appendingPathComponent("DerivedData/ModuleCache.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        if payloadBytes > 0 {
            let moduleURL = cacheURL.appendingPathComponent("module.pcm")
            try Data(repeating: 0xBB, count: payloadBytes).write(to: moduleURL)
            try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: moduleURL.path)
        }
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: cacheURL.path)
        return cacheURL
    }

    @discardableResult
    func addDeviceSupport(
        platformFolder: String,
        versionFolder: String,
        modifiedDate: Date,
        payloadBytes: Int = 8192
    ) throws -> URL {
        let folderURL = xcodeRootURL
            .appendingPathComponent("\(platformFolder)/\(versionFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        if payloadBytes > 0 {
            try Data(repeating: 0xCC, count: payloadBytes)
                .write(to: folderURL.appendingPathComponent("Symbols.dyld"))
        }
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: folderURL.path)
        return folderURL
    }

    @discardableResult
    func addPreviewDevice(
        udid: String,
        name: String,
        runtime: String,
        modifiedDate: Date,
        payloadBytes: Int = 4096
    ) throws -> URL {
        let folderURL = xcodeRootURL
            .appendingPathComponent("UserData/Previews/Simulator Devices/\(udid)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try writePlist(
            ["name": name, "runtime": runtime],
            to: folderURL.appendingPathComponent("device.plist")
        )
        if payloadBytes > 0 {
            try Data(repeating: 0xDD, count: payloadBytes)
                .write(to: folderURL.appendingPathComponent("data.bin"))
        }
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: folderURL.path)
        return folderURL
    }

    @discardableResult
    func addArchive(
        dateFolder: String,
        archiveName: String,
        appName: String,
        shortVersion: String,
        buildVersion: String,
        bundleID: String,
        creationDate: Date,
        payloadBytes: Int = 8192
    ) throws -> URL {
        let archiveURL = xcodeRootURL
            .appendingPathComponent("Archives/\(dateFolder)/\(archiveName).xcarchive", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Name": appName,
            "CreationDate": creationDate,
            "ApplicationProperties": [
                "CFBundleShortVersionString": shortVersion,
                "CFBundleVersion": buildVersion,
                "CFBundleIdentifier": bundleID,
            ],
        ]
        try writePlist(plist, to: archiveURL.appendingPathComponent("Info.plist"))
        if payloadBytes > 0 {
            try Data(repeating: 0xEE, count: payloadBytes)
                .write(to: archiveURL.appendingPathComponent("Products.bin"))
        }
        return archiveURL
    }

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }
}

// MARK: - CommandRunning Test Adapters

struct StubCommandRunner: CommandRunning, Sendable {
    var devicesJSON = #"{"devices":{}}"#
    var runtimesJSON = #"{}"#
    var previewDevicesJSON = #"{"devices":{}}"#
    var devicesError: (any Error)?
    var runtimesError: (any Error)?
    var previewDevicesError: (any Error)?
    var shutdownError: (any Error)?

    func run(executableURL _: URL, arguments: [String], timeout _: Duration?) async throws -> CommandOutput {
        if arguments.contains("shutdown"), let shutdownError {
            throw shutdownError
        }
        switch arguments {
        case ["simctl", "list", "devices", "-j"]:
            if let devicesError {
                throw devicesError
            }
            return CommandOutput(stdout: Data(devicesJSON.utf8), stderr: Data(), terminationStatus: 0)
        case ["simctl", "--set", "previews", "list", "devices", "-j"]:
            if let previewDevicesError {
                throw previewDevicesError
            }
            return CommandOutput(stdout: Data(previewDevicesJSON.utf8), stderr: Data(), terminationStatus: 0)
        case ["simctl", "runtime", "list", "-j"]:
            if let runtimesError {
                throw runtimesError
            }
            return CommandOutput(stdout: Data(runtimesJSON.utf8), stderr: Data(), terminationStatus: 0)
        default:
            return CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
        }
    }
}

typealias ControllableCommandRunner = ParkedCalls<[String], CommandOutput>

/// The `simctl` list commands a scan of `TempXcodeFixture` runs: devices, runtimes, and preview
/// devices. Without a preview set folder, a scan skips the third.
let scanSimctlListCallCount = 3

actor RecordingCommandRunner: CommandRunning {
    struct Call: Equatable, Sendable {
        let arguments: [String]
        let timeout: Duration?
    }

    private(set) var calls: [Call] = []
    private let stub: StubCommandRunner

    init(stub: StubCommandRunner = StubCommandRunner()) {
        self.stub = stub
    }

    func run(executableURL: URL, arguments: [String], timeout: Duration?) async throws -> CommandOutput {
        calls.append(Call(arguments: arguments, timeout: timeout))
        return try await stub.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }
}

// MARK: - FileTrashing Test Adapters

struct TestTrashError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Records each move; with `removingUnder`, also removes items inside that folder as the Trash would.
actor RecordingFileTrasher: FileTrashing {
    private(set) var trashedURLs: [URL] = []
    private let failingPaths: Set<String>
    private let removalRoot: URL?

    init(failingURLs: [URL] = [], removingUnder removalRoot: URL? = nil) {
        failingPaths = Set(failingURLs.map(\.path))
        self.removalRoot = removalRoot
    }

    func trashItem(at url: URL) async throws {
        if failingPaths.contains(url.path) {
            throw TestTrashError(message: "Permission denied for \(url.lastPathComponent)")
        }
        try removeItem(url, ifInside: removalRoot)
        trashedURLs.append(url)
    }
}

typealias ControllableFileTrasher = ParkedCalls<URL, Void>

/// Removes `url` as the Trash would, so a rescan sees what a real deletion leaves, but only when
/// it is inside `root`, the test's own fixture. Without a root, or outside it, nothing is touched.
func removeItem(_ url: URL, ifInside root: URL?) throws {
    guard let root else { return }
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/"), FileManager.default.fileExists(atPath: path) else { return }
    try FileManager.default.removeItem(atPath: path)
}

// MARK: - Parked Calls

/// A call to a fake OS edge, held until the test resumes or cancels it.
struct ParkedCall<Argument: Sendable>: Sendable {
    let id: UUID
    let argument: Argument
}

extension ParkedCall where Argument == [String] {
    var arguments: [String] {
        argument
    }
}

extension ParkedCall where Argument == URL {
    var url: URL {
        argument
    }
}

/// Fake for an async OS edge. Each call is recorded, then either throws `CancellationError` at once
/// (caller already cancelled; no handle is produced) or parks until the test resumes it or the caller
/// is cancelled. Whichever of resume and cancellation reaches the actor first decides the outcome.
/// Conforms to `CommandRunning` and `FileTrashing` so one cancellation contract backs both fakes.
actor ParkedCalls<Argument: Sendable, Output: Sendable> {
    /// Arguments of every call, recorded on entry, before cancellation is checked.
    private(set) var recordedArguments: [Argument] = []
    /// Arguments of calls the test resumed successfully.
    private(set) var completedArguments: [Argument] = []
    private var queuedCalls: [ParkedCall<Argument>] = []
    private var inFlightCalls: [UUID: (argument: Argument, continuation: CheckedContinuation<Output, any Error>)] = [:]
    private var waiters: [(id: UUID, continuation: CheckedContinuation<ParkedCall<Argument>, any Error>)] = []
    private var cancelledCallIDs: Set<UUID> = []
    private var cancellationWaiters: [UUID: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] = [:]
    /// As a file trasher, removes trashed items inside this folder; see `removeItem(_:ifInside:)`.
    let removalRoot: URL?

    init(removingUnder removalRoot: URL? = nil) {
        self.removalRoot = removalRoot
    }

    var hasParkedCall: Bool {
        !inFlightCalls.isEmpty
    }

    var hasRegisteredWaiter: Bool {
        !waiters.isEmpty
    }

    func park(_ argument: Argument) async throws -> Output {
        recordedArguments.append(argument)
        let callID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightCalls[callID] = (argument, continuation)
                let call = ParkedCall(id: callID, argument: argument)
                if !waiters.isEmpty {
                    waiters.removeFirst().continuation.resume(returning: call)
                } else {
                    queuedCalls.append(call)
                }
            }
        } onCancel: {
            Task { await self.cancelCall(id: callID) }
        }
    }

    func nextPendingCall() async throws -> ParkedCall<Argument> {
        if !queuedCalls.isEmpty {
            return queuedCalls.removeFirst()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !queuedCalls.isEmpty {
                    continuation.resume(returning: queuedCalls.removeFirst())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func resume(id: UUID, with result: Result<Output, any Error>) {
        guard let entry = inFlightCalls.removeValue(forKey: id) else { return }
        if case .success = result {
            completedArguments.append(entry.argument)
        }
        entry.continuation.resume(with: result)
    }

    /// Returns once the parked call `id` has been cancelled; throws if the waiting task is cancelled first.
    func waitForCancellation(id: UUID) async throws {
        if cancelledCallIDs.contains(id) {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if cancelledCallIDs.contains(id) {
                    continuation.resume()
                } else {
                    cancellationWaiters[id, default: []].append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelCancellationWaiter(callID: id, waiterID: waiterID) }
        }
    }

    private func cancelCall(id: UUID) {
        // A call already resumed by the test completed; it must not also read as cancelled.
        guard let entry = inFlightCalls.removeValue(forKey: id) else { return }
        queuedCalls.removeAll { $0.id == id }
        cancelledCallIDs.insert(id)
        for waiter in cancellationWaiters.removeValue(forKey: id) ?? [] {
            waiter.continuation.resume()
        }
        entry.continuation.resume(throwing: CancellationError())
    }

    private func cancelCancellationWaiter(callID: UUID, waiterID: UUID) {
        guard var waiters = cancellationWaiters[callID],
              let index = waiters.firstIndex(where: { $0.id == waiterID })
        else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            cancellationWaiters.removeValue(forKey: callID)
        } else {
            cancellationWaiters[callID] = waiters
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

extension ParkedCalls: CommandRunning where Argument == [String], Output == CommandOutput {
    func run(executableURL _: URL, arguments: [String], timeout _: Duration?) async throws -> CommandOutput {
        try await park(arguments)
    }
}

extension ParkedCalls: FileTrashing where Argument == URL, Output == Void {
    var trashedURLs: [URL] {
        completedArguments
    }

    func trashItem(at url: URL) async throws {
        try await park(url)
        try removeItem(url, ifInside: removalRoot)
    }

    func resume(id: UUID) {
        resume(id: id, with: .success(()))
    }
}

// MARK: - Async Utilities

actor EventRecorder<Event: Sendable> {
    private var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}

struct ConditionTimeoutError: Error, CustomStringConvertible {
    let description: String
}

func waitUntil(
    _ label: String,
    timeout: Duration = .seconds(5),
    condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        try Task.checkCancellation()
        if ContinuousClock.now >= deadline {
            throw ConditionTimeoutError(description: "Timed out waiting for: \(label)")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Cancels `task` and returns its result, failing when the task does not finish within `timeout`
/// of the call. The deadline is fixed before cancellation starts and checked against the task's
/// recorded finish time, so neither a blocking cancellation handler nor a late poll can hide a
/// slow finish.
func cancelAndAwaitResult<Success: Sendable>(
    of task: Task<Success, any Error>,
    within timeout: Duration
) async throws -> Result<Success, any Error> {
    try await boundedResult(of: task, within: timeout, cancelling: true, waitingFor: "cancelled task finished")
}

/// The task's result, or `ConditionTimeoutError` if it doesn't finish within `timeout`, so a task
/// that never resumes fails the test instead of hanging it.
func awaitResult<Success: Sendable>(
    of task: Task<Success, any Error>,
    within timeout: Duration
) async throws -> Result<Success, any Error> {
    try await boundedResult(of: task, within: timeout, cancelling: false, waitingFor: "task finished")
}

/// The deadline is set before cancelling, and cancelling happens on the observer, so a slow or
/// stuck cancellation handler counts against the bound.
private func boundedResult<Success: Sendable>(
    of task: Task<Success, any Error>,
    within timeout: Duration,
    cancelling: Bool,
    waitingFor description: String
) async throws -> Result<Success, any Error> {
    let deadline = ContinuousClock.now + timeout
    let outcome = OSAllocatedUnfairLock<(result: Result<Success, any Error>, finishedAt: ContinuousClock.Instant)?>(
        initialState: nil
    )
    Task.detached {
        if cancelling {
            task.cancel()
        }
        let result = await task.result
        let finishedAt = ContinuousClock.now
        outcome.withLock { $0 = (result, finishedAt) }
    }
    try await waitUntil(description, timeout: deadline - ContinuousClock.now) {
        outcome.withLock { $0 != nil }
    }
    let finished = try #require(outcome.withLock { $0 })
    guard finished.finishedAt <= deadline else {
        throw ConditionTimeoutError(description: "Task finished after its deadline")
    }
    return finished.result
}

func testISO8601Date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else {
        preconditionFailure("Invalid ISO8601 date literal: \(string)")
    }
    return date
}

func makeStorageItem(
    id: String,
    category: StorageCategory = .derivedData,
    name: String? = nil,
    subtitle: String = "",
    workspacePath: String? = nil,
    sizeBytes: Int64 = 1,
    status: ItemStatus = .stale,
    method: DeletionMethod = .trashFile(URL(filePath: "/tmp/item"))
) -> StorageItem {
    StorageItem(
        id: id,
        category: category,
        name: name ?? id,
        subtitle: subtitle,
        sizeBytes: sizeBytes,
        lastUsedDate: nil,
        path: nil,
        workspacePath: workspacePath,
        status: status,
        statusExplanation: "",
        deletionMethod: method,
        metadata: []
    )
}

func finalScanSnapshot(from storage: XcodeStorage) async throws -> ScanSnapshot {
    var snapshot: ScanSnapshot?
    for try await event in storage.scan() {
        if case let .completed(final) = event {
            snapshot = final
        }
    }
    return try #require(snapshot)
}

/// A one-shot latch: `wait()` returns once `signal()` has been called.
actor AsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        if signalled {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if signalled {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

/// A runner whose commands stay in flight after cancellation until `finishExiting()`, as
/// ProcessRunner does while a cancelled child exits; then each throws CancellationError.
/// `simctl shutdown` returns at once, so a device deletion parks at its delete.
actor SlowExitCommandRunner: CommandRunning {
    private(set) var parkedArguments: [[String]] = []

    /// Commands parked so far.
    var startedCount: Int {
        parkedArguments.count
    }
    private let exited = AsyncSignal()

    func run(executableURL _: URL, arguments: [String], timeout _: Duration?) async throws -> CommandOutput {
        if arguments.contains("shutdown") {
            return CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0)
        }
        parkedArguments.append(arguments)
        await exited.wait()
        try Task.checkCancellation()
        return CommandOutput(stdout: Data(#"{"devices":{}}"#.utf8), stderr: Data(), terminationStatus: 0)
    }

    func finishExiting() async {
        await exited.signal()
    }
}
