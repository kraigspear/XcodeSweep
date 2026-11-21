import Foundation

/// Calculates APFS-accurate allocated disk usage for files and directories.
enum DirectorySizer {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .totalFileSizeKey,
        .fileSizeKey,
    ]

    /// Returns the total allocated bytes on disk for `url` (file or directory).
    ///
    /// Does not follow symbolic links into external directories.
    static func allocatedSize(of url: URL) -> Int64 {
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
