import Foundation
import os

/// Runs external command-line tools such as `/usr/bin/xcrun`.
protocol CommandRunning: Sendable {
    /// Runs `executableURL` with `arguments` to completion and returns its output.
    ///
    /// - Parameter timeout: How long to wait before giving up on the command, or `nil` to wait until it
    ///   finishes. On expiry the command is asked to stop; it may outlive the call.
    /// - Throws: An implementation-specific error when the command can't run, times out, or fails.
    func run(executableURL: URL, arguments: [String], timeout: Duration?) async throws -> CommandOutput
}

/// Captured output and exit status of a finished command.
struct CommandOutput: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32

    var stdoutString: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: stderr, as: UTF8.self)
    }
}

/// A command that couldn't launch, timed out, or exited with a nonzero status.
enum ProcessRunnerError: LocalizedError, Sendable {
    case launchFailed(command: String, underlying: String)
    case nonZeroExit(command: String, status: Int32, stderr: String)
    case timedOut(command: String, timeout: Duration)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(command, underlying):
            return "Failed to launch \(command): \(underlying)"
        case let .nonZeroExit(command, status, stderr):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if details.isEmpty {
                return "\(command) exited with status \(status)."
            }
            return "\(command) exited with status \(status): \(details)"
        case let .timedOut(command, timeout):
            let duration = timeout.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated))
            return "\(command) timed out after \(duration)."
        }
    }
}

/// Async wrapper around `Process` that collects stdout and stderr through readability callbacks.
///
/// Callbacks keep cooperative threads free while a command runs. On Swift task cancellation or
/// timeout the runner sends the child SIGTERM, discards its output, and throws `CancellationError`
/// or `ProcessRunnerError.timedOut` right away; it does not wait for the child or a descendant
/// holding a pipe to exit. The pipes close at their next activity or when the direct child exits,
/// whichever comes first.
struct ProcessRunner: CommandRunning, Sendable {
    /// - Throws: `ProcessRunnerError` when launch fails, the command times out, or the exit status
    ///   is nonzero; or `CancellationError` when the task is cancelled.
    func run(executableURL: URL, arguments: [String], timeout: Duration? = nil) async throws -> CommandOutput {
        try Task.checkCancellation()

        let run = ProcessRun(
            executableURL: executableURL,
            arguments: arguments
        )
        // Weak, so a pending deadline never keeps a finished run alive.
        let timeoutTask: Task<Void, Never>? = timeout.map { limit in
            Task { [weak run] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                run?.timeOut(after: limit)
            }
        }
        defer { timeoutTask?.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            timeoutTask?.cancel()
            run.cancel()
        }
    }
}

/// One command execution. The lock decides which path resumes the caller, exactly once: `start`
/// resumes directly when the run was already aborted or launch fails; otherwise it stores the
/// continuation, and cancellation, timeout, or completion takes it under the lock.
final class ProcessRun: Sendable {
    private struct State {
        var continuation: CheckedContinuation<CommandOutput, any Error>?
        var abortError: (any Error)?
        var stdout = Data()
        var stderr = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var exited = false

        var isAborted: Bool {
            abortError != nil
        }
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let commandDescription: String
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        commandDescription = ([executableURL.lastPathComponent] + arguments).joined(separator: " ")
    }

    func start(_ continuation: CheckedContinuation<CommandOutput, any Error>) {
        // The lock orders launch against `cancel` and `timeOut`: an aborted run never launches.
        let launchError: (any Error)? = state.withLockUnchecked { state in
            if let abortError = state.abortError {
                return abortError
            }
            state.continuation = continuation
            installHandlers()
            do {
                try process.run()
                return nil
            } catch {
                state.continuation = nil
                removeHandlers()
                return ProcessRunnerError.launchFailed(
                    command: commandDescription,
                    underlying: error.localizedDescription
                )
            }
        }
        if let launchError {
            continuation.resume(throwing: launchError)
        }
    }

    func cancel() {
        abort(with: CancellationError())
    }

    func timeOut(after timeout: Duration) {
        abort(with: ProcessRunnerError.timedOut(command: commandDescription, timeout: timeout))
    }

    private func abort(with error: any Error) {
        let action: (continuation: CheckedContinuation<CommandOutput, any Error>?, hasExited: Bool)? =
            state.withLockUnchecked { state in
                guard !state.isAborted else { return nil }
                state.abortError = error
                state.stdout = Data()
                state.stderr = Data()
                return (state.continuation.take(), state.exited)
            }
        guard let (continuation, hasExited) = action else { return }
        if hasExited {
            releasePipesHeldByDescendants()
        }
        // The read handlers stay installed: their next callback sees the abort and closes
        // its pipe, whether or not the child exits.
        if process.isRunning {
            process.terminate()
        }
        continuation?.resume(throwing: error)
    }

    private func installHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(from: handle, isStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(from: handle, isStdout: false)
        }
        process.terminationHandler = { [self] _ in
            let isAborted = state.withLockUnchecked { state in
                state.exited = true
                return state.isAborted
            }
            if isAborted {
                releasePipesHeldByDescendants()
            }
            finishIfComplete()
        }
    }

    /// Once the run is both aborted and exited, whichever happens second calls this: a silent
    /// descendant may hold the pipes open with no further callbacks, so dropping the handlers is
    /// what releases this run, and with it the read ends.
    private func releasePipesHeldByDescendants() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Breaks the handler-to-run retain cycles for a process that never launched.
    private func removeHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    /// Runs on the handle's own callback queue, so closing the handle here cannot race a read.
    private func receive(from handle: FileHandle, isStdout: Bool) {
        if state.withLockUnchecked({ $0.isAborted }) {
            // Closing the read end makes a writer that outlived cancellation or timeout get SIGPIPE.
            handle.readabilityHandler = nil
            try? handle.close()
            return
        }
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
        }
        state.withLockUnchecked { state in
            switch (isStdout, data.isEmpty) {
            case (true, true): state.stdoutClosed = true
            case (true, false): state.stdout.append(data)
            case (false, true): state.stderrClosed = true
            case (false, false): state.stderr.append(data)
            }
        }
        finishIfComplete()
    }

    private func finishIfComplete() {
        let finished = state.withLockUnchecked { state -> (
            CheckedContinuation<CommandOutput, any Error>,
            CommandOutput
        )? in
            guard !state.isAborted, state.exited, state.stdoutClosed, state.stderrClosed,
                  let continuation = state.continuation.take()
            else { return nil }
            return (continuation, CommandOutput(
                stdout: state.stdout,
                stderr: state.stderr,
                terminationStatus: process.terminationStatus
            ))
        }
        guard let (continuation, output) = finished else { return }

        guard output.terminationStatus == 0 else {
            continuation.resume(throwing: ProcessRunnerError.nonZeroExit(
                command: commandDescription,
                status: output.terminationStatus,
                stderr: output.stderrString
            ))
            return
        }
        continuation.resume(returning: output)
    }
}
