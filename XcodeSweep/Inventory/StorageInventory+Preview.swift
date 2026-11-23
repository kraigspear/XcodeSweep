// periphery:ignore:all - used only by #Preview, which Periphery does not index
#if DEBUG && canImport(SwiftUI)
    import Foundation

    extension StorageInventory {
        /// Fixed sample scan covering every category and status, so previews don't depend on what's on this Mac.
        static let preview = StorageInventory(
            itemsByCategory: Dictionary(grouping: StorageItem.previewItems, by: \.category),
            scannedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            volume: DiskVolume(name: "Macintosh HD", availableBytes: 412_000_000_000, totalBytes: 994_000_000_000)
        )
    }

    extension StorageItem {
        static let previewItems: [StorageItem] = [
            previewItem(
                "dd-orphan", .derivedData, "SampleApp", "SampleApp-abcdefghijk",
                gigabytes: 4.2, daysAgo: 62, status: .orphaned,
                workspacePath: "/Users/me/Projects/SampleApp/SampleApp.xcodeproj"
            ),
            previewItem(
                "dd-worktree", .derivedData, "WeatherDemo", "WeatherDemo-lmnopqrstuv",
                gigabytes: 2.8, daysAgo: 3, status: .worktree,
                workspacePath: "/Users/me/Projects/WeatherDemo-feature/WeatherDemo.xcodeproj"
            ),
            previewItem(
                "dd-active", .derivedData, "NotesKit", "NotesKit-wxyzabcdefg",
                gigabytes: 1.1, daysAgo: 0, status: .active,
                workspacePath: "/Users/me/Projects/NotesKit/Package.swift"
            ),
            previewItem(
                "dd-stale", .derivedData, "OldPrototype", "OldPrototype-hijklmnopqr",
                gigabytes: 0.9, daysAgo: 120, status: .stale,
                workspacePath: "/Users/me/Projects/OldPrototype/OldPrototype.xcodeproj"
            ),
            previewItem(
                "sim-booted", .simulatorDevices, "iPhone 17 Pro", "iOS 27.0",
                gigabytes: 6.4, daysAgo: 0, status: .booted,
                method: .simctlDevice(udid: "PREVIEW-BOOTED")
            ),
            previewItem(
                "sim-unavailable", .simulatorDevices, "iPhone 15", "iOS 17.5",
                gigabytes: 3.7, daysAgo: 400, status: .unavailable,
                method: .simctlDevice(udid: "PREVIEW-UNAVAILABLE")
            ),
            previewItem(
                "rt-current", .simulatorRuntimes, "iOS 27.0", "Build 24A5300",
                gigabytes: 8.9, daysAgo: 0, status: .active,
                method: .simctlRuntime(identifier: "PREVIEW-RT-CURRENT")
            ),
            previewItem(
                "rt-stale", .simulatorRuntimes, "watchOS 11.0", "Build 22R349",
                gigabytes: 4.1, daysAgo: 210, status: .stale,
                method: .simctlRuntime(identifier: "PREVIEW-RT-STALE")
            ),
            previewItem(
                "rt-system", .simulatorRuntimes, "visionOS 27.0", "Build 24N100",
                gigabytes: 7.6, daysAgo: 30, status: .systemManaged,
                method: .notDeletable(reason: "Managed by Xcode")
            ),
            previewItem(
                "ds-old", .deviceSupport, "iPhone17,1 26.4", "iOS DeviceSupport",
                gigabytes: 5.3, daysAgo: 90, status: .stale
            ),
            previewItem(
                "pv-device", .previews, "iPhone 17 Preview", "Previews/Simulator Devices",
                gigabytes: 1.6, daysAgo: 12, status: .active
            ),
            previewItem(
                "ac-archive", .archivesAndCaches, "SampleApp 1.0", "Archives/2026-03-02",
                gigabytes: 0.4, daysAgo: 263, status: .stale
            ),
        ]

        private static func previewItem(
            _ id: String,
            _ category: StorageCategory,
            _ name: String,
            _ subtitle: String,
            gigabytes: Double,
            daysAgo: Int,
            status: ItemStatus,
            workspacePath: String? = nil,
            method: DeletionMethod? = nil
        ) -> StorageItem {
            let path = URL(filePath: "/Users/me/Library/Developer/Xcode/\(category.rawValue)/\(name)")
            return StorageItem(
                id: id,
                category: category,
                name: name,
                subtitle: subtitle,
                sizeBytes: Int64(gigabytes * 1_000_000_000),
                lastUsedDate: Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(daysAgo) * 86400),
                path: path,
                workspacePath: workspacePath,
                status: status,
                deletionMethod: method ?? .trashFile(path),
                metadata: [MetadataEntry(key: "Source", value: "Preview sample")]
            )
        }
    }
#endif
