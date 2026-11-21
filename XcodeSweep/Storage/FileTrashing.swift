import Foundation

/// Moves filesystem items to macOS Trash.
protocol FileTrashing: Sendable {
    func trashItem(at url: URL) async throws
}

/// Production adapter that moves filesystem items to Trash using `FileManager`.
struct LiveFileTrasher: FileTrashing, Sendable {
    func trashItem(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }.value
    }
}
