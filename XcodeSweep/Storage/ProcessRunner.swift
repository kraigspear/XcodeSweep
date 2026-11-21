import Foundation
import os

/// Runs external command-line tools such as `/usr/bin/xcrun`.
protocol CommandRunning: Sendable {
    /// Runs `executableURL` with `arguments` to completion and returns its output.
    ///
    /// - Throws: An implementation-specific error when the command can't run or fails.
    func run(executableURL: URL, arguments: [String]) async throws -> CommandOutput
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

/// A command that couldn't launch or exited with a nonzero status.
enum ProcessRunnerError: LocalizedError, Sendable {
    case launchFailed(command: String, underlying: String)
    case nonZeroExit(command: String, status: Int32, stderr: String)

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
        }
    }
}

/// Async wrapper around `Process` that collects stdout and stderr through readability callbacks.
///
/// Callbacks keep cooperative threads free while a command runs. On Swift task cancellation the
/// runner sends the child SIGTERM, discards its output, and throws `CancellationError` right away;
/// it does not wait for the child or a descendant holding a pipe to exit. The pipes close at their
/// next activity or when the direct child exits, whichever comes first.
struct ProcessRunner: CommandRunning, Sendable {
    /// - Throws: `ProcessRunnerError` when launch fails or the exit status is nonzero, or
    ///   `CancellationError` when the task is cancelled.
    func run(executableURL: URL, arguments: [String]) async throws -> CommandOutput {
        let run = Run(
            executableURL: executableURL,
            arguments: arguments
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// One command execution. The lock decides which path resumes the caller, exactly once: `start`
/// resumes directly when the task was already cancelled or launch fails; otherwise it stores the
/// continuation, and cancellation or completion takes it under the lock.
private final class Run: Sendable {
    private struct State {
        var continuation: CheckedContinuation<CommandOutput, any Error>?
        var isCancelled = false
        var stdout = Data()
        var stderr = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var exited = false
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
        // The lock orders launch against `cancel`: a cancelled run never launches.
        let launchError: (any Error)? = state.withLockUnchecked { state in
            if state.isCancelled {
                return CancellationError()
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
        let (continuation, hasExited) = state.withLockUnchecked { state in
            state.isCancelled = true
            state.stdout = Data()
            state.stderr = Data()
            return (state.continuation.take(), state.exited)
        }
        if hasExited {
            releasePipesHeldByDescendants()
        }
        // The read handlers stay installed: their next callback sees the cancellation and closes
        // its pipe, whether or not the child exits.
        if process.isRunning {
            process.terminate()
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func installHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(from: handle, isStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            receive(from: handle, isStdout: false)
        }
        process.terminationHandler = { [self] _ in
            let isCancelled = state.withLockUnchecked { state in
                state.exited = true
                return state.isCancelled
            }
            if isCancelled {
                releasePipesHeldByDescendants()
            }
            finishIfComplete()
        }
    }

    /// Once the run is both cancelled and exited, whichever happens second calls this: a silent
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
        if state.withLockUnchecked({ $0.isCancelled }) {
            // Closing the read end makes a writer that outlived cancellation get SIGPIPE.
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
            guard state.exited, state.stdoutClosed, state.stderrClosed,
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
