import Foundation

extension XcodeStorage {
    // MARK: - Device Support

    func scanDeviceSupport(now: Date) async -> [StorageItem] {
        let folderNames = [
            ("iOS DeviceSupport", "iOS"),
            ("watchOS DeviceSupport", "watchOS"),
            ("tvOS DeviceSupport", "tvOS"),
            ("visionOS DeviceSupport", "visionOS"),
        ]

        let fileManager = FileManager.default
        var candidates: [(url: URL, platformLabel: String)] = []

        for (folderName, platformLabel) in folderNames {
            let root = xcodeRootURL.appendingPathComponent(folderName, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries {
                candidates.append((entry, platformLabel))
            }
        }

        return await Self.scanConcurrently(candidates, limiter: folderWalkLimiter) { candidate in
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
    }

    // MARK: - SwiftUI Previews

    func scanPreviews(now: Date) async -> [StorageItem] {
        let previewsDevicesURL = xcodeRootURL
            .appendingPathComponent("UserData/Previews/Simulator Devices", isDirectory: true)

        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: previewsDevicesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }

        return await Self.scanConcurrently(directories, limiter: folderWalkLimiter) { url in
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
                deletionMethod: .trashFile(url),
                metadata: metadata
            )
        }
    }

    // MARK: - Archives & Caches

    func scanArchivesAndCaches(sharedCaches: [URL]) async throws(CancellationError) -> [StorageItem] {
        var items: [StorageItem] = []
        let fileManager = FileManager.default

        // 1. Caches Xcode shares across projects in DerivedData
        let lane = folderWalkLimiter.makeLane()
        for cacheURL in sharedCaches {
            try await items.append(folderWalkLimiter.withPermit(in: lane) { () throws(CancellationError) in
                try Self.inspectSharedCache(at: cacheURL)
            })
        }

        // 2. Archives/YYYY-MM-DD/*.xcarchive
        let archivesURL = xcodeRootURL.appendingPathComponent("Archives", isDirectory: true)
        if let dateFolders = try? fileManager.contentsOfDirectory(
            at: archivesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var archiveURLs: [URL] = []
            for dateFolder in dateFolders {
                guard let archives = try? fileManager.contentsOfDirectory(
                    at: dateFolder,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for archive in archives where archive.pathExtension == "xcarchive" {
                    archiveURLs.append(archive)
                }
            }

            let archiveItems = await Self.scanConcurrently(archiveURLs, limiter: folderWalkLimiter) { archiveURL in
                try Self.inspectArchive(at: archiveURL)
            }
            items.append(contentsOf: archiveItems)
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Private Inspection

    /// The module cache keeps its long-standing Unused status. Other folders aren't recommended:
    /// most are build caches, and clearing one can slow the builds that use it.
    private static func inspectSharedCache(at url: URL) throws(CancellationError) -> StorageItem {
        let isModuleCache = url.lastPathComponent == moduleCacheFolderName
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
