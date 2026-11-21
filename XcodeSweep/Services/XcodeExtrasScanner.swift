import Foundation

/// Scans DeviceSupport folders, SwiftUI Preview simulators, Xcode Archives, and DerivedData ModuleCache.
struct XcodeExtrasScanner: Sendable {
    private let xcodeRootURL: URL
    private let staleThresholdDays: Int

    init(
        xcodeRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode", isDirectory: true),
        staleThresholdDays: Int = 45
    ) {
        self.xcodeRootURL = xcodeRootURL
        self.staleThresholdDays = staleThresholdDays
    }

    // MARK: - Device Support

    func scanDeviceSupport() async -> [StorageItem] {
        let folderNames = [
            ("iOS DeviceSupport", "iOS"),
            ("watchOS DeviceSupport", "watchOS"),
            ("tvOS DeviceSupport", "tvOS"),
            ("visionOS DeviceSupport", "visionOS"),
        ]

        let fileManager = FileManager.default
        var candidateURLs: [(URL, String)] = []

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
                candidateURLs.append((entry, platformLabel))
            }
        }

        let now = Date()
        let threshold = TimeInterval(staleThresholdDays) * 86_400

        return await withTaskGroup(of: StorageItem.self, returning: [StorageItem].self) { group in
            for (url, platformLabel) in candidateURLs {
                group.addTask {
                    let size = DirectorySizer.allocatedSize(of: url)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    let status: ItemStatus = if let modified, now.timeIntervalSince(modified) > threshold {
                        .stale
                    } else {
                        .active
                    }

                    return StorageItem(
                        id: "deviceSupport:\(url.path)",
                        category: .deviceSupport,
                        name: url.lastPathComponent,
                        subtitle: "\(platformLabel) DeviceSupport symbols",
                        sizeBytes: size,
                        lastUsedDate: modified,
                        path: url,
                        workspacePath: nil,
                        status: status,
                        deletionMethod: .trashFile(url),
                        metadata: [
                            MetadataEntry(key: "Platform", value: platformLabel),
                            MetadataEntry(key: "Path", value: url.path),
                        ]
                    )
                }
            }

            var items: [StorageItem] = []
            for await item in group {
                items.append(item)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    // MARK: - SwiftUI Previews

    func scanPreviews() async -> [StorageItem] {
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

        let now = Date()
        let threshold = TimeInterval(staleThresholdDays) * 86_400

        return await withTaskGroup(of: StorageItem.self, returning: [StorageItem].self) { group in
            for url in directories {
                group.addTask {
                    let size = DirectorySizer.allocatedSize(of: url)
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    let previewInfo = Self.parsePreviewDevicePlist(at: url.appendingPathComponent("device.plist"))

                    let name = previewInfo?.name ?? url.lastPathComponent
                    let runtimeLabel = previewInfo?.runtime.map(SimulatorScanner.readableRuntimeName(from:))
                    let subtitle = runtimeLabel.map { "\($0) • \(url.lastPathComponent)" } ?? url.lastPathComponent

                    let status: ItemStatus = if let modified, now.timeIntervalSince(modified) > threshold {
                        .stale
                    } else {
                        .active
                    }

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

            var items: [StorageItem] = []
            for await item in group {
                items.append(item)
            }
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    // MARK: - Archives & Caches

    func scanArchivesAndCaches() async -> [StorageItem] {
        var items: [StorageItem] = []
        let fileManager = FileManager.default

        // 1. DerivedData/ModuleCache.noindex
        let moduleCacheURL = xcodeRootURL
            .appendingPathComponent("DerivedData/ModuleCache.noindex", isDirectory: true)
        if fileManager.fileExists(atPath: moduleCacheURL.path) {
            let size = DirectorySizer.allocatedSize(of: moduleCacheURL)
            let modified = (try? moduleCacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            items.append(
                StorageItem(
                    id: "cache:moduleCache",
                    category: .archivesAndCaches,
                    name: "ModuleCache.noindex",
                    subtitle: "Shared Swift/Clang module cache (safely regenerated on next build)",
                    sizeBytes: size,
                    lastUsedDate: modified,
                    path: moduleCacheURL,
                    workspacePath: nil,
                    status: .stale,
                    deletionMethod: .trashFile(moduleCacheURL),
                    metadata: [
                        MetadataEntry(key: "Type", value: "Xcode Build Cache"),
                        MetadataEntry(key: "Path", value: moduleCacheURL.path),
                    ]
                )
            )
        }

        // 2. ~/Library/Developer/Xcode/Archives/YYYY-MM-DD/*.xcarchive
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

            let archiveItems = await withTaskGroup(of: StorageItem.self, returning: [StorageItem].self) { group in
                for archiveURL in archiveURLs {
                    group.addTask {
                        Self.inspectArchive(at: archiveURL)
                    }
                }
                var collected: [StorageItem] = []
                for await item in group {
                    collected.append(item)
                }
                return collected
            }
            items.append(contentsOf: archiveItems)
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Private Plist Helpers

    private static func inspectArchive(at url: URL) -> StorageItem {
        let size = DirectorySizer.allocatedSize(of: url)
        let infoURL = url.appendingPathComponent("Info.plist")
        var displayName = url.deletingPathExtension().lastPathComponent
        var versionSubtitle = "Xcode Archive"
        var creationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var metadata: [MetadataEntry] = [
            MetadataEntry(key: "Path", value: url.path),
        ]

        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
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

    private static func parsePreviewDevicePlist(at url: URL) -> (name: String?, runtime: String?)? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return (plist["name"] as? String, plist["runtime"] as? String)
    }
}
