import Foundation
import Testing
@testable import XcodeSweep

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Captures stdout and zero termination status from a local command")
    func runsCommandAndCapturesStdout() async throws {
        let runner = ProcessRunner()
        let output = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello-xcodesweep"]
        )

        #expect(output.terminationStatus == 0)
        #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-xcodesweep")
    }

    @Test("Throws nonZeroExit with status and stderr when command fails")
    func throwsNonZeroExitWithStderr() async {
        let runner = ProcessRunner()

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo something-failed >&2; exit 7"]
            )
            Issue.record("Expected ProcessRunnerError.nonZeroExit")
        } catch let ProcessRunnerError.nonZeroExit(_, status, stderr) {
            #expect(status == 7)
            #expect(stderr.contains("something-failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Throws launchFailed when executable does not exist")
    func throwsLaunchFailedForMissingExecutable() async {
        let runner = ProcessRunner()

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/xcodesweep-binary"),
                arguments: []
            )
            Issue.record("Expected ProcessRunnerError.launchFailed")
        } catch ProcessRunnerError.launchFailed {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Releases pipes when the executable fails to launch")
    func releasesPipesAfterFailedLaunches() async throws {
        let before = openDescriptorCount()
        for _ in 0 ..< 200 {
            _ = try? await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/nonexistent/xcodesweep-binary"),
                arguments: []
            )
        }
        // Each leaked run would hold four pipe descriptors. Foundation releases them through
        // autorelease pools, so wait for the count to settle; allow noise from parallel tests.
        try await waitUntil("failed launches released their pipes") {
            openDescriptorCount() - before < 100
        }
    }

    @Test(
        "Terminates a launched child promptly and throws CancellationError on task cancellation",
        .timeLimit(.minutes(1))
    )
    func terminatesLaunchedChildOnCancellation() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "\(PIDMarker.publishOwnPID); exec sleep 30", marker.path]
            )
        }
        defer { task.cancel() }
        let pid = try await marker.waitForPID()

        let result = try await cancelAndAwaitResult(of: task, within: .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        // The error arrives only after the child has exited.
        #expect(kill(pid, 0) != 0)
    }

    @Test(
        "Returns promptly on cancellation while a SIGTERM-immune grandchild holds the output pipe open",
        .timeLimit(.minutes(1))
    )
    func returnsPromptlyWhenGrandchildHoldsPipe() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", PIDMarker.spawnTermImmuneGrandchild(running: "sleep 30"), marker.path]
            )
        }
        defer { task.cancel() }
        let grandchildPID = try await marker.waitForPID()
        defer { kill(grandchildPID, SIGKILL) }

        let result = try await cancelAndAwaitResult(of: task, within: .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test(
        "Stops reading after cancellation so a grandchild still writing to the pipe is not buffered forever",
        .timeLimit(.minutes(1))
    )
    func stopsReadingAfterCancellation() async throws {
        // Given: a SIGTERM-immune grandchild writing to stdout without end
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", PIDMarker.spawnTermImmuneGrandchild(running: "yes"), marker.path]
            )
        }
        defer { task.cancel() }
        let grandchildPID = try await marker.waitForPID()
        defer { kill(grandchildPID, SIGKILL) }

        // When
        _ = try await cancelAndAwaitResult(of: task, within: .seconds(2))

        // Then: the runner closes its read end, so the writer gets SIGPIPE and exits
        try await waitUntil("grandchild writer exited") { kill(grandchildPID, 0) != 0 }
    }

    @Test(
        "Closes its pipes on cancellation even when the SIGTERM-immune direct child keeps writing",
        .timeLimit(.minutes(1))
    )
    func closesPipesWhenDirectChildIgnoresTerm() async throws {
        // Given: the direct child ignores SIGTERM and writes to stdout without end
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; \(PIDMarker.publishOwnPID); exec yes", marker.path]
            )
        }
        defer { task.cancel() }
        let childPID = try await marker.waitForPID()
        defer { kill(childPID, SIGKILL) }

        // When
        _ = try await cancelAndAwaitResult(of: task, within: .seconds(2))

        // Then: the closed read end makes the writer exit on SIGPIPE
        try await waitUntil("direct child writer exited") { kill(childPID, 0) != 0 }
    }

    @Test(
        "Closes its pipes when cancelled first and the direct child then exits, while a silent descendant holds them",
        .timeLimit(.minutes(1))
    )
    func closesPipesWhenCancelledBeforeDirectChildExits() async throws {
        let probe = try SilentDescendantProbe()
        defer { probe.cleanup() }

        // Given: the direct child waits on the silent descendant
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: probe.directChildArguments(waitsForDescendant: true)
            )
        }
        defer { task.cancel() }
        try await probe.waitForLaunch()

        // When: cancellation kills the direct child
        _ = try await cancelAndAwaitResult(of: task, within: .seconds(2))
        try await probe.waitForDirectChildExit()

        // Then
        try await probe.expectDescendantKilledByItsFirstWrite()
    }

    @Test(
        "Closes its pipes when the direct child exits first and the run is then cancelled, while a silent descendant holds them",
        .timeLimit(.minutes(1))
    )
    func closesPipesWhenDirectChildExitsBeforeCancellation() async throws {
        let probe = try SilentDescendantProbe()
        defer { probe.cleanup() }

        // Given: the direct child exits at once, leaving the run pending on the descendant's pipe
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: probe.directChildArguments(waitsForDescendant: false)
            )
        }
        defer { task.cancel() }
        try await probe.waitForLaunch()
        try await probe.waitForDirectChildExit()

        // When
        _ = try await cancelAndAwaitResult(of: task, within: .seconds(2))

        // Then
        try await probe.expectDescendantKilledByItsFirstWrite()
    }

    @Test("Never launches the executable when the task is already cancelled")
    func neverLaunchesWhenCancelledBeforeLaunch() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcodesweep-launched-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [markerURL.path]
            )
        }

        let result = try await cancelAndAwaitResult(of: task, within: .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test(
        "Drains more than pipe capacity on both streams across many concurrent commands",
        .timeLimit(.minutes(1))
    )
    func drainsLargeOutputOnBothStreamsConcurrently() async throws {
        let byteCount = 256 * 1024
        let script = "head -c \(byteCount) /dev/zero; head -c \(byteCount) /dev/zero >&2"
        let commandCount = ProcessInfo.processInfo.activeProcessorCount * 3

        let sizes = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for _ in 0 ..< commandCount {
                group.addTask {
                    let output = try await ProcessRunner().run(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", script]
                    )
                    return (output.stdout.count, output.stderr.count)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(sizes.count == commandCount)
        #expect(sizes.allSatisfy { $0 == (byteCount, byteCount) })
    }

    @Test("Throws timedOut once a command outlives its timeout", .timeLimit(.minutes(1)))
    func throwsTimedOutWhenDeadlinePasses() async {
        do {
            _ = try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: .milliseconds(250)
            )
            Issue.record("Expected ProcessRunnerError.timedOut")
        } catch let ProcessRunnerError.timedOut(command, timeout) {
            #expect(command.contains("sleep"))
            #expect(timeout == .milliseconds(250))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Returns output without waiting out an armed timeout", .timeLimit(.minutes(1)))
    func returnsOutputBeforeArmedTimeout() async throws {
        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["done"],
                timeout: .seconds(120)
            )
        }
        defer { task.cancel() }

        let output = try await awaitResult(of: task, within: .seconds(10)).get()
        #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
    }

    @Test("Throws CancellationError, not timedOut, when cancelled with a timeout armed", .timeLimit(.minutes(1)))
    func cancellationWinsOverArmedTimeout() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "\(PIDMarker.publishOwnPID); exec sleep 30", marker.path],
                timeout: .seconds(120)
            )
        }
        defer { task.cancel() }
        let pid = try await marker.waitForPID()
        defer { kill(pid, SIGKILL) }

        let result = try await cancelAndAwaitResult(of: task, within: .seconds(2))
        #expect(throws: CancellationError.self) { try result.get() }
        // The error arrives only after the child has exited.
        #expect(kill(pid, 0) != 0)
    }

    @Test("Terminates the child and throws timedOut when the deadline fires", .timeLimit(.minutes(1)))
    func timeOutTerminatesLaunchedChild() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }
        let run = ProcessRun(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "\(PIDMarker.publishOwnPID); exec sleep 30", marker.path]
        )
        let task = startTask(run)
        defer { run.cancel() }
        let pid = try await marker.waitForPID()
        defer { kill(pid, SIGKILL) }

        run.timeOut(after: .seconds(1))

        let result = try await awaitResult(of: task, within: .seconds(10))
        #expect(throws: ProcessRunnerError.self) { try result.get() }
        #expect(kill(pid, 0) != 0)
    }

    @Test(
        "Closes pipes on timeout so a SIGTERM-immune grandchild still writing exits on SIGPIPE",
        .timeLimit(.minutes(1))
    )
    func closesPipesWhenGrandchildOutlivesTimeout() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }
        let run = ProcessRun(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", PIDMarker.spawnTermImmuneGrandchild(running: "yes"), marker.path]
        )
        let task = startTask(run)
        defer { run.cancel() }
        let grandchildPID = try await marker.waitForPID()
        defer { kill(grandchildPID, SIGKILL) }

        run.timeOut(after: .seconds(1))

        let result = try await awaitResult(of: task, within: .seconds(10))
        #expect(throws: ProcessRunnerError.self) { try result.get() }
        try await waitUntil("grandchild writer exited on SIGPIPE") { kill(grandchildPID, 0) != 0 }
    }

    @Test("Kills a child that ignores SIGTERM after the grace period, then throws", .timeLimit(.minutes(1)))
    func killsChildThatIgnoresTermAfterGrace() async throws {
        let marker = PIDMarker()
        defer { marker.remove() }

        let task = Task {
            try await ProcessRunner(terminationGrace: .milliseconds(300)).run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; \(PIDMarker.publishOwnPID); exec sleep 30", marker.path]
            )
        }
        defer { task.cancel() }
        let pid = try await marker.waitForPID()
        defer { kill(pid, SIGKILL) }

        let result = try await cancelAndAwaitResult(of: task, within: .seconds(10))

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(kill(pid, 0) != 0)
    }

    @Test(
        "A run aborted before it starts never launches and reports that abort",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func abortBeforeStartNeverLaunches(byTimeout: Bool) async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcodesweep-never-\(UUID().uuidString)")
        let run = ProcessRun(executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path])

        if byTimeout {
            run.timeOut(after: .seconds(1))
        } else {
            run.cancel()
        }
        let result = try await awaitResult(of: startTask(run), within: .seconds(10))

        if byTimeout {
            #expect(throws: ProcessRunnerError.self) { try result.get() }
        } else {
            #expect(throws: CancellationError.self) { try result.get() }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(
        "The first abort decides the result when cancellation and timeout both arrive",
        .timeLimit(.minutes(1)),
        arguments: [false, true]
    )
    func firstAbortWins(timeoutFirst: Bool) async throws {
        let marker = PIDMarker()
        defer { marker.remove() }
        let run = ProcessRun(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "\(PIDMarker.publishOwnPID); exec sleep 30", marker.path]
        )
        let task = startTask(run)
        let pid = try await marker.waitForPID()
        defer { kill(pid, SIGKILL) }

        // A second resume of the continuation would trap, so reaching the assertions proves one result.
        if timeoutFirst {
            run.timeOut(after: .seconds(1))
            run.cancel()
        } else {
            run.cancel()
            run.timeOut(after: .seconds(1))
        }
        let result = try await awaitResult(of: task, within: .seconds(10))

        if timeoutFirst {
            #expect(throws: ProcessRunnerError.self) { try result.get() }
        } else {
            #expect(throws: CancellationError.self) { try result.get() }
        }
    }
}

