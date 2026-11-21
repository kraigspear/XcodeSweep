import Foundation

/// Snapshot returned after scanning all Xcode and CoreSimulator storage categories.
struct ScanSnapshot: Equatable, Sendable {
    let itemsByCategory: [StorageCategory: [StorageItem]]
    let diskAvailableBytes: Int64?
    let diskTotalBytes: Int64?
    let warnings: [String]
}

/// Deep module owning local Xcode and CoreSimulator storage inspection and safe cleanup.
/// All external seams live strictly at the OS edges: root directory URL, command execution,
/// file trashing, and reference clock.
struct XcodeStorage: Sendable {
    static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    enum StalenessPolicy {
        static let derivedDataDays = 30
        static let simulatorDevicesDays = 30
        static let simulatorRuntimesDays = 45
        static let deviceSupportDays = 45
        static let previewsDays = 45

        static func threshold(days: Int) -> TimeInterval {
            TimeInterval(days) * 86400
        }
    }

    let xcodeRootURL: URL
    let commandRunner: any CommandRunning
    let fileTrasher: any FileTrashing
    let now: @Sendable () -> Date

    init(
        xcodeRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode", isDirectory: true),
        commandRunner: any CommandRunning = ProcessRunner(),
        fileTrasher: any FileTrashing = LiveFileTrasher(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.xcodeRootURL = xcodeRootURL
        self.commandRunner = commandRunner
        self.fileTrasher = fileTrasher
        self.now = now
    }

    // MARK: - Scanning

    func scanAll(
        onProgress: @escaping @Sendable (StorageCategory, [StorageItem]) async -> Void
    ) async throws -> ScanSnapshot {
        let capacity = readVolumeCapacity()
        let referenceDate = now()

        let snapshot = await withTaskGroup(
            of: (StorageCategory, [StorageItem], String?)?.self,
            returning: ScanSnapshot.self
        ) { group in
            group.addTask {
                let items = await scanDerivedData(now: referenceDate)
                return (.derivedData, items, nil)
            }

            group.addTask {
                do {
                    let items = try await scanSimulatorDevices(now: referenceDate)
                    return (.simulatorDevices, items, nil)
                } catch is CancellationError {
                    return nil
                } catch {
                    return (.simulatorDevices, [], "Simulator Devices: \(error.localizedDescription)")
                }
            }

            group.addTask {
                do {
                    let items = try await scanSimulatorRuntimes(now: referenceDate)
                    return (.simulatorRuntimes, items, nil)
                } catch is CancellationError {
                    return nil
                } catch {
                    return (.simulatorRuntimes, [], "Simulator Runtimes: \(error.localizedDescription)")
                }
            }

            group.addTask {
                let items = await scanDeviceSupport(now: referenceDate)
                return (.deviceSupport, items, nil)
            }

            group.addTask {
                let items = await scanPreviews(now: referenceDate)
                return (.previews, items, nil)
            }

            group.addTask {
                let items = await scanArchivesAndCaches()
                return (.archivesAndCaches, items, nil)
            }

            var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
            var warnings: [String] = []

            for await case let (category, items, warning)? in group {
                itemsByCategory[category] = items
                if let warning {
                    warnings.append(warning)
                }
                // Awaited, so no progress update can outlive the scan.
                await onProgress(category, items)
            }

            return ScanSnapshot(
                itemsByCategory: itemsByCategory,
                diskAvailableBytes: capacity.available,
                diskTotalBytes: capacity.total,
                warnings: warnings
            )
        }

        // A cancelled scan is incomplete; never hand it back as a finished result.
        try Task.checkCancellation()
        return snapshot
    }

    // MARK: - Deletion

    func delete(
        items: [StorageItem],
        onProgress: @escaping @Sendable (DeletionProgress) async -> Void
    ) async -> DeletionReport {
        var deletedCount = 0
        var trashedCount = 0
        var simctlDeletedCount = 0
        var reclaimedBytes: Int64 = 0
        var removedItemIDs: Set<StorageItem.ID> = []
        var failures: [DeletionFailure] = []

        let total = items.count
        for (index, item) in items.enumerated() {
            await onProgress(
                DeletionProgress(
                    completedCount: index,
                    totalCount: total,
                    currentItemName: item.name,
                    removedBytes: reclaimedBytes,
                    removedItemID: nil
                )
            )

            var removedID: StorageItem.ID?
            do {
                switch item.deletionMethod {
                case let .trashFile(url):
                    try await fileTrasher.trashItem(at: url)
                    deletedCount += 1
                    trashedCount += 1
                    reclaimedBytes += item.sizeBytes
                    removedItemIDs.insert(item.id)
                    removedID = item.id

                case let .simctlDevice(udid, isBooted):
                    try await deleteSimulatorDevice(udid: udid, isBooted: isBooted)
                    deletedCount += 1
                    simctlDeletedCount += 1
                    reclaimedBytes += item.sizeBytes
                    removedItemIDs.insert(item.id)
                    removedID = item.id

                case let .simctlRuntime(identifier):
                    try await deleteSimulatorRuntime(identifier: identifier)
                    deletedCount += 1
                    simctlDeletedCount += 1
                    reclaimedBytes += item.sizeBytes
                    removedItemIDs.insert(item.id)
                    removedID = item.id

                case let .notDeletable(reason):
                    failures.append(DeletionFailure(itemID: item.id, itemName: item.name, reason: reason))
                }
            } catch {
                failures.append(
                    DeletionFailure(
                        itemID: item.id,
                        itemName: item.name,
                        reason: error.localizedDescription
                    )
                )
            }

            await onProgress(
                DeletionProgress(
                    completedCount: index + 1,
                    totalCount: total,
                    currentItemName: item.name,
                    removedBytes: reclaimedBytes,
                    removedItemID: removedID
                )
            )
        }

        return DeletionReport(
            deletedCount: deletedCount,
            trashedCount: trashedCount,
            simctlDeletedCount: simctlDeletedCount,
            reclaimedBytes: reclaimedBytes,
            removedItemIDs: removedItemIDs,
            failures: failures
        )
    }

    // MARK: - Shared Internal Helpers

    static func scanConcurrently<Input: Sendable>(
        _ inputs: [Input],
        inspect: @escaping @Sendable (Input) -> StorageItem?
    ) async -> [StorageItem] {
        await withTaskGroup(of: StorageItem?.self, returning: [StorageItem].self) { group in
            for input in inputs {
                group.addTask {
                    inspect(input)
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

    static func loadPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func classifyByAge(lastUsed: Date?, now: Date, thresholdDays: Int) -> ItemStatus {
        let threshold = StalenessPolicy.threshold(days: thresholdDays)
        if let lastUsed, now.timeIntervalSince(lastUsed) > threshold {
            return .stale
        }
        return .active
    }

    private func readVolumeCapacity() -> (available: Int64?, total: Int64?) {
        let targetURL = nearestExistingDirectory(from: xcodeRootURL)
            ?? FileManager.default.homeDirectoryForCurrentUser
        let values = try? targetURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
        let total = values?.volumeTotalCapacity.map(Int64.init)
        return (available, total)
    }

    private func nearestExistingDirectory(from url: URL) -> URL? {
        let fileManager = FileManager.default
        var current = url
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
        return current
    }
}
