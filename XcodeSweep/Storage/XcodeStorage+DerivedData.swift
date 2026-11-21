import Foundation

extension XcodeStorage {
    static let moduleCacheFolderName = "ModuleCache.noindex"

    func scanDerivedData(now: Date) async -> [StorageItem] {
        let derivedDataURL = xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let candidates = entries.filter { url in
            guard url.lastPathComponent != Self.moduleCacheFolderName else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }

        let threshold = StalenessPolicy.threshold(days: StalenessPolicy.derivedDataDays)
        return await Self.scanConcurrently(candidates) { folderURL in
            Self.inspectDerivedDataFolder(at: folderURL, now: now, staleThreshold: threshold)
        }
    }

    // MARK: - Private Inspection

    private static func inspectDerivedDataFolder(
        at folderURL: URL,
        now: Date,
        staleThreshold: TimeInterval
    ) -> StorageItem {
        let fileManager = FileManager.default
        let folderName = folderURL.lastPathComponent
        let plist = loadPlist(at: folderURL.appendingPathComponent("info.plist"))

        let workspacePath = plist?["WorkspacePath"] as? String
        let lastAccessed = (plist?["LastAccessedDate"] as? Date) ?? modificationDate(of: folderURL)
        let sizeBytes = DirectorySizer.allocatedSize(of: folderURL)

        let status = classifyDerivedDataStatus(
            workspacePath: workspacePath,
            lastAccessed: lastAccessed,
            now: now,
            staleThreshold: staleThreshold,
            fileManager: fileManager
        )

        let displayName = projectDisplayName(folderName: folderName, workspacePath: workspacePath)
        let subtitle = workspaceSubtitle(workspacePath: workspacePath, status: status, folderName: folderName)

        var metadata: [MetadataEntry] = [
            MetadataEntry(key: "Folder", value: folderName),
            MetadataEntry(key: "Path", value: folderURL.path),
        ]
        if let workspacePath {
            metadata.append(MetadataEntry(key: "Workspace", value: workspacePath))
            let exists = fileManager.fileExists(atPath: workspacePath)
            metadata.append(MetadataEntry(key: "Workspace Exists", value: exists ? "Yes" : "No (Deleted or Moved)"))
        } else {
            metadata.append(MetadataEntry(key: "Workspace", value: "Missing info.plist"))
        }

        return StorageItem(
            id: "derivedData:\(folderURL.path)",
            category: .derivedData,
            name: displayName,
            subtitle: subtitle,
            sizeBytes: sizeBytes,
            lastUsedDate: lastAccessed,
            path: folderURL,
            workspacePath: workspacePath,
            status: status,
            deletionMethod: .trashFile(folderURL),
            metadata: metadata
        )
    }

    private static func classifyDerivedDataStatus(
        workspacePath: String?,
        lastAccessed: Date?,
        now: Date,
        staleThreshold: TimeInterval,
        fileManager: FileManager
    ) -> ItemStatus {
        guard let workspacePath, !workspacePath.isEmpty, fileManager.fileExists(atPath: workspacePath) else {
            return .orphaned
        }

        if isWorktreePath(workspacePath, fileManager: fileManager) {
            return .worktree
        }

        if let lastAccessed, now.timeIntervalSince(lastAccessed) > staleThreshold {
            return .stale
        }

        return .active
    }

    /// Detects git worktrees either by path convention or by finding a `.git` file (worktree pointer) walking upward.
    private static func isWorktreePath(_ workspacePath: String, fileManager: FileManager) -> Bool {
        if workspacePath.lowercased().contains("worktree") {
            return true
        }

        var currentURL = URL(fileURLWithPath: workspacePath)
        for _ in 0 ..< 6 {
            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path {
                break
            }
            currentURL = parent

            let dotGitURL = currentURL.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDir) {
                // In a linked git worktree, `.git` is a regular file pointing to the main repo's `.git/worktrees/...`.
                return !isDir.boolValue
            }
        }
        return false
    }

    private static func projectDisplayName(folderName: String, workspacePath: String?) -> String {
        if let workspacePath {
            let url = URL(fileURLWithPath: workspacePath)
            let projectName = url.deletingPathExtension().lastPathComponent
            if !projectName.isEmpty {
                return projectName
            }
        }
        if let dashIndex = folderName.lastIndex(of: "-") {
            let prefix = String(folderName[..<dashIndex])
            if !prefix.isEmpty {
                return prefix
            }
        }
        return folderName
    }

    private static func workspaceSubtitle(
        workspacePath: String?,
        status: ItemStatus,
        folderName: String
    ) -> String {
        guard let workspacePath else {
            return "Missing info.plist — \(folderName)"
        }
        let shortened = workspacePath.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
        if status == .orphaned {
            return "Missing: \(shortened)"
        }
        return shortened
    }
}
