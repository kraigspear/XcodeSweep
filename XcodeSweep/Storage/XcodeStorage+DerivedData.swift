import Foundation

extension XcodeStorage {
    static let moduleCacheFolderName = "ModuleCache.noindex"

    /// `failure` is why the DerivedData folder couldn't be listed, found when its folders were classified.
    func scanDerivedData(_ projectFolders: [URL], failure: String?, now: Date) async -> CategoryScan {
        let items = await Self.scanConcurrently(projectFolders, limiter: folderWalkLimiter) { folderURL in
            try Self.inspectDerivedDataFolder(at: folderURL, now: now)
        }
        return CategoryScan(items: Self.namingFoldersOfSharedWorkspaces(items), failure: failure)
    }

    /// Rows built from the same workspace, such as Xcode's folder and an `xcodebuild -derivedDataPath`
    /// one, otherwise look identical, so their subtitles name the folder.
    private static func namingFoldersOfSharedWorkspaces(_ items: [StorageItem]) -> [StorageItem] {
        let countsByWorkspace = Dictionary(items.compactMap { $0.workspacePath.map { ($0, 1) } }, uniquingKeysWith: +)
        return items.map { item in
            guard let workspacePath = item.workspacePath,
                  countsByWorkspace[workspacePath, default: 0] > 1,
                  let folderName = item.path?.lastPathComponent
            else { return item }
            var named = item
            named.subtitle += " — \(folderName)"
            return named
        }
    }

    /// DerivedData's folders, split into per-project build folders and everything else: caches Xcode
    /// shares across projects, such as `ModuleCache.noindex`, and, in a custom folder, folders that
    /// may not be Xcode's at all.
    ///
    /// A project folder is named `<Project>-<28 lowercase letters>`, or has an `info.plist`; in a
    /// custom folder that plist must be Xcode's, recording a `WorkspacePath`. In the default folder
    /// anything else is a shared cache: Xcode adds new ones without notice, so they aren't listed by name.
    ///
    /// `failure` says why the folder couldn't be read; a missing folder is simply empty.
    func derivedDataFolders() -> (projects: [URL], sharedCaches: [URL], failure: String?) {
        let derivedDataURL = xcodeLocations.derivedDataURL
        let isCustom = xcodeLocations.hasCustomDerivedData
        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try Self.folderEntries(of: derivedDataURL) ?? []
        } catch {
            return ([], [], error.localizedDescription)
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
        return (projects, sharedCaches, nil)
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
        let assessment = assessDerivedData(
            workspacePath: workspacePath,
            presence: presence,
            lastAccessed: lastAccessed,
            now: now,
            fileManager: fileManager
        )

        let displayName = projectDisplayName(folderName: folderName, workspacePath: workspacePath)
        let subtitle = workspaceSubtitle(workspacePath: workspacePath, status: assessment.status, folderName: folderName)

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
            status: assessment.status,
            statusExplanation: assessment.explanation,
            deletionMethod: .trashFile(folderURL),
            metadata: metadata
        )
    }

    private static func assessDerivedData(
        workspacePath: String?,
        presence: WorkspacePresence,
        lastAccessed: Date?,
        now: Date,
        fileManager: FileManager
    ) -> (status: ItemStatus, explanation: String) {
        guard let workspacePath, !workspacePath.isEmpty else {
            return (.orphaned, "This folder has no readable record of its project, so nothing is known to use it.")
        }
        guard presence != .missing else {
            return (.orphaned, "Its project is no longer at \(abbreviatingHome(in: workspacePath)).")
        }

        if isWorktreePath(workspacePath, fileManager: fileManager) {
            return (.worktree, "Its project path looks like a git worktree, which counts as in use whatever its age.")
        }

        return StorageCategory.derivedData.ageAssessment(lastUsed: lastAccessed, now: now)
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
        let shortened = abbreviatingHome(in: workspacePath)
        if status == .orphaned {
            return "Missing: \(shortened)"
        }
        return shortened
    }

    private static func abbreviatingHome(in path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
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
