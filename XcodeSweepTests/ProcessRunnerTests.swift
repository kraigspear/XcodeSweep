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
}
