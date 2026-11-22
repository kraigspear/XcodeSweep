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

        return await Self.scanConcurrently(candidates) { folderURL in
            Self.inspectDerivedDataFolder(at: folderURL, now: now)
        }
    }

    // MARK: - Private Inspection

    private static func inspectDerivedDataFolder(at folderURL: URL, now: Date) -> StorageItem {
        let fileManager = FileManager.default
        let folderName = folderURL.lastPathComponent
        let plist = loadPlist(at: folderURL.appendingPathComponent("info.plist"))

        let workspacePath = plist?["WorkspacePath"] as? String
        let lastAccessed = (plist?["LastAccessedDate"] as? Date) ?? modificationDate(of: folderURL)
        let sizeBytes = DirectorySizer.allocatedSize(of: folderURL)

        let presence = workspacePath.map(workspacePresence(atPath:)) ?? .missing
        let status = classifyDerivedDataStatus(
            workspacePath: workspacePath,
            presence: presence,
            lastAccessed: lastAccessed,
            now: now,
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
            metadata.append(MetadataEntry(key: "Workspace Exists", value: presence.label))
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
        presence: WorkspacePresence,
        lastAccessed: Date?,
        now: Date,
        fileManager: FileManager
    ) -> ItemStatus {
        guard let workspacePath, !workspacePath.isEmpty, presence != .missing else {
            return .orphaned
        }

        if isWorktreePath(workspacePath, fileManager: fileManager) {
            return .worktree
        }

        return StorageCategory.derivedData.ageStatus(lastUsed: lastAccessed, now: now)
    }

    /// Whether the workspace at `path` exists, is provably gone, or can't be checked.
    ///
    /// Only `ENOENT` on a reachable parent proves it gone. A permission or TCC denial, or a path on
    /// a volume that isn't mounted, is unreachable: the project may be fine.
    private static func workspacePresence(atPath path: String) -> WorkspacePresence {
        switch statErrno(path) {
        case 0:
            return .present
        case ENOENT, ENOTDIR:
            break
        default:
            return .unreachable
        }

        var ancestor = URL(fileURLWithPath: path).standardized.deletingLastPathComponent()
        while true {
            switch statErrno(ancestor.path) {
            case 0:
                // A missing mount point under /Volumes is an unmounted volume.
                return ancestor.path == "/Volumes" ? .unreachable : .missing
            case ENOENT, ENOTDIR:
                ancestor.deleteLastPathComponent()
            default:
                return .unreachable
            }
        }
    }

    private static func statErrno(_ path: String) -> Int32 {
        var info = stat()
        return stat(path, &info) == 0 ? 0 : errno
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

/// Whether a DerivedData folder's recorded workspace is still on disk.
private enum WorkspacePresence: Equatable, Sendable {
    case present
    /// Provably gone: its parent folder is readable and doesn't contain it.
    case missing
    /// Couldn't be checked, such as a denied folder or an unmounted volume.
    case unreachable

    var label: String {
        switch self {
        case .present: "Yes"
        case .missing: "No (Deleted or Moved)"
        case .unreachable: "Unknown (Not Accessible)"
        }
    }
}
