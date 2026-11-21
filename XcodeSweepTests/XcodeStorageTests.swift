import Foundation
import os
import Testing
@testable import XcodeSweep

@Suite("XcodeStorage")
struct XcodeStorageTests {
    // MARK: - Scanning Across All 6 Categories

    @Test("Scans all six storage categories, enforces per-category staleness rules, and reports progress")
    func scanAllCategoriesEndToEnd() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let referenceNow = testISO8601Date("2026-11-21T10:00:00Z")
        let tenDaysAgo = referenceNow.addingTimeInterval(-10 * 86400)
        let thirtyFiveDaysAgo = referenceNow.addingTimeInterval(-35 * 86400)
        let sixtyDaysAgo = referenceNow.addingTimeInterval(-60 * 86400)

        // 1. DerivedData (30d threshold): orphaned, git worktree, stale, active — plus ModuleCache skipped here.
        let worktreeProject = try fixture.createWorkspace(
            folderName: "feature-branch",
            projectName: "LinkedApp.xcodeproj",
            isGitWorktree: true
        )
        let staleProject = try fixture.createWorkspace(
            folderName: "old-repo",
            projectName: "OldApp.xcodeproj"
        )
        let activeProject = try fixture.createWorkspace(
            folderName: "active-repo",
            projectName: "ActiveApp.xcodeproj"
        )

        try fixture.addDerivedData(
            folderName: "OrphanedApp-abc123",
            workspacePath: "/nonexistent/path/OrphanedApp.xcodeproj",
            lastAccessed: tenDaysAgo
        )
        try fixture.addDerivedData(
            folderName: "LinkedApp-wt123",
            workspacePath: worktreeProject.path,
            lastAccessed: tenDaysAgo
        )
        try fixture.addDerivedData(
            folderName: "OldApp-xyz",
            workspacePath: staleProject.path,
            lastAccessed: thirtyFiveDaysAgo
        )
        try fixture.addDerivedData(
            folderName: "ActiveApp-cur",
            workspacePath: activeProject.path,
            lastAccessed: tenDaysAgo
        )
        try fixture.addModuleCache()

        // 2. DeviceSupport (45d threshold)
        try fixture.addDeviceSupport(
            platformFolder: "iOS DeviceSupport",
            versionFolder: "18.1 (22B83)",
            modifiedDate: sixtyDaysAgo
        )
        try fixture.addDeviceSupport(
            platformFolder: "watchOS DeviceSupport",
            versionFolder: "11.2 (22S99)",
            modifiedDate: thirtyFiveDaysAgo
        )

        // 3. SwiftUI Previews (45d threshold)
        try fixture.addPreviewDevice(
            udid: "PREVIEW-OLD",
            name: "iPhone 17 Pro",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            modifiedDate: sixtyDaysAgo
        )

        // 4. Archives (always .active regardless of age) + ModuleCache (always .stale)
        try fixture.addArchive(
            dateFolder: "2026-08-01",
            archiveName: "ReleaseApp 8-1-26",
            appName: "ReleaseApp",
            shortVersion: "2.4.0",
            buildVersion: "42",
            bundleID: "com.example.releaseapp",
            creationDate: sixtyDaysAgo
        )

        // 5 & 6. Simulator Devices (30d threshold) & Simulator Runtimes (45d threshold)
        let runtimesJSON = """
        {
          "STALE-RT": {
            "build": "24B114",
            "deletable": true,
            "identifier": "STALE-RT",
            "kind": "Patchable Cryptex Disk Image",
            "lastUsedAt": "2026-08-01T09:27:36Z",
            "path": "/System/Library/AssetsV2/iOS27.2",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            "sizeBytes": 8311163745,
            "state": "Ready",
            "version": "27.2"
          },
          "RECENT-35D-RT": {
            "build": "24B120",
            "deletable": true,
            "identifier": "RECENT-35D-RT",
            "kind": "Cryptex",
            "lastUsedAt": "2026-10-17T10:00:00Z",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-3",
            "sizeBytes": 5000000000,
            "state": "Ready",
            "version": "27.3"
          },
          "SYSTEM-RUNTIME-ID": {
            "build": "24C100",
            "deletable": false,
            "identifier": "SYSTEM-RUNTIME-ID",
            "kind": "Bundled",
            "platformIdentifier": "com.apple.platform.watchsimulator",
            "sizeBytes": 3000000000,
            "state": "Ready",
            "version": "12.0"
          }
        }
        """

