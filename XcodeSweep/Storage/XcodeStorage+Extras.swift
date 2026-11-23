import Foundation

extension XcodeStorage {
    // MARK: - Device Support

    /// `failure` names each DeviceSupport folder that couldn't be read.
    func scanDeviceSupport(now: Date) async -> (items: [StorageItem], failure: String?) {
        let folderNames = [
            ("iOS DeviceSupport", "iOS"),
            ("watchOS DeviceSupport", "watchOS"),
            ("tvOS DeviceSupport", "tvOS"),
            ("visionOS DeviceSupport", "visionOS"),
        ]

        var candidates: [(url: URL, platformLabel: String)] = []
        var failures: [String] = []

        for (folderName, platformLabel) in folderNames {
            let root = xcodeRootURL.appendingPathComponent(folderName, isDirectory: true)
            do {
                for entry in try Self.folderEntries(of: root) {
                    candidates.append((entry, platformLabel))
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        let items = await Self.scanConcurrently(candidates, limiter: folderWalkLimiter) { candidate in
            let size = try DirectorySizer.allocatedSize(of: candidate.url)
            let modified = Self.modificationDate(of: candidate.url)
            let status = StorageCategory.deviceSupport.ageStatus(lastUsed: modified, now: now)

            return StorageItem(
                id: "deviceSupport:\(candidate.url.path)",
                category: .deviceSupport,
                name: candidate.url.lastPathComponent,
                subtitle: "\(candidate.platformLabel) DeviceSupport symbols",
                sizeBytes: size,
                lastUsedDate: modified,
                path: candidate.url,
                workspacePath: nil,
                status: status,
                deletionMethod: .trashFile(candidate.url),
                metadata: [
                    MetadataEntry(key: "Platform", value: candidate.platformLabel),
                    MetadataEntry(key: "Path", value: candidate.url.path),
                ]
            )
        }
        return (items, failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    // MARK: - SwiftUI Previews

    /// Preview devices `simctl` has registered, for deletion through it, and leftover folders it
    /// doesn't know, for Trash.
    ///
    /// When `simctl` can't list the set, every folder is protected: any of them may be registered,
    /// and trashing one behind CoreSimulator's back leaves its set pointing at a missing device.
    /// Without the set's folder there is nothing to list, and `simctl` would fail on the missing path.
    func scanPreviews(now: Date) async -> (items: [StorageItem], failure: String?) {
        let previewsDevicesURL = xcodeRootURL
            .appendingPathComponent("UserData/Previews/Simulator Devices", isDirectory: true)

        guard FileManager.default.fileExists(atPath: previewsDevicesURL.path) else { return ([], nil) }
        var failures: [String] = []
        let entries: [URL]
        do {
            entries = try Self.folderEntries(of: previewsDevicesURL)
        } catch {
            entries = []
            failures.append(error.localizedDescription)
        }
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }

        let registered: [StorageItem]?
        do {
            registered = try await listSimulatorDevices(in: .previews, now: now)
        } catch {
            registered = nil
            if !(error is CancellationError) {
                failures.append(error.localizedDescription)
            }
        }

        // Matched by file identity: a folder may spell its UDID in another case than simctl, and on a
        // case-sensitive volume two such spellings are distinct folders.
        var registeredFolders: Set<FileIdentity> = []
        var unlocatedUDIDs: Set<String> = []
        for item in registered ?? [] {
            if let folder = item.path, let identity = FileIdentity(of: folder) {
                registeredFolders.insert(identity)
            } else if case let .simctlDevice(udid, _) = item.deletionMethod {
                unlocatedUDIDs.insert(udid.uppercased())
            }
        }
        // A folder that can't be identified vanished or can't be reached, so it isn't offered at all.
        let leftovers = directories.filter { url in
            FileIdentity(of: url).map { !registeredFolders.contains($0) } ?? false
        }
        let protectedUDIDs = unlocatedUDIDs

        let leftoverItems = await Self.scanConcurrently(leftovers, limiter: folderWalkLimiter) { url in
            // Without simctl's list, or its path for a device of this name, the folder may be registered.
            let canTrash = registered != nil && !protectedUDIDs.contains(url.lastPathComponent.uppercased())
            let size = try DirectorySizer.allocatedSize(of: url)
            let modified = Self.modificationDate(of: url)
            let plist = Self.loadPlist(at: url.appendingPathComponent("device.plist"))

            let name = (plist?["name"] as? String) ?? url.lastPathComponent
            let runtimeLabel = (plist?["runtime"] as? String).map(Self.readableRuntimeName(from:))
            let subtitle = runtimeLabel.map { "\($0) • \(url.lastPathComponent)" } ?? url.lastPathComponent
            let status = StorageCategory.previews.ageStatus(lastUsed: modified, now: now)

            var metadata: [MetadataEntry] = [
                MetadataEntry(key: "UDID", value: url.lastPathComponent),
                MetadataEntry(key: "Path", value: url.path),
            ]
            if let runtimeLabel {
                metadata.append(MetadataEntry(key: "Runtime", value: runtimeLabel))
            }

            return StorageItem(
                id: "preview:\(url.path)",
                category: .previews,
                name: name,
                subtitle: subtitle,
                sizeBytes: size,
                lastUsedDate: modified,
                path: url,
                workspacePath: nil,
                status: status,
                deletionMethod: canTrash
                    ? .trashFile(url)
                    : .notDeletable(reason: "simctl couldn't confirm this folder isn't a registered preview device"),
                metadata: metadata
            )
        }

        let items = ((registered ?? []) + leftoverItems).sorted { $0.sizeBytes > $1.sizeBytes }
        return (items, failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    // MARK: - Archives & Caches

    /// `failure` names each archives folder that couldn't be read.
    func scanArchivesAndCaches(
        sharedCaches: [URL]
    ) async throws(CancellationError) -> (items: [StorageItem], failure: String?) {
        var items: [StorageItem] = []
        var failures: [String] = []

        // 1. Caches Xcode shares across projects in DerivedData
        let lane = folderWalkLimiter.makeLane()
        let isCustom = xcodeLocations.hasCustomDerivedData
        for cacheURL in sharedCaches {
            try await items.append(folderWalkLimiter.withPermit(in: lane) { () throws(CancellationError) in
                try Self.inspectSharedCache(at: cacheURL, inCustomFolder: isCustom)
            })
        }

        // 2. Archives/YYYY-MM-DD/*.xcarchive
        let archivesURL = xcodeLocations.archivesURL
        var archiveURLs: [URL] = []
        do {
            for dateFolder in try Self.folderEntries(of: archivesURL)
                where (try? dateFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            {
                do {
                    for archive in try Self.folderEntries(of: dateFolder) where archive.pathExtension == "xcarchive" {
                        archiveURLs.append(archive)
                    }
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        let archiveItems = await Self.scanConcurrently(archiveURLs, limiter: folderWalkLimiter) { archiveURL in
            try Self.inspectArchive(at: archiveURL)
        }
        items.append(contentsOf: archiveItems)

        return (items.sorted { $0.sizeBytes > $1.sizeBytes }, failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    // MARK: - Private Inspection

    /// Caches Xcode is known to create in DerivedData; in a custom folder, only these may be removed.
    private static let knownSharedCacheNames: Set<String> = [moduleCacheFolderName, "SDKExplicitPrecompiledModules"]

    /// The module cache keeps its long-standing Unused status. Other folders aren't recommended:
    /// most are build caches, and clearing one can slow the builds that use it. In a custom
    /// DerivedData folder an unknown one may not be Xcode's at all, so it is protected, and left
    /// unmeasured so it can't count as Xcode storage.
    private static func inspectSharedCache(at url: URL, inCustomFolder: Bool) throws(CancellationError) -> StorageItem {
        let isModuleCache = url.lastPathComponent == moduleCacheFolderName
        let isTrusted = !inCustomFolder || knownSharedCacheNames.contains(url.lastPathComponent)
        guard isTrusted else {
            return StorageItem(
                id: "unrecognized:\(url.path)",
                category: .archivesAndCaches,
                name: url.lastPathComponent,
                subtitle: "Not recognized as Xcode's; left alone and not counted",
                sizeBytes: 0,
                lastUsedDate: modificationDate(of: url),
                path: url,
                workspacePath: nil,
                status: .active,
                deletionMethod: .notDeletable(reason: "Not recognized as Xcode's, in a custom DerivedData folder that may hold other files"),
                metadata: [
                    MetadataEntry(key: "Type", value: "Unrecognized Folder"),
                    MetadataEntry(key: "Path", value: url.path),
                ]
            )
        }
        return try StorageItem(
            id: isModuleCache ? "cache:moduleCache" : "sharedCache:\(url.lastPathComponent)",
            category: .archivesAndCaches,
            name: url.lastPathComponent,
            subtitle: isModuleCache
                ? "Shared Swift/Clang module cache (safely regenerated on next build)"
                : "Shared DerivedData folder, not tied to one project",
            sizeBytes: DirectorySizer.allocatedSize(of: url),
            lastUsedDate: modificationDate(of: url),
            path: url,
            workspacePath: nil,
            status: isModuleCache ? .stale : .active,
            deletionMethod: .trashFile(url),
            metadata: [
                MetadataEntry(key: "Type", value: isModuleCache ? "Xcode Build Cache" : "DerivedData Folder"),
                MetadataEntry(key: "Path", value: url.path),
            ]
        )
    }

    private static func inspectArchive(at url: URL) throws(CancellationError) -> StorageItem {
        let size = try DirectorySizer.allocatedSize(of: url)
        var displayName = url.deletingPathExtension().lastPathComponent
        var versionSubtitle = "Xcode Archive"
        var creationDate = modificationDate(of: url)
        var metadata: [MetadataEntry] = [
            MetadataEntry(key: "Path", value: url.path),
        ]

        if let plist = loadPlist(at: url.appendingPathComponent("Info.plist")) {
            if let name = plist["Name"] as? String, !name.isEmpty {
                displayName = name
            }
            if let created = plist["CreationDate"] as? Date {
                creationDate = created
            }
            if let appProps = plist["ApplicationProperties"] as? [String: Any] {
                let shortVersion = appProps["CFBundleShortVersionString"] as? String
                let buildVersion = appProps["CFBundleVersion"] as? String
                if let shortVersion {
                    versionSubtitle = buildVersion.map { "v\(shortVersion) (\($0))" } ?? "v\(shortVersion)"
                }
                if let bundleID = appProps["CFBundleIdentifier"] as? String {
                    metadata.append(MetadataEntry(key: "Bundle ID", value: bundleID))
                }
            }
        }

        return StorageItem(
            id: "archive:\(url.path)",
            category: .archivesAndCaches,
            name: displayName,
            subtitle: versionSubtitle,
            sizeBytes: size,
            lastUsedDate: creationDate,
            path: url,
            workspacePath: nil,
            status: .active,
            deletionMethod: .trashFile(url),
            metadata: metadata
        )
    }
}

/// A file's volume and inode, equal for every path that reaches it.
private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init?(of url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }

    static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(inode)
    }
}
