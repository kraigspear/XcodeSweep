import Foundation

/// Scans `~/Library/Developer/Xcode/DerivedData` and inspects each folder's `info.plist`
/// to identify orphaned projects and git worktree builds.
struct DerivedDataScanner: Sendable {
    private let derivedDataURL: URL
    private let staleThresholdDays: Int

    init(
        derivedDataURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
        staleThresholdDays: Int = 30
    ) {
        self.derivedDataURL = derivedDataURL
        self.staleThresholdDays = staleThresholdDays
    }

    func scan() async -> [StorageItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let candidates = entries.filter { url in
            guard url.lastPathComponent != "ModuleCache.noindex" else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }

        let now = Date()
        let threshold = TimeInterval(staleThresholdDays) * 86400

        return await withTaskGroup(of: StorageItem?.self, returning: [StorageItem].self) { group in
            for folderURL in candidates {
                group.addTask {
                    Self.inspectDerivedDataFolder(
                        at: folderURL,
                        now: now,
                        staleThreshold: threshold
                    )
                }
            }

            var items: [StorageItem] = []
            for await item in group {
                if let item {
                    items.append(item)
                }
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    // MARK: - Folder Inspection

    static func inspectDerivedDataFolder(
        at folderURL: URL,
        now: Date = Date(),
        staleThreshold: TimeInterval = 30 * 86400
    ) -> StorageItem {
        let fileManager = FileManager.default
        let folderName = folderURL.lastPathComponent
        let infoPlistURL = folderURL.appendingPathComponent("info.plist")
        let parsedInfo = parseInfoPlist(at: infoPlistURL)

        let workspacePath = parsedInfo?.workspacePath
        let lastAccessed = parsedInfo?.lastAccessedDate
            ?? (try? folderURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let sizeBytes = DirectorySizer.allocatedSize(of: folderURL)
        let status = classifyStatus(
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

    static func parseInfoPlist(at url: URL) -> DerivedDataInfo? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        let workspacePath = plist["WorkspacePath"] as? String
        let lastAccessedDate = plist["LastAccessedDate"] as? Date
        return DerivedDataInfo(workspacePath: workspacePath, lastAccessedDate: lastAccessedDate)
    }

    static func classifyStatus(
        workspacePath: String?,
        lastAccessed: Date?,
        now: Date,
        staleThreshold: TimeInterval,
        fileManager: FileManager = .default
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
    static func isWorktreePath(_ workspacePath: String, fileManager: FileManager = .default) -> Bool {
        let lowercased = workspacePath.lowercased()
        if lowercased.contains("worktree") {
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

struct DerivedDataInfo: Equatable, Sendable {
    let workspacePath: String?
    let lastAccessedDate: Date?
}
