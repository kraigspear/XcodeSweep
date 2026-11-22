import Foundation

/// Moves filesystem items to macOS Trash.
protocol FileTrashing: Sendable {
    func trashItem(at url: URL) async throws
}

/// Production adapter that moves filesystem items to Trash using `FileManager`.
struct LiveFileTrasher: FileTrashing, Sendable {
    /// `@concurrent` keeps the blocking move off the caller's actor, which is the main actor.
    @concurrent
    func trashItem(at url: URL) async throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}
