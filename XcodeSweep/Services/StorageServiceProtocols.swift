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

/// Scans Xcode and Simulator storage categories and computes disk capacity.
protocol StorageScanning: Sendable {
    func scanAll(
        onProgress: @escaping @Sendable (StorageCategory, [StorageItem]) -> Void
    ) async throws -> ScanSnapshot
}

/// Snapshot returned after scanning all storage categories.
struct ScanSnapshot: Equatable, Sendable {
    let itemsByCategory: [StorageCategory: [StorageItem]]
    let diskAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let warnings: [String]
}

/// Deletes user-selected storage items (Trash for files, `simctl` for simulators/runtimes).
protocol StorageDeleting: Sendable {
    func delete(
        items: [StorageItem],
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async -> DeletionReport
}
