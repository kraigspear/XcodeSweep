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
    func addModuleCache(payloadBytes: Int = 4096) throws -> URL {
        let cacheURL = xcodeRootURL
            .appendingPathComponent("DerivedData/ModuleCache.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        if payloadBytes > 0 {
            try Data(repeating: 0xBB, count: payloadBytes)
                .write(to: cacheURL.appendingPathComponent("module.pcm"))
        }
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
    var devicesError: (any Error)?
    var runtimesError: (any Error)?

    func run(executableURL _: URL, arguments: [String]) async throws -> CommandOutput {
        switch arguments {
        case ["simctl", "list", "devices", "-j"]:
            if let devicesError {
                throw devicesError
            }
            return CommandOutput(stdout: Data(devicesJSON.utf8), stderr: Data(), terminationStatus: 0)
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

struct PendingCommandHandle: Sendable {
    let id: UUID
    let arguments: [String]
}

actor ControllableCommandRunner: CommandRunning {
    private(set) var recordedArguments: [[String]] = []
    private var queuedHandles: [PendingCommandHandle] = []
    private var inFlightCalls: [UUID: CheckedContinuation<CommandOutput, any Error>] = [:]
    private var waiters: [(id: UUID, continuation: CheckedContinuation<PendingCommandHandle, any Error>)] = []
    private var cancelledCallIDs: Set<UUID> = []
    private var cancellationWaiters: [UUID: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] = [:]

    var hasParkedCall: Bool {
        !inFlightCalls.isEmpty
    }

    var hasRegisteredWaiter: Bool {
        !waiters.isEmpty
    }

    func run(executableURL _: URL, arguments: [String]) async throws -> CommandOutput {
        recordedArguments.append(arguments)
        let callID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightCalls[callID] = continuation
                let handle = PendingCommandHandle(id: callID, arguments: arguments)
                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.continuation.resume(returning: handle)
                } else {
                    queuedHandles.append(handle)
                }
            }
        } onCancel: {
            Task { await self.cancelCall(id: callID) }
        }
    }

    func nextPendingCall() async throws -> PendingCommandHandle {
        if !queuedHandles.isEmpty {
            return queuedHandles.removeFirst()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !queuedHandles.isEmpty {
                    continuation.resume(returning: queuedHandles.removeFirst())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func resumeCall(id: UUID, with result: Result<CommandOutput, any Error>) {
        guard let continuation = inFlightCalls.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

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
        queuedHandles.removeAll { $0.id == id }
        cancelledCallIDs.insert(id)
        for waiter in cancellationWaiters.removeValue(forKey: id) ?? [] {
            waiter.continuation.resume()
        }
        guard let continuation = inFlightCalls.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
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
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - FileTrashing Test Adapters

struct TestTrashError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

actor RecordingFileTrasher: FileTrashing {
    private(set) var trashedURLs: [URL] = []
    private let failingPaths: Set<String>

    init(failingURLs: [URL] = []) {
        failingPaths = Set(failingURLs.map(\.path))
    }

    func trashItem(at url: URL) async throws {
        if failingPaths.contains(url.path) {
            throw TestTrashError(message: "Permission denied for \(url.lastPathComponent)")
        }
        trashedURLs.append(url)
    }
}

struct PendingTrashHandle: Sendable {
    let id: UUID
    let url: URL
}

actor ControllableFileTrasher: FileTrashing {
    private(set) var trashedURLs: [URL] = []
    private var queuedHandles: [PendingTrashHandle] = []
    private var inFlightCalls: [UUID: (url: URL, continuation: CheckedContinuation<Void, any Error>)] = [:]
    private var waiters: [(id: UUID, continuation: CheckedContinuation<PendingTrashHandle, any Error>)] = []

    var hasRegisteredWaiter: Bool {
        !waiters.isEmpty
    }

    func trashItem(at url: URL) async throws {
        let callID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                inFlightCalls[callID] = (url, continuation)
                let handle = PendingTrashHandle(id: callID, url: url)
                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.continuation.resume(returning: handle)
                } else {
                    queuedHandles.append(handle)
                }
            }
        } onCancel: {
            Task { await self.cancelCall(id: callID) }
        }
    }

    func nextPendingTrash() async throws -> PendingTrashHandle {
        if !queuedHandles.isEmpty {
            return queuedHandles.removeFirst()
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !queuedHandles.isEmpty {
                    continuation.resume(returning: queuedHandles.removeFirst())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    func resumeTrash(id: UUID, with result: Result<Void, any Error> = .success(())) {
        guard let entry = inFlightCalls.removeValue(forKey: id) else { return }
        if case .success = result {
            trashedURLs.append(entry.url)
        }
        entry.continuation.resume(with: result)
    }

    private func cancelCall(id: UUID) {
        queuedHandles.removeAll { $0.id == id }
        guard let entry = inFlightCalls.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
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
    let deadline = ContinuousClock.now + timeout
    let outcome = OSAllocatedUnfairLock<(result: Result<Success, any Error>, finishedAt: ContinuousClock.Instant)?>(
        initialState: nil
    )
    Task.detached {
        task.cancel()
        let result = await task.result
        let finishedAt = ContinuousClock.now
        outcome.withLock { $0 = (result, finishedAt) }
    }
    try await waitUntil("cancelled task finished", timeout: deadline - ContinuousClock.now) {
        outcome.withLock { $0 != nil }
    }
    let finished = try #require(outcome.withLock { $0 })
    guard finished.finishedAt <= deadline else {
        throw ConditionTimeoutError(description: "Cancelled task finished after its deadline")
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
