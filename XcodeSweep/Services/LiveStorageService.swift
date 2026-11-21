import Foundation

/// Live coordinator that scans all Xcode storage locations concurrently and executes safe deletions.
struct LiveStorageService: StorageScanning, StorageDeleting, Sendable {
    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    private let commandRunner: any CommandRunning
    private let derivedDataScanner: DerivedDataScanner
    private let simulatorScanner: SimulatorScanner
    private let extrasScanner: XcodeExtrasScanner

    init(
        commandRunner: any CommandRunning = ProcessRunner(),
        derivedDataScanner: DerivedDataScanner = DerivedDataScanner(),
        simulatorScanner: SimulatorScanner? = nil,
        extrasScanner: XcodeExtrasScanner = XcodeExtrasScanner()
    ) {
        self.commandRunner = commandRunner
        self.derivedDataScanner = derivedDataScanner
        self.simulatorScanner = simulatorScanner ?? SimulatorScanner(commandRunner: commandRunner)
        self.extrasScanner = extrasScanner
    }

    // MARK: - StorageScanning

    func scanAll(
        onProgress: @escaping @Sendable (StorageCategory, [StorageItem]) -> Void
    ) async throws -> ScanSnapshot {
        let capacity = Self.readVolumeCapacity()

        return await withTaskGroup(
            of: (StorageCategory, [StorageItem], String?).self,
            returning: ScanSnapshot.self
        ) { group in
            group.addTask {
                let items = await derivedDataScanner.scan()
                return (.derivedData, items, nil)
            }

            group.addTask {
                do {
                    let items = try await simulatorScanner.scanDevices()
                    return (.simulatorDevices, items, nil)
                } catch {
                    return (.simulatorDevices, [], "Simulator Devices: \(error.localizedDescription)")
                }
            }

            group.addTask {
                do {
                    let items = try await simulatorScanner.scanRuntimes()
                    return (.simulatorRuntimes, items, nil)
                } catch {
                    return (.simulatorRuntimes, [], "Simulator Runtimes: \(error.localizedDescription)")
                }
            }

            group.addTask {
                let items = await extrasScanner.scanDeviceSupport()
                return (.deviceSupport, items, nil)
            }

            group.addTask {
                let items = await extrasScanner.scanPreviews()
                return (.previews, items, nil)
            }

            group.addTask {
                let items = await extrasScanner.scanArchivesAndCaches()
                return (.archivesAndCaches, items, nil)
            }

            var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
            var warnings: [String] = []

            for await (category, items, warning) in group {
                itemsByCategory[category] = items
                if let warning {
                    warnings.append(warning)
                }
                onProgress(category, items)
            }

            return ScanSnapshot(
                itemsByCategory: itemsByCategory,
                diskAvailableBytes: capacity.available,
                diskTotalBytes: capacity.total,
                warnings: warnings
            )
        }
    }

    // MARK: - StorageDeleting

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
                    try await Task.detached(priority: .userInitiated) {
                        var resultingURL: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                    }.value
                    deletedCount += 1
                    trashedCount += 1
                    reclaimedBytes += item.sizeBytes
                    removedItemIDs.insert(item.id)
                    removedID = item.id

                case let .simctlDevice(udid, isBooted):
                    if isBooted {
                        _ = try? await commandRunner.run(
                            executableURL: Self.xcrunURL,
                            arguments: ["simctl", "shutdown", udid]
                        )
                    }
                    _ = try await commandRunner.run(
                        executableURL: Self.xcrunURL,
                        arguments: ["simctl", "delete", udid]
                    )
                    deletedCount += 1
                    simctlDeletedCount += 1
                    reclaimedBytes += item.sizeBytes
                    removedItemIDs.insert(item.id)
                    removedID = item.id

                case let .simctlRuntime(identifier):
                    _ = try await commandRunner.run(
                        executableURL: Self.xcrunURL,
                        arguments: ["simctl", "runtime", "delete", identifier]
                    )
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

    // MARK: - Disk Capacity

    private static func readVolumeCapacity() -> (available: Int64?, total: Int64?) {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let values = try? homeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
        let total = values?.volumeTotalCapacity.map(Int64.init)
        return (available, total)
    }
}
