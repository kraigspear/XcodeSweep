import Foundation

/// Moves filesystem items to macOS Trash.
protocol FileTrashing: Sendable {
    func trashItem(at url: URL) async throws
}

/// Production adapter that moves filesystem items to Trash using `FileManager`.
struct LiveFileTrasher: FileTrashing, Sendable {
    /// `@concurrent` keeps the blocking move off the main actor even if the project adopts
    /// caller-isolated async functions, under which a deletion started on the main actor would run it there.
    @concurrent
    func trashItem(at url: URL) async throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}
