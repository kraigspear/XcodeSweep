import Foundation

extension XcodeStorage {
    static let moduleCacheFolderName = "ModuleCache.noindex"

    func scanDerivedData(_ projectFolders: [URL], now: Date) async -> [StorageItem] {
        await Self.scanConcurrently(projectFolders, limiter: folderWalkLimiter) { folderURL in
            try Self.inspectDerivedDataFolder(at: folderURL, now: now)
        }
    }

    /// DerivedData's folders, split into per-project build folders and caches Xcode shares across
    /// projects, such as `ModuleCache.noindex` and `SDKExplicitPrecompiledModules`.
    ///
    /// A project folder has an `info.plist`, or is named `<Project>-<28 lowercase letters>` and has
    /// lost it. Anything else is a shared cache: Xcode adds new ones without notice, so they aren't listed by name.
    func derivedDataFolders() -> (projects: [URL], sharedCaches: [URL]) {
        let derivedDataURL = xcodeLocations.derivedDataURL
        let isCustom = xcodeLocations.hasCustomDerivedData
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: derivedDataURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        let folders = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        // One check per folder, so a plist appearing mid-classification can't put it in both lists or neither.
        var projects: [URL] = []
        var sharedCaches: [URL] = []
        for folder in folders {
            let plistURL = folder.appendingPathComponent("info.plist")
            // A custom folder may hold anything, such as a repository with its own Info.plist, so
            // there only Xcode's own plist, which records the workspace, counts.
            let hasXcodePlist = isCustom
                ? Self.loadPlist(at: plistURL)?["WorkspacePath"] is String
                : fileManager.fileExists(atPath: plistURL.path)
            let isProject = hasXcodePlist || folder.lastPathComponent.wholeMatch(of: /.+-[a-z]{28}/) != nil
            if isProject {
                projects.append(folder)
            } else {
                sharedCaches.append(folder)
            }
        }
        return (projects, sharedCaches)
    }

    // MARK: - Private Inspection

    private static func inspectDerivedDataFolder(at folderURL: URL, now: Date) throws(CancellationError) -> StorageItem {
        let fileManager = FileManager.default
        let folderName = folderURL.lastPathComponent
        let plist = loadPlist(at: folderURL.appendingPathComponent("info.plist"))

        let workspacePath = plist?["WorkspacePath"] as? String
        let lastAccessed = (plist?["LastAccessedDate"] as? Date) ?? modificationDate(of: folderURL)
        let sizeBytes = try DirectorySizer.allocatedSize(of: folderURL)

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
    /// Gone means `ENOENT` or `ENOTDIR` all the way up to an ancestor that exists: path lookup
    /// through a searchable folder is authoritative. A permission or TCC denial, a dangling
    /// symlink, or a missing mount point in `/Volumes` is unreachable: the project may be fine.
    private static func workspacePresence(atPath path: String) -> WorkspacePresence {
        var current = URL(fileURLWithPath: path)
        switch fileStatus(current.path).error {
        case 0:
            return .present
        case ENOENT, ENOTDIR:
            break
        default:
            return .unreachable
        }

        while true {
            // A link that resolves nowhere may point at a drive that is ejected.
            if fileStatus(current.path, followingLinks: false).error == 0 {
                return .unreachable
            }
            current.deleteLastPathComponent()
            let ancestor = fileStatus(current.path)
            switch ancestor.error {
            case 0:
                return isVolumesFolder(ancestor.info) ? .unreachable : .missing
            case ENOENT, ENOTDIR:
                continue
            default:
                return .unreachable
            }
        }
    }

    /// Compared by identity, since `/Volumes` is also reachable as `/System/Volumes/Data/Volumes`.
    private static func isVolumesFolder(_ info: stat) -> Bool {
        let volumes = fileStatus("/Volumes")
        return volumes.error == 0 && volumes.info.st_dev == info.st_dev && volumes.info.st_ino == info.st_ino
    }

    private static func fileStatus(_ path: String, followingLinks: Bool = true) -> (error: Int32, info: stat) {
        var info = stat()
        let result = followingLinks ? stat(path, &info) : lstat(path, &info)
        return (result == 0 ? 0 : errno, info)
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
    /// Provably gone: lookup fails with `ENOENT` or `ENOTDIR` up to the nearest existing ancestor.
    case missing
    /// Couldn't be checked, such as a denied folder, a dangling symlink, or an unmounted volume.
    case unreachable

    var label: String {
        switch self {
        case .present: "Yes"
        case .missing: "No (Deleted or Moved)"
        case .unreachable: "Unknown (Not Accessible)"
        }
    }
}
