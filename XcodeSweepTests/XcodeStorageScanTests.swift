import Foundation
import Testing
@testable import XcodeSweep

@Suite("XcodeStorage scanning")
struct XcodeStorageScanTests {
    @Test("Scans all six storage categories, enforces per-category staleness rules, and streams ordered events")
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

        var reportedCategories: Set<StorageCategory> = []
        var completedSnapshots: [ScanSnapshot] = []

        for try await event in storage.scan() {
            switch event {
            case let .categoryScanned(category, _):
                #expect(completedSnapshots.isEmpty)
                reportedCategories.insert(category)
            case let .completed(snapshot):
                completedSnapshots.append(snapshot)
            }
        }

        #expect(reportedCategories == Set(StorageCategory.allCases))
        #expect(completedSnapshots.count == 1)
        let snapshot = try #require(completedSnapshots.first)

        // Volume capacity and injected clock timestamp should be populated on the snapshot.
        #expect(snapshot.scannedAt == referenceNow)
        #expect(snapshot.warnings.isEmpty)
        #expect((snapshot.diskTotalBytes ?? 0) > 0)

        // DerivedData: 4 folders (ModuleCache.noindex excluded)
        let derived = try #require(snapshot.itemsByCategory[.derivedData])
        #expect(derived.count == 4)
        let derivedByName = Dictionary(uniqueKeysWithValues: derived.map { ($0.name, $0) })
        #expect(derivedByName["OrphanedApp"]?.status == .orphaned)
        #expect(derivedByName["OrphanedApp"]?.isReclaimable == true)
        #expect(derivedByName["LinkedApp"]?.status == .worktree)
        #expect(derivedByName["LinkedApp"]?.isReclaimable == false)
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
        #expect(devicesByName["iPhone 15"]?.isReclaimable == true)
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

        // Every status a scanner assigned must be one its category declares, so filters can't drift from scanners.
        for (category, items) in snapshot.itemsByCategory {
            for item in items {
                #expect(category.possibleStatuses.contains(item.status), "\(category): \(item.name) is \(item.status)")
            }
        }
    }

    @Test("Records warnings instead of failing scan when simctl fails")
    func scanCapturesSimctlWarnings() async throws {
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

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.itemsByCategory[.simulatorDevices] == [])
        #expect(snapshot.itemsByCategory[.simulatorRuntimes] == [])
        #expect(snapshot.warnings.count == 2)
    }

    @Test("Classifies DerivedData as orphaned only when its workspace is provably gone")
    func unreachableWorkspaceIsNotOrphaned() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")

        // A workspace inside a folder this user can't search, as with a TCC denial.
        let lockedFolder = fixture.rootURL.appendingPathComponent("Locked", isDirectory: true)
        let lockedWorkspace = lockedFolder.appendingPathComponent("Locked.xcodeproj")
        try FileManager.default.createDirectory(at: lockedWorkspace, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.path) }

        try fixture.addDerivedData(
            folderName: "Locked-1",
            workspacePath: lockedWorkspace.path,
            lastAccessed: now
        )
        try fixture.addDerivedData(
            folderName: "Unmounted-2",
            workspacePath: "/Volumes/XcodeSweep-Unmounted-\(UUID().uuidString)/Unmounted.xcodeproj",
            lastAccessed: now
        )
        // A project folder symlinked to an ejected drive.
        let linkedFolder = fixture.rootURL.appendingPathComponent("LinkedProjects")
        try FileManager.default.createSymbolicLink(
            atPath: linkedFolder.path,
            withDestinationPath: "/Volumes/XcodeSweep-Ejected-\(UUID().uuidString)/Projects"
        )
        try fixture.addDerivedData(
            folderName: "Linked-4",
            workspacePath: linkedFolder.appendingPathComponent("Linked.xcodeproj").path,
            lastAccessed: now
        )
        // The same unmounted volume, spelled through the Data volume's firmlink.
        try fixture.addDerivedData(
            folderName: "DataVolumes-5",
            workspacePath: "/System/Volumes/Data/Volumes/XcodeSweep-Unmounted-\(UUID().uuidString)/DataVolumes.xcodeproj",
            lastAccessed: now
        )
        // A folder in the recorded path is now a regular file.
        let fileInPath = fixture.rootURL.appendingPathComponent("NowAFile")
        try Data("x".utf8).write(to: fileInPath)
        try fixture.addDerivedData(
            folderName: "Replaced-6",
            workspacePath: fileInPath.appendingPathComponent("Replaced.xcodeproj").path,
            lastAccessed: now
        )
        try fixture.addDerivedData(
            folderName: "Gone-3",
            workspacePath: fixture.rootURL.appendingPathComponent("Deleted/Gone.xcodeproj").path,
            lastAccessed: now
        )

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let snapshot = try await finalScanSnapshot(from: storage)
        let byName = Dictionary(
            uniqueKeysWithValues: try #require(snapshot.itemsByCategory[.derivedData]).map { ($0.name, $0) }
        )

        #expect(byName["Locked"]?.status == .active)
        #expect(byName["Unmounted"]?.status == .active)
        #expect(byName["Gone"]?.status == .orphaned)
        #expect(byName["Linked"]?.status == .active)
        #expect(byName["DataVolumes"]?.status == .active)
        #expect(byName["Replaced"]?.status == .orphaned)
        #expect(byName["Locked"]?.isReclaimable == false)
        #expect(byName["Unmounted"]?.isReclaimable == false)
    }
}
