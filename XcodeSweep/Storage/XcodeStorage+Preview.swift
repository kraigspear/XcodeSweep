#if DEBUG && canImport(SwiftUI)
    import Foundation

    extension XcodeStorage {
        /// Storage that keeps previews away from the developer's Xcode data: it scans a missing
        /// folder in the temporary directory and refuses every command and Trash move.
        static let preview = XcodeStorage(
            xcodeRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("XcodeSweepPreview-\(UUID().uuidString)", isDirectory: true),
            commandRunner: PreviewRefusal(),
            fileTrasher: PreviewRefusal()
        )
    }

    private struct PreviewRefusal: CommandRunning, FileTrashing, LocalizedError {
        var errorDescription: String? {
            "Previews don't run commands or move files to Trash."
        }

        func run(executableURL _: URL, arguments _: [String], timeout _: Duration?) async throws -> CommandOutput {
            throw self
        }

        func trashItem(at _: URL) async throws {
            throw self
        }
    }
#endif