private func startTask(_ run: ProcessRun) -> Task<CommandOutput, any Error> {
    Task { try await withCheckedThrowingContinuation { run.start($0) } }
}

// MARK: - Helpers

/// A file a child process writes its pid into, published atomically once the process is ready.
private struct PIDMarker {
    /// Shell snippet: write this shell's pid to the marker path passed as `$0`.
    static let publishOwnPID = #"echo $$ > "$0.tmp" && mv "$0.tmp" "$0""#

    /// Shell script: start a grandchild that ignores SIGTERM, publishes its own pid once the trap is
    /// installed, then execs `command` with the inherited stdout; the parent waits on it.
    static func spawnTermImmuneGrandchild(running command: String) -> String {
        #"/bin/sh -c "trap '' TERM; echo \$\$ > \"\$0.tmp\" && mv \"\$0.tmp\" \"\$0\"; exec "# + command + #"" "$0" & wait"#
    }

    let url: URL

    init(directory: URL = FileManager.default.temporaryDirectory) {
        url = directory.appendingPathComponent("xcodesweep-pid-\(UUID().uuidString)")
    }

    var path: String {
        url.path
    }

    func waitForPID() async throws -> pid_t {
        try await waitUntil("pid marker published") {
            FileManager.default.fileExists(atPath: url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A SIGTERM-immune descendant that holds the runner's stdout without writing until the test
/// signals it, then writes once. That write raises SIGPIPE, killing it, only if the runner has
/// already closed its read end.
private struct SilentDescendantProbe {
    private let directoryURL: URL
    private let descendantPIDMarker: PIDMarker
    private let directChildPIDMarker: PIDMarker

    init() throws {
        // The apostrophe keeps the scripts honest about quoting the paths they are handed.
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcodesweep-probe-it's-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        descendantPIDMarker = PIDMarker(directory: directoryURL)
        directChildPIDMarker = PIDMarker(directory: directoryURL)
        try """
        trap '' TERM
        echo $$ > "$1.tmp" && mv "$1.tmp" "$1"
        while [ ! -e "$2" ]; do sleep 0.05; done
        echo poke
        exec sleep 30
        """.write(to: descendantScriptURL, atomically: true, encoding: .utf8)
    }

    private var descendantScriptURL: URL {
        directoryURL.appendingPathComponent("descendant.sh")
    }

    private var writeSignalURL: URL {
        directoryURL.appendingPathComponent("write")
    }

    /// Arguments for `/bin/sh` that run the direct child. Paths travel as positional parameters,
    /// never inside the script text, so no path character needs quoting.
    func directChildArguments(waitsForDescendant: Bool) -> [String] {
        let script = #"echo $$ > "$0.tmp" && mv "$0.tmp" "$0"; /bin/sh "$1" "$2" "$3" &"#
            + (waitsForDescendant ? " wait" : "")
        return [
            "-c", script,
            directChildPIDMarker.path,
            descendantScriptURL.path,
            descendantPIDMarker.path,
            writeSignalURL.path,
        ]
    }

    func waitForLaunch() async throws {
        _ = try await descendantPIDMarker.waitForPID()
        _ = try await directChildPIDMarker.waitForPID()
    }

    func waitForDirectChildExit() async throws {
        let pid = try await directChildPIDMarker.waitForPID()
        try await waitUntil("direct child exited") { kill(pid, 0) != 0 }
        // Exit is observed when the child is reaped; give the runner's exit handling a moment.
        try await Task.sleep(for: .milliseconds(300))
    }

    func expectDescendantKilledByItsFirstWrite() async throws {
        let pid = try await descendantPIDMarker.waitForPID()
        FileManager.default.createFile(atPath: writeSignalURL.path, contents: nil)
        try await waitUntil("descendant exited on its first write") { kill(pid, 0) != 0 }
    }

    func cleanup() {
        if let text = try? String(contentsOf: descendantPIDMarker.url, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            kill(pid, SIGKILL)
        }
        descendantPIDMarker.remove()
        directChildPIDMarker.remove()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
}
