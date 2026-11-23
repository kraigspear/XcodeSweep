import Foundation

/// Snapshot emitted at the end of a completed scan across all storage categories.
struct ScanSnapshot: Equatable, Sendable {
    let scannedAt: Date
    let itemsByCategory: [StorageCategory: [StorageItem]]
    /// The volume holding the Xcode folder; `nil` if it couldn't be read.
    let volume: DiskVolume?
    let warnings: [String]
}

/// A volume's display name and capacity.
struct DiskVolume: Equatable, Sendable {
    let name: String
    let availableBytes: Int64
    let totalBytes: Int64
}

/// Ordered lifecycle events emitted by `XcodeStorage.scan()`.
enum ScanEvent: Equatable, Sendable {
    case categoryScanned(StorageCategory, [StorageItem])
    case completed(ScanSnapshot)
}

/// Ordered lifecycle events emitted by `XcodeStorage.delete(_:)`.
enum DeletionEvent: Equatable, Sendable {
    case starting(DeletionProgress)
    case deleted(itemID: StorageItem.ID, progress: DeletionProgress)
    case failed(DeletionFailure, progress: DeletionProgress)
    case completed(DeletionReport)
}

/// Inspects and cleans local Xcode and CoreSimulator storage.
struct XcodeStorage: Sendable {
    static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// The Xcode data folder, `~/Library/Developer/Xcode` by default.
    let xcodeRootURL: URL
    let commandRunner: any CommandRunning
    let fileTrasher: any FileTrashing
    /// The clock that stamps scans and ages items.
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

    /// Scans all storage categories concurrently, streaming each category's results, then a snapshot.
    ///
    /// The `.completed(ScanSnapshot)` event is stamped with `now()`. When cancellation is observed
    /// during `next()`, child scan tasks are cancelled, full producer teardown is awaited, and
    /// `CancellationError` is thrown. Breaking out of iteration early requests producer
    /// cancellation on iterator release without awaiting teardown or throwing.
    func scan() -> some AsyncSequence<ScanEvent, any Error> & Sendable {
        StructuredScanStream(storage: self)
    }

    // MARK: - Deletion

    /// Deletes the plan's deletable items one at a time, streaming each outcome and then a report.
    ///
    /// Protected items are never deleted. Each item is deleted only when the next event is requested.
    ///
    /// Cancellation is cooperative: once observed, no subsequent items are started and `CancellationError`
    /// is never recorded as a `DeletionFailure`; an in-flight `FileTrashing` move that cannot be interrupted
    /// may complete and emit its outcome before cancellation is thrown on the next pull.
    func delete(_ plan: DeletionPlan) -> some AsyncSequence<DeletionEvent, any Error> & Sendable {
        DeletionStream(storage: self, items: plan.deletableItems)
    }

    /// `item` must come from `DeletionPlan.deletableItems`; a protected item traps.
    fileprivate func remove(_ item: StorageItem) async throws {
        switch item.deletionMethod {
        case let .trashFile(url):
            try await fileTrasher.trashItem(at: url)
        case let .simctlDevice(udid):
            try await deleteSimulatorDevice(udid: udid)
        case let .simctlRuntime(identifier):
            try await deleteSimulatorRuntime(identifier: identifier)
        case .notDeletable:
            preconditionFailure("DeletionPlan excludes protected items")
        }
    }

    // MARK: - Shared Internal Helpers

