import Foundation

/// Runs external command-line tools such as `/usr/bin/xcrun`.
protocol CommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandOutput
}

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

/// Deadlock-free async wrapper around `Process` that drains stdout and stderr concurrently.
struct ProcessRunner: CommandRunning, Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> CommandOutput {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let commandDescription = ([executableURL.lastPathComponent] + arguments).joined(separator: " ")

            do {
                try process.run()
            } catch {
                throw ProcessRunnerError.launchFailed(
                    command: commandDescription,
                    underlying: error.localizedDescription
                )
            }

            let outHandle = stdoutPipe.fileHandleForReading
            let errHandle = stderrPipe.fileHandleForReading

            let outTask = Task.detached(priority: .userInitiated) {
                (try? outHandle.readToEnd()) ?? Data()
            }
            let errTask = Task.detached(priority: .userInitiated) {
                (try? errHandle.readToEnd()) ?? Data()
            }

            let stdoutData = await outTask.value
            let stderrData = await errTask.value
            process.waitUntilExit()

            let output = CommandOutput(
                stdout: stdoutData,
                stderr: stderrData,
                terminationStatus: process.terminationStatus
            )

            guard output.terminationStatus == 0 else {
                throw ProcessRunnerError.nonZeroExit(
                    command: commandDescription,
                    status: output.terminationStatus,
                    stderr: output.stderrString
                )
            }

            return output
        }.value
    }
}