        let devicesJSON = """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
              {
                "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/AAA/data",
                "dataPathSize": 4000000000,
                "logPathSize": 500000,
                "udid": "AAA",
                "lastUsedAt": "2026-11-20T09:00:12Z",
                "isAvailable": true,
                "state": "Booted",
                "name": "iPhone 17 Pro"
              },
              {
                "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/BBB/data",
                "dataPathSize": 2500000000,
                "logPathSize": 0,
                "udid": "BBB",
                "isAvailable": false,
                "availabilityError": "runtime profile not found",
                "state": "Shutdown",
                "name": "iPhone 15"
              },
              {
                "dataPath": "/Users/test/Library/Developer/CoreSimulator/Devices/CCC/data",
                "dataPathSize": 1000000000,
                "logPathSize": 0,
                "udid": "CCC",
                "lastUsedAt": "2026-10-10T09:00:00Z",
                "isAvailable": true,
                "state": "Shutdown",
                "name": "iPhone 14 Stale"
              }
            ]
          }
        }
        """

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(devicesJSON: devicesJSON, runtimesJSON: runtimesJSON),
            fileTrasher: RecordingFileTrasher(),
            now: { referenceNow }
        )

        let reportedCategories = CategoryCollector()
        let snapshot = try await storage.scanAll { category, _ in
            Task { await reportedCategories.insert(category) }
        }

        // Volume capacity should be populated from the local volume hosting xcodeRootURL.
        #expect(snapshot.warnings.isEmpty)
        #expect((snapshot.diskTotalBytes ?? 0) > 0)

        // DerivedData: 4 folders (ModuleCache.noindex excluded)
        let derived = try #require(snapshot.itemsByCategory[.derivedData])
        #expect(derived.count == 4)
        let derivedByName = Dictionary(uniqueKeysWithValues: derived.map { ($0.name, $0) })
        #expect(derivedByName["OrphanedApp"]?.status == .orphaned)
        #expect(derivedByName["OrphanedApp"]?.isReclaimableCandidate == true)
        #expect(derivedByName["LinkedApp"]?.status == .worktree)
        #expect(derivedByName["LinkedApp"]?.isReclaimableCandidate == false)
        #expect(derivedByName["OldApp"]?.status == .stale)
        #expect(derivedByName["ActiveApp"]?.status == .active)

        // Simulator Runtimes: 45d threshold keeps 35d-old runtime .active while marking >45d .stale
        let runtimes = try #require(snapshot.itemsByCategory[.simulatorRuntimes])
        #expect(runtimes.count == 3)
        let runtimesByName = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.name, $0) })
        #expect(runtimesByName["iOS 27.2"]?.status == .stale)
        #expect(runtimesByName["iOS 27.2"]?.deletionMethod == .simctlRuntime(identifier: "STALE-RT"))
        #expect(runtimesByName["iOS 27.3"]?.status == .active)
        #expect(runtimesByName["watchOS 12.0"]?.status == .systemManaged)
        #expect(runtimesByName["watchOS 12.0"]?.isDeletable == false)

        // Simulator Devices: 30d threshold + booted + unavailable + data+log size sum
        let devices = try #require(snapshot.itemsByCategory[.simulatorDevices])
        #expect(devices.count == 3)
        let devicesByName = Dictionary(uniqueKeysWithValues: devices.map { ($0.name, $0) })
        #expect(devicesByName["iPhone 17 Pro"]?.sizeBytes == 4_000_500_000)
        #expect(devicesByName["iPhone 17 Pro"]?.status == .booted)
        #expect(devicesByName["iPhone 17 Pro"]?.deletionMethod == .simctlDevice(udid: "AAA", isBooted: true))
        #expect(devicesByName["iPhone 15"]?.status == .unavailable)
        #expect(devicesByName["iPhone 15"]?.isReclaimableCandidate == true)
        #expect(devicesByName["iPhone 14 Stale"]?.status == .stale)

        // DeviceSupport: 45d threshold
        let deviceSupport = try #require(snapshot.itemsByCategory[.deviceSupport])
        #expect(deviceSupport.count == 2)
        let dsByName = Dictionary(uniqueKeysWithValues: deviceSupport.map { ($0.name, $0) })
        #expect(dsByName["18.1 (22B83)"]?.status == .stale)
        #expect(dsByName["11.2 (22S99)"]?.status == .active)

        // Previews: reads device.plist and formats runtime label
        let previews = try #require(snapshot.itemsByCategory[.previews])
        #expect(previews.count == 1)
        #expect(previews.first?.name == "iPhone 17 Pro")
        #expect(previews.first?.subtitle == "iOS 27.2 • PREVIEW-OLD")
        #expect(previews.first?.status == .stale)

        // Archives & Caches: ModuleCache (.stale) + Archive (.active even at 60d old)
        let archivesAndCaches = try #require(snapshot.itemsByCategory[.archivesAndCaches])
        #expect(archivesAndCaches.count == 2)
        let extrasByName = Dictionary(uniqueKeysWithValues: archivesAndCaches.map { ($0.name, $0) })
        #expect(extrasByName["ModuleCache.noindex"]?.status == .stale)
        #expect(extrasByName["ReleaseApp"]?.status == .active)
        #expect(extrasByName["ReleaseApp"]?.subtitle == "v2.4.0 (42)")

        // Wait briefly for progress tasks to complete and verify all 6 categories were reported.
        try await waitUntil("all 6 categories reported") {
            await reportedCategories.count == StorageCategory.allCases.count
        }
    }

    @Test("Records warnings instead of failing scanAll when simctl fails")
    func scanAllCapturesSimctlWarnings() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(
                devicesError: ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "simctl unavailable"),
                runtimesError: ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "runtime error")
            ),
            fileTrasher: RecordingFileTrasher()
        )

        let snapshot = try await storage.scanAll { _, _ in }

        #expect(snapshot.itemsByCategory[.simulatorDevices] == [])
        #expect(snapshot.itemsByCategory[.simulatorRuntimes] == [])
        #expect(snapshot.warnings.count == 2)
    }

    // MARK: - Deletion Through OS-Edge Seams

    @Test("Trashes filesystem items through FileTrashing adapter and records partial failures")
    func deleteTrashesFilesAndRecordsFailure() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let goodURL = try fixture.addDerivedData(
            folderName: "Good-1",
            workspacePath: "/nonexistent/Good.xcodeproj",
            lastAccessed: Date()
        )
        let badURL = try fixture.addDerivedData(
            folderName: "Locked-2",
            workspacePath: "/nonexistent/Locked.xcodeproj",
            lastAccessed: Date()
        )

        let trasher = RecordingFileTrasher(failingURLs: [badURL])
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: trasher
        )

        let snapshot = try await storage.scanAll { _, _ in }
        let items = try #require(snapshot.itemsByCategory[.derivedData])
            .sorted { $0.name < $1.name }

        let recorder = ProgressRecorder()
        let report = await storage.delete(items: items) { progress in
            await recorder.append(progress)
        }

        let trashed = await trasher.trashedURLs
        #expect(trashed == [goodURL])
        #expect(report.deletedCount == 1)
        #expect(report.trashedCount == 1)
        #expect(report.simctlDeletedCount == 0)
        #expect(report.removedItemIDs == ["derivedData:\(goodURL.path)"])
        #expect(report.failures.map(\.itemID) == ["derivedData:\(badURL.path)"])

        let events = await recorder.snapshot()
        #expect(events.count == 4)
        #expect(events[1].removedItemID == "derivedData:\(goodURL.path)")
        #expect(events[3].removedItemID == nil)
    }

    @Test(
        "Emits ordered start and completion progress across a suspended simctl deletion and handles failures",
        .timeLimit(.minutes(1))
    )
    func deleteEmitsOrderedProgressAcrossSuspensionAndFailure() async throws {
        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )

        let bootedDevice = StorageItem(
            id: "sim-1",
            category: .simulatorDevices,
            name: "iPhone 17 Pro",
            subtitle: "iOS 27.2",
            sizeBytes: 4_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .booted,
            deletionMethod: .simctlDevice(udid: "UDID-1", isBooted: true),
            metadata: []
        )
        let failingRuntime = StorageItem(
            id: "rt-2",
            category: .simulatorRuntimes,
            name: "iOS 26.4",
            subtitle: "Build 23E100",
            sizeBytes: 8_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .stale,
            deletionMethod: .simctlRuntime(identifier: "RT-2"),
            metadata: []
        )
        let protectedRuntime = StorageItem(
            id: "rt-3",
            category: .simulatorRuntimes,
            name: "watchOS 12.0",
            subtitle: "Bundled",
            sizeBytes: 3_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .systemManaged,
            deletionMethod: .notDeletable(reason: "Managed by Xcode"),
            metadata: []
        )

        let recordedEvents = ProgressRecorder()

        async let pendingReport = storage.delete(items: [bootedDevice, failingRuntime, protectedRuntime]) { progress in
            await recordedEvents.append(progress)
        }

        let firstCall = try await controller.nextPendingCall()
        #expect(firstCall.arguments == ["simctl", "shutdown", "UDID-1"])

        let eventsWhileSuspended = await recordedEvents.snapshot()
        #expect(eventsWhileSuspended.count == 1)
        #expect(eventsWhileSuspended.first == DeletionProgress(
            completedCount: 0,
            totalCount: 3,
            currentItemName: "iPhone 17 Pro",
            removedBytes: 0,
            removedItemID: nil
        ))

        await controller.resumeCall(
            id: firstCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        let secondCall = try await controller.nextPendingCall()
        #expect(secondCall.arguments == ["simctl", "delete", "UDID-1"])
        await controller.resumeCall(
            id: secondCall.id,
            with: .success(CommandOutput(stdout: Data(), stderr: Data(), terminationStatus: 0))
        )

        let thirdCall = try await controller.nextPendingCall()
        #expect(thirdCall.arguments == ["simctl", "runtime", "delete", "RT-2"])

        let eventsBeforeFailureResolves = await recordedEvents.snapshot()
        #expect(eventsBeforeFailureResolves.count == 3)
        #expect(eventsBeforeFailureResolves[1] == DeletionProgress(
            completedCount: 1,
            totalCount: 3,
            currentItemName: "iPhone 17 Pro",
            removedBytes: 4_000_000_000,
            removedItemID: "sim-1"
        ))
        #expect(eventsBeforeFailureResolves[2] == DeletionProgress(
            completedCount: 1,
            totalCount: 3,
            currentItemName: "iOS 26.4",
            removedBytes: 4_000_000_000,
            removedItemID: nil
        ))

        await controller.resumeCall(
            id: thirdCall.id,
            with: .failure(ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "runtime busy"))
        )

        let report = await pendingReport
        let allEvents = await recordedEvents.snapshot()

        #expect(allEvents.count == 6)
        #expect(allEvents[3].removedItemID == nil)
        #expect(allEvents[5].removedItemID == nil)
        #expect(report.deletedCount == 1)
        #expect(report.trashedCount == 0)
        #expect(report.simctlDeletedCount == 1)
        #expect(report.reclaimedBytes == 4_000_000_000)
        #expect(report.removedItemIDs == ["sim-1"])
        #expect(report.failures.map(\.itemID) == ["rt-2", "rt-3"])
    }

    @Test(
        "Cancelling while parked inside CommandRunning exits promptly instead of hanging",
        .timeLimit(.minutes(1))
    )
    func cancelledDeletionExitsImmediately() async throws {
        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )

        let device = StorageItem(
            id: "sim-extra",
            category: .simulatorDevices,
            name: "iPhone 17",
            subtitle: "iOS 27.2",
            sizeBytes: 1_000_000_000,
            lastUsedDate: nil,
            path: nil,
            workspacePath: nil,
            status: .unavailable,
            deletionMethod: .simctlDevice(udid: "UDID-EXTRA", isBooted: false),
            metadata: []
        )

        let outerTask = Task { () -> DeletionReport in
            await storage.delete(items: [device]) { _ in }
        }
        defer { outerTask.cancel() }

        try await waitUntil("worker parked in command runner") {
            await controller.hasParkedCall
        }
        outerTask.cancel()

        let report = await outerTask.value
        #expect(report.deletedCount == 0)
        #expect(report.failures.map(\.itemID) == ["sim-extra"])
    }

    @Test(
        "Throws CancellationError and reports no simulator progress when cancelled during simctl",
        .timeLimit(.minutes(1))
    )
    func scanCancelledDuringSimctlThrowsWithoutSimulatorProgress() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let controller = ControllableCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: controller,
            fileTrasher: RecordingFileTrasher()
        )
        let reportedCategories = OSAllocatedUnfairLock<[StorageCategory]>(initialState: [])

        let scanTask = Task {
            try await storage.scanAll { category, _ in
                reportedCategories.withLock { $0.append(category) }
            }
        }
        defer { scanTask.cancel() }

        _ = try await controller.nextPendingCall()
        _ = try await controller.nextPendingCall()
        scanTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await scanTask.value
        }
        let reported = reportedCategories.withLock { $0 }
        #expect(!reported.contains(.simulatorDevices))
        #expect(!reported.contains(.simulatorRuntimes))
    }

    @Test("Finishes delivering every progress update before returning")
    func scanAwaitsProgressDelivery() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )
        let deliveredCategories = OSAllocatedUnfairLock<Set<StorageCategory>>(initialState: [])

        _ = try await storage.scanAll { category, _ in
            try? await Task.sleep(for: .milliseconds(20))
            deliveredCategories.withLock { _ = $0.insert(category) }
        }

        #expect(deliveredCategories.withLock { $0 } == Set(StorageCategory.allCases))
    }

    // MARK: - Test Adapter Waiters

    @Test(
        "Cancelling a registered command waiter exits immediately instead of hanging",
        .timeLimit(.minutes(1))
    )
    func cancelledCommandWaiterExitsImmediately() async throws {
        let controller = ControllableCommandRunner()
        let waiterTask = Task {
            try await controller.nextPendingCall()
        }
        defer { waiterTask.cancel() }

        try await waitUntil("command waiter registered") {
            await controller.hasRegisteredWaiter
        }
        waiterTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiterTask.value
        }
    }

    @Test(
        "Cancelling a registered trash waiter exits immediately instead of hanging",
        .timeLimit(.minutes(1))
    )
    func cancelledTrashWaiterExitsImmediately() async throws {
        let trasher = ControllableFileTrasher()
        let waiterTask = Task {
            try await trasher.nextPendingTrash()
        }
        defer { waiterTask.cancel() }

        try await waitUntil("trash waiter registered") {
            await trasher.hasRegisteredWaiter
        }
        waiterTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiterTask.value
        }
    }
}

private actor CategoryCollector {
    private var categories: Set<StorageCategory> = []

    var count: Int {
        categories.count
    }

    func insert(_ category: StorageCategory) {
        categories.insert(category)
    }
}
