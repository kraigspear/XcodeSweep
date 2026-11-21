import Foundation
import Testing
@testable import XcodeSweep

@Suite("DerivedDataScanner")
struct DerivedDataScannerTests {
    @Test("Marks DerivedData folder as orphaned when WorkspacePath no longer exists")
    func orphanedWhenWorkspaceMissing() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let derivedFolder = tempRoot.appendingPathComponent("SampleApp-abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedFolder, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "WorkspacePath": "/nonexistent/path/sampleapp-worktrees/feature-123/SampleApp.xcodeproj",
            "LastAccessedDate": Date(),
        ]
        try writePlist(plist, to: derivedFolder.appendingPathComponent("info.plist"))

        let item = DerivedDataScanner.inspectDerivedDataFolder(at: derivedFolder)
        #expect(item.name == "SampleApp")
        #expect(item.status == .orphaned)
        #expect(item.isReclaimableCandidate)
    }

    @Test("Detects active git worktree via .git pointer file")
    func detectsGitWorktree() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Simulate a linked git worktree: `.git` is a regular file, not a directory.
        let repoRoot = tempRoot.appendingPathComponent("feature-branch", isDirectory: true)
        let projectURL = repoRoot.appendingPathComponent("SampleApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "gitdir: /somewhere/.git/worktrees/feature-branch".write(
            to: repoRoot.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let derivedFolder = tempRoot.appendingPathComponent("SampleApp-wt123", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedFolder, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "WorkspacePath": projectURL.path,
            "LastAccessedDate": Date(),
        ]
        try writePlist(plist, to: derivedFolder.appendingPathComponent("info.plist"))

        let item = DerivedDataScanner.inspectDerivedDataFolder(at: derivedFolder)
        #expect(item.status == .worktree)
        #expect(!item.isReclaimableCandidate)
    }

    @Test("Classifies untouched existing project older than threshold as stale")
    func classifiesOldProjectAsStale() throws {
        let tempRoot = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projectURL = tempRoot.appendingPathComponent("OldApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let derivedFolder = tempRoot.appendingPathComponent("OldApp-xyz", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedFolder, withIntermediateDirectories: true)

        let sixtyDaysAgo = Date().addingTimeInterval(-60 * 86_400)
        let plist: [String: Any] = [
            "WorkspacePath": projectURL.path,
            "LastAccessedDate": sixtyDaysAgo,
        ]
        try writePlist(plist, to: derivedFolder.appendingPathComponent("info.plist"))

        let item = DerivedDataScanner.inspectDerivedDataFolder(at: derivedFolder)
        #expect(item.status == .stale)
        #expect(item.isReclaimableCandidate)
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcodeSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }
}
