import Foundation

/// Snapshot emitted at the end of a completed scan across all storage categories.
struct ScanSnapshot: Equatable, Sendable {
    let scannedAt: Date
    let itemsByCategory: [StorageCategory: [StorageItem]]
    /// The volume holding the Xcode folder; `nil` if it couldn't be read.
    let volume: DiskVolume?
    /// Why a category's scan is incomplete, for each category that couldn't be fully read.
    let failures: [StorageCategory: String]
}

/// A volume's display name and capacity.
struct DiskVolume: Equatable, Sendable {
    let name: String
    let availableBytes: Int64
    let totalBytes: Int64
}

/// Ordered lifecycle events emitted by `XcodeStorage.scan()`.
enum ScanEvent: Equatable, Sendable {
    /// A category's items, and why its scan is incomplete, if it is.
    case categoryScanned(StorageCategory, [StorageItem], failure: String?)
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

    /// Where the scanned folders are.
    let xcodeLocations: XcodeLocations
    let commandRunner: any CommandRunning
    let fileTrasher: any FileTrashing
    /// The clock that stamps scans and ages items.
    let now: @Sendable () -> Date
    /// Shared by every category. Caps walks at `activeProcessorCount - 2`, at least one, meant to
    /// leave pool threads for categories that are ready to report.
    let folderWalkLimiter = FolderWalkLimiter(width: max(1, ProcessInfo.processInfo.activeProcessorCount - 2))