    /// Inspects `inputs` concurrently, returning the items found sorted largest first.
    ///
    /// A child already cancelled when it starts skips its input, and an input whose `inspect` throws
    /// contributes no item; the inspections here throw only on cancellation.
    static func scanConcurrently<Input: Sendable>(
        _ inputs: [Input],
        inspect: @escaping @Sendable (Input) throws -> StorageItem?
    ) async -> [StorageItem] {
        await withTaskGroup(of: StorageItem?.self, returning: [StorageItem].self) { group in
            for input in inputs {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return try? inspect(input)
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

    /// The dictionary in the property list at `url`; `nil` if unreadable or not a dictionary.
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

    fileprivate func readVolume() -> DiskVolume? {
        let targetURL = nearestExistingDirectory(from: xcodeRootURL)
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? targetURL.resourceValues(forKeys: [
            .volumeLocalizedNameKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
            let name = values.volumeLocalizedName,
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else {
            return nil
        }
        return DiskVolume(name: name, availableBytes: available, totalBytes: Int64(total))
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

// MARK: - Deletion Logging

private extension DeletionMethod {
    var logName: String {
        switch self {
        case .trashFile: "trash"
        case .simctlDevice: "simctlDevice"
        case .simctlRuntime: "simctlRuntime"
        case .notDeletable: "none"
        }
    }

    /// The path, device UDID, or runtime identifier being removed.
    var logTarget: String {
        switch self {
        case let .trashFile(url): url.path
        case let .simctlDevice(udid): udid
        case let .simctlRuntime(identifier): identifier
        case .notDeletable: ""
        }
    }
}

// MARK: - Private Structured Scan Stream

private final class ScanProducerHandle: Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }

    func waitForExit() async {
        await task.value
    }

    deinit {
        task.cancel()
    }
}

/// The `scan()` sequence: a detached producer task feeds the iterator, and iterator cancellation
/// waits for that task to finish.
private struct StructuredScanStream: AsyncSequence, Sendable {
    typealias Element = ScanEvent

    let storage: XcodeStorage

    struct AsyncIterator: AsyncIteratorProtocol {
        private var base: AsyncThrowingStream<ScanEvent, any Error>.AsyncIterator
        private let producer: ScanProducerHandle
        private var deliveredCompletion = false

        init(storage: XcodeStorage) {
            let (stream, continuation) = AsyncThrowingStream<ScanEvent, any Error>.makeStream()
            let task = Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                let volume = storage.readVolume()
                let referenceDate = storage.now()
                // Classified once, so a folder Xcode is creating mid-scan lands in exactly one category.
                let derivedData = storage.derivedDataFolders()

                let snapshot = await withTaskGroup(
                    of: (StorageCategory, [StorageItem], String?)?.self,
                    returning: ScanSnapshot.self
                ) { group in
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let items = await storage.scanDerivedData(derivedData.projects, now: referenceDate)
                        guard !Task.isCancelled else { return nil }
                        return (.derivedData, items, nil)
                    }

                    group.addTask {
                        do {
                            let items = try await storage.scanSimulatorDevices(now: referenceDate)
                            return (.simulatorDevices, items, nil)
                        } catch is CancellationError {
                            return nil
                        } catch {
                            return (.simulatorDevices, [], "Simulator Devices: \(error.localizedDescription)")
                        }
                    }

                    group.addTask {
                        do {
                            let items = try await storage.scanSimulatorRuntimes(now: referenceDate)
                            return (.simulatorRuntimes, items, nil)
                        } catch is CancellationError {
                            return nil
                        } catch {
                            return (.simulatorRuntimes, [], "Simulator Runtimes: \(error.localizedDescription)")
                        }
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let items = await storage.scanDeviceSupport(now: referenceDate)
                        guard !Task.isCancelled else { return nil }
                        return (.deviceSupport, items, nil)
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let items = await storage.scanPreviews(now: referenceDate)
                        guard !Task.isCancelled else { return nil }
                        return (.previews, items, nil)
                    }

                    group.addTask {
                        guard !Task.isCancelled,
                              let items = try? await storage.scanArchivesAndCaches(sharedCaches: derivedData.sharedCaches),
                              !Task.isCancelled
                        else { return nil }
                        return (.archivesAndCaches, items, nil)
                    }

                    var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
                    var warnings: [String] = []

                    for await case let (category, items, warning)? in group {
                        if Task.isCancelled {
                            continue
                        }
                        itemsByCategory[category] = items
                        if let warning {
                            warnings.append(warning)
                        }
                        continuation.yield(.categoryScanned(category, items))
                    }

                    return ScanSnapshot(
                        scannedAt: referenceDate,
                        itemsByCategory: itemsByCategory,
                        volume: volume,
                        warnings: warnings
                    )
                }

                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.yield(.completed(snapshot))
                    continuation.finish()
                }
            }

            let producer = ScanProducerHandle(task: task)
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }

            base = stream.makeAsyncIterator()
            self.producer = producer
        }

        mutating func next() async throws -> ScanEvent? {
            if deliveredCompletion {
                await producer.waitForExit()
                return nil
            }

            if Task.isCancelled {
                producer.cancel()
                await producer.waitForExit()
                throw CancellationError()
            }

            let producer = self.producer
            do {
                let event = try await withTaskCancellationHandler {
                    try await base.next()
                } onCancel: {
                    producer.cancel()
                }

                if Task.isCancelled {
                    producer.cancel()
                    await producer.waitForExit()
                    throw CancellationError()
                }

                if case .completed = event {
                    deliveredCompletion = true
                }
                if event == nil {
                    await producer.waitForExit()
                }
                return event
            } catch is CancellationError {
                producer.cancel()
                await producer.waitForExit()
                throw CancellationError()
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage)
    }
}

// MARK: - Private Pull-Based Deletion Stream

/// The `delete(_:)` sequence: each `next()` call deletes at most one item.
private struct DeletionStream: AsyncSequence, Sendable {
    typealias Element = DeletionEvent

    let storage: XcodeStorage
    let items: [StorageItem]

    struct AsyncIterator: AsyncIteratorProtocol {
        private enum Phase {
            case beforeItem(Int)
            case executeItem(Int)
            case finish
            case done
        }

        /// Targets and reasons are public: the log is the user's record of what left their own
        /// developer folders, and redacted entries couldn't serve as one. Nothing logs below notice,
        /// the lowest level the system keeps on disk by default.
        private static let logger = LogContext.deletion.logger

        private let storage: XcodeStorage
        private let items: [StorageItem]
        private var phase: Phase
        private var removed: [StorageItem] = []
        private var reclaimedBytes: Int64 = 0
        private var failures: [DeletionFailure] = []

        init(storage: XcodeStorage, items: [StorageItem]) {
            self.storage = storage
            self.items = items
            phase = items.isEmpty ? .finish : .beforeItem(0)
        }

        private func progress(completing index: Int) -> DeletionProgress {
            DeletionProgress(
                completedCount: index + 1,
                totalCount: items.count,
                currentItemName: items[index].name,
                removedBytes: reclaimedBytes
            )
        }

        mutating func next() async throws -> DeletionEvent? {
            if Task.isCancelled {
                phase = .done
                throw CancellationError()
            }

            switch phase {
            case .done:
                return nil

            case let .beforeItem(index):
                phase = .executeItem(index)
                let item = items[index]
                let progress = DeletionProgress(
                    completedCount: index,
                    totalCount: items.count,
                    currentItemName: item.name,
                    removedBytes: reclaimedBytes
                )
                return .starting(progress)

            case let .executeItem(index):
                let item = items[index]
                phase = index + 1 < items.count ? .beforeItem(index + 1) : .finish

                do {
                    try await storage.remove(item)
                    Self.logger.notice("""
                    outcome=removed method=\(item.deletionMethod.logName, privacy: .public) \
                    bytes=\(item.sizeBytes, privacy: .public) target=\(item.deletionMethod.logTarget, privacy: .public)
                    """)
                    removed.append(item)
                    reclaimedBytes += item.sizeBytes
                    return .deleted(itemID: item.id, progress: progress(completing: index))
                } catch is CancellationError {
                    // A stopped trash move or simctl command may still have taken effect.
                    Self.logger.notice("""
                    outcome=unknown method=\(item.deletionMethod.logName, privacy: .public) \
                    target=\(item.deletionMethod.logTarget, privacy: .public)
                    """)
                    phase = .done
                    throw CancellationError()
                } catch {
                    Self.logger.error("""
                    outcome=failed method=\(item.deletionMethod.logName, privacy: .public) \
                    target=\(item.deletionMethod.logTarget, privacy: .public) \
                    reason=\(error.localizedDescription, privacy: .public)
                    """)
                    let failure = DeletionFailure(
                        itemID: item.id,
                        itemName: item.name,
                        reason: error.localizedDescription
                    )
                    failures.append(failure)
                    return .failed(failure, progress: progress(completing: index))
                }

            case .finish:
                phase = .done
                return .completed(DeletionReport(removed: removed, failures: failures))
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: storage, items: items)
    }
}
