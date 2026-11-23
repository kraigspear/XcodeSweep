import Foundation

/// Estimates the disk usage of files and directories.
///
/// Each file counts its allocated size, or its logical size when no allocated size is reported.
/// APFS clones and hard links are counted once per reference, so a total can exceed the space
/// that deleting the folder frees.
enum DirectorySizer {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .totalFileSizeKey,
        .fileSizeKey,
    ]

    /// Returns the estimated bytes used by `url` (file or directory), as described on the type.
    ///
    /// Does not follow symbolic links into external directories.
    ///
    /// - Throws: `CancellationError` if the task is cancelled mid-walk, so a partial walk is never
    ///   mistaken for a small or empty folder.
    static func allocatedSize(of url: URL) throws(CancellationError) -> Int64 {
        let fileManager = FileManager.default

        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isSymbolicLink == true
        {
            return singleFileSize(of: url)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return singleFileSize(of: url)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                continue
            }
            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true {
                let bytes = values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.totalFileSize
                    ?? values.fileSize
                    ?? 0
                total += Int64(bytes)
            }
        }
        return total
    }

    private static func singleFileSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return 0
        }
        let bytes = values.totalFileAllocatedSize
            ?? values.fileAllocatedSize
            ?? values.totalFileSize
            ?? values.fileSize
            ?? 0
        return Int64(bytes)
    }
}