    init(
        xcodeLocations: XcodeLocations = .current(),
        commandRunner: any CommandRunning = ProcessRunner(),
        fileTrasher: any FileTrashing = LiveFileTrasher(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.xcodeLocations = xcodeLocations
        self.commandRunner = commandRunner
        self.fileTrasher = fileTrasher
        self.now = now
    }

    /// Storage for the Xcode folder at `xcodeRootURL`, with DerivedData and archives in it.
    ///
    /// Xcode's Locations settings belong to the real Xcode folder, so they aren't read here.
    init(
        xcodeRootURL: URL,
        commandRunner: any CommandRunning = ProcessRunner(),
        fileTrasher: any FileTrashing = LiveFileTrasher(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            xcodeLocations: XcodeLocations(xcodeRootURL: xcodeRootURL),
            commandRunner: commandRunner,
            fileTrasher: fileTrasher,
            now: now
        )
    }

    /// The Xcode data folder, `~/Library/Developer/Xcode` for the real Xcode.
    var xcodeRootURL: URL {
        xcodeLocations.xcodeRootURL
    }

    // MARK: - Scanning

    /// Scans all storage categories concurrently, streaming each category's results, then a snapshot.
    ///
    /// The `.completed(ScanSnapshot)` event is stamped with `now()`. When cancellation is observed
    /// during `next()`, child scan tasks are cancelled, full producer teardown is awaited, and
    /// `CancellationError` is thrown. Breaking out of iteration early requests producer
    /// cancellation on iterator release without awaiting teardown or throwing.
    func scan() -> some AsyncSequence<ScanEvent, CancellationError> & Sendable {
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
    func delete(_ plan: DeletionPlan) -> some AsyncSequence<DeletionEvent, CancellationError> & Sendable {
        DeletionStream(storage: self, items: plan.deletableItems)
    }

    /// `item` must come from `DeletionPlan.deletableItems`; a protected item traps.
    ///
    /// - Throws: `CancellationError` if cancellation is seen before the removing step is called;
    ///   `RemovalInterrupted` if the step itself ends in cancellation, which may be before it took
    ///   effect or launched.
    fileprivate func remove(_ item: StorageItem) async throws {
        switch item.deletionMethod {
        case let .trashFile(url):
            try await Self.removing { try await fileTrasher.trashItem(at: url) }
        case let .simctlDevice(udid, deviceSet):
            try await deleteSimulatorDevice(udid: udid, in: deviceSet)
        case let .simctlRuntime(identifier):
            try await deleteSimulatorRuntime(identifier: identifier)
        case .notDeletable:
            preconditionFailure("DeletionPlan excludes protected items")
        }
    }

    /// Runs the step that removes an item, reporting its cancellation as `RemovalInterrupted`.
    ///
    /// Cancellation seen before calling `removal` stays `CancellationError`: nothing was removed.
    /// Cancellation that `removal` ends in becomes `RemovalInterrupted`, meaning "may have been
    /// removed": a runner can't say whether a cancelled command launched, so this includes a
    /// command stopped before launch.
    static func removing(_ removal: () async throws -> Void) async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        do {
            try await removal()
        } catch is CancellationError {
            throw RemovalInterrupted()
        }
    }

    // MARK: - Shared Internal Helpers

    /// Inspects `inputs` concurrently, as many at once as `limiter` allows in one lane of its own,
    /// returning the items found sorted largest first.
    ///
    /// A child whose cancellation is seen before it holds a permit skips its input, and an input
    /// whose `inspect` throws contributes no item; the inspections here throw only on cancellation.
    static func scanConcurrently<Input: Sendable>(
        _ inputs: [Input],
        limiter: FolderWalkLimiter,
        inspect: @escaping @Sendable (Input) throws -> StorageItem?
    ) async -> [StorageItem] {
        let lane = limiter.makeLane()
        return await withTaskGroup(of: StorageItem?.self, returning: [StorageItem].self) { group in
            for input in inputs {
                group.addTask {
                    try? await limiter.withPermit(in: lane) { try? inspect(input) }
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

    /// The entries of the folder at `url`, or `nil` if it doesn't exist: a feature never used has no folder.
    ///
    /// - Throws: The error when the folder, or one above it, exists but can't be read, such as
    ///   when access is denied.
    static func folderEntries(of url: URL) throws -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    /// Whether `url` is a folder, following a symbolic link to one.
    static func isFolder(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
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

/// Cancellation after an item's removal began, so the item may be gone.
struct RemovalInterrupted: Error {}

// MARK: - Deletion Logging

private extension DeletionMethod {
    var logName: String {
        switch self {
        case .trashFile: "trash"
        case .simctlDevice(_, .standard): "simctlDevice"
        case .simctlDevice(_, .previews): "simctlPreviewDevice"
        case .simctlRuntime: "simctlRuntime"
        case .notDeletable: "none"
        }
    }

    /// The path, device UDID, or runtime identifier being removed.
    var logTarget: String {
        switch self {
        case let .trashFile(url): url.path
        case let .simctlDevice(udid, _): udid
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
    typealias Failure = CancellationError

    let storage: XcodeStorage

    struct AsyncIterator: AsyncIteratorProtocol {
        private var base: AsyncStream<ScanEvent>.AsyncIterator
        private let producer: ScanProducerHandle
        private var deliveredCompletion = false

        init(storage: XcodeStorage) {
            // Not throwing: the producer ends early only when cancelled, which `next()` reports.
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
            let task = Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    continuation.finish()
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
                        return (.derivedData, items, derivedData.failure)
                    }

                    group.addTask {
                        do {
                            let items = try await storage.scanSimulatorDevices(now: referenceDate)
                            return (.simulatorDevices, items, nil)
                        } catch is CancellationError {
                            return nil
                        } catch {
                            return (.simulatorDevices, [], error.localizedDescription)
                        }
                    }

                    group.addTask {
                        do {
                            let items = try await storage.scanSimulatorRuntimes(now: referenceDate)
                            return (.simulatorRuntimes, items, nil)
                        } catch is CancellationError {
                            return nil
                        } catch {
                            return (.simulatorRuntimes, [], error.localizedDescription)
                        }
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let deviceSupport = await storage.scanDeviceSupport(now: referenceDate)
                        guard !Task.isCancelled else { return nil }
                        return (.deviceSupport, deviceSupport.items, deviceSupport.failure)
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let previews = await storage.scanPreviews(now: referenceDate)
                        guard !Task.isCancelled else { return nil }
                        return (.previews, previews.items, previews.failure)
                    }

                    group.addTask {
                        guard !Task.isCancelled,
                              let archives = try? await storage.scanArchivesAndCaches(sharedCaches: derivedData.sharedCaches),
                              !Task.isCancelled
                        else { return nil }
                        return (.archivesAndCaches, archives.items, archives.failure)
                    }

                    var itemsByCategory: [StorageCategory: [StorageItem]] = [:]
                    var failures: [StorageCategory: String] = [:]

                    for await case let (category, items, failure)? in group {
                        if Task.isCancelled {
                            continue
                        }
                        itemsByCategory[category] = items
                        failures[category] = failure
                        continuation.yield(.categoryScanned(category, items, failure: failure))
                    }

                    return ScanSnapshot(
                        scannedAt: referenceDate,
                        itemsByCategory: itemsByCategory,
                        volume: volume,
                        failures: failures
                    )
                }

                if !Task.isCancelled {
                    continuation.yield(.completed(snapshot))
                }
                continuation.finish()
            }

            let producer = ScanProducerHandle(task: task)
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }

            base = stream.makeAsyncIterator()
            self.producer = producer
        }

        mutating func next() async throws(CancellationError) -> ScanEvent? {
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
            let event = await withTaskCancellationHandler {
                await base.next()
            } onCancel: {
                producer.cancel()
            }

            if Task.isCancelled {
                producer.cancel()
                await producer.waitForExit()
                throw CancellationError()
            }
            guard let event else {
                // The stream ends before `.completed` only when the producer was cancelled.
                await producer.waitForExit()
                throw CancellationError()
            }
            if case .completed = event {
                deliveredCompletion = true
            }
            return event
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
    typealias Failure = CancellationError

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

        mutating func next() async throws(CancellationError) -> DeletionEvent? {
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
                } catch is RemovalInterrupted {
                    // A stopped trash move or simctl command may still have taken effect.
                    Self.logger.notice("""
                    outcome=unknown method=\(item.deletionMethod.logName, privacy: .public) \
                    target=\(item.deletionMethod.logTarget, privacy: .public)
                    """)
                    phase = .done
                    throw CancellationError()
                } catch is CancellationError {
                    Self.logger.notice("""
                    outcome=skipped method=\(item.deletionMethod.logName, privacy: .public) \
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
