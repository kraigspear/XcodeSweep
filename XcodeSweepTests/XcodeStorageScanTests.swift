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
        try fixture.addModuleCache(modifiedDate: thirtyFiveDaysAgo)

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

        // 4. Archives (always .active regardless of age) + ModuleCache (DerivedData's 30d threshold)
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
            case let .categoryScanned(category, _, _):
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
        #expect(snapshot.failures.isEmpty)
        let expectedVolumeName = try fixture.xcodeRootURL
            .resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        let volume = try #require(snapshot.volume)
        #expect(volume.name == expectedVolumeName)
        #expect(volume.totalBytes > 0)

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
        #expect(devicesByName["iPhone 17 Pro"]?.deletionMethod == .simctlDevice(udid: "AAA"))
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

        // Archives & Caches: ModuleCache (.stale at 35d) + Archive (.active even at 60d old)
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

    @Test("Records a failure for each simctl category instead of failing the scan")
    func simctlFailuresAreCategoryFailures() async throws {
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
        #expect(snapshot.failures[.simulatorDevices]?.contains("simctl unavailable") == true)
        #expect(snapshot.failures[.simulatorRuntimes]?.contains("runtime error") == true)
        #expect(snapshot.failures.count == 2)
    }

    @Test("Records a failure instead of failing the scan when simctl times out")
    func simctlTimeoutIsCategoryFailure() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(
                devicesError: ProcessRunnerError.timedOut(
                    command: "xcrun simctl list devices -j",
                    timeout: .seconds(60)
                )
            ),
            fileTrasher: RecordingFileTrasher()
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.itemsByCategory[.simulatorDevices] == [])
        #expect(snapshot.failures.count == 1)
        #expect(snapshot.failures[.simulatorDevices]?.contains("timed out") == true)
    }

    @Test("Gives every simctl list command a 60-second timeout during scan")
    func scanPassesTimeoutToSimctlListCommands() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }

        let runner = RecordingCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )

        _ = try await finalScanSnapshot(from: storage)

        let calls = await runner.calls
        let devicesCall = try #require(calls.first { $0.arguments == ["simctl", "list", "devices", "-j"] })
        let runtimesCall = try #require(calls.first { $0.arguments == ["simctl", "runtime", "list", "-j"] })
        let previewsCall = try #require(calls.first { $0.arguments == ["simctl", "--set", "previews", "list", "devices", "-j"] })
        // A literal, so raising the constant fails here; ADR 0001's reasoning assumes a short limit.
        #expect(devicesCall.timeout == .seconds(60))
        #expect(runtimesCall.timeout == .seconds(60))
        #expect(previewsCall.timeout == .seconds(60))
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

        // The inspector distinguishes unreachable from present and from gone.
        let workspaceExists = { (name: String) in
            byName[name]?.metadata.first { $0.key == "Workspace Exists" }?.value
        }
        #expect(workspaceExists("Locked") == "Unknown (Not Accessible)")
        #expect(workspaceExists("Unmounted") == "Unknown (Not Accessible)")
        #expect(workspaceExists("Gone") == "No (Deleted or Moved)")
        #expect(byName["Locked"]?.isReclaimable == false)
        #expect(byName["Unmounted"]?.isReclaimable == false)
    }

    /// To replicate: build any project, then open Archives & Caches; the module cache showed
    /// Unused beside a Last Used of minutes ago.
    @Test("Ages the module cache by DerivedData's threshold instead of always calling it unused")
    func recentlyUsedModuleCacheIsActive() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        try fixture.addModuleCache(modifiedDate: now.addingTimeInterval(-29 * 86400))

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let snapshot = try await finalScanSnapshot(from: storage)
        let moduleCache = try #require(
            snapshot.itemsByCategory[.archivesAndCaches]?.first { $0.name == "ModuleCache.noindex" }
        )

        #expect(moduleCache.status == .active)
        #expect(moduleCache.isReclaimable == false)
    }

    @Test("Counts a module written into a cache subfolder as use, though the cache folder's own date is old")
    func moduleCacheUsedThroughSubfolderIsActive() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")

        // Given: a build wrote a module into an existing hash folder an hour ago,
        // which leaves the cache folder's own date 35 days old
        let cacheURL = try fixture.addModuleCache(modifiedDate: now.addingTimeInterval(-35 * 86400))
        let hashFolder = cacheURL.appendingPathComponent("1046HBEBLAASD", isDirectory: true)
        try FileManager.default.createDirectory(at: hashFolder, withIntermediateDirectories: true)
        try Data(repeating: 0xBB, count: 4096).write(to: hashFolder.appendingPathComponent("Foundation-3S5Y.pcm"))
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: hashFolder.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-35 * 86400)], ofItemAtPath: cacheURL.path
        )

        // When
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let snapshot = try await finalScanSnapshot(from: storage)

        // Then
        let moduleCache = try #require(
            snapshot.itemsByCategory[.archivesAndCaches]?.first { $0.name == "ModuleCache.noindex" }
        )
        #expect(moduleCache.status == .active)
        #expect(moduleCache.isReclaimable == false)
        #expect(moduleCache.lastUsedDate == now.addingTimeInterval(-3600))
    }

    /// To replicate: build one project in Xcode and with `xcodebuild -derivedDataPath`; two rows
    /// showed the same name and workspace with nothing to tell them apart.
    @Test("Names the folder only on DerivedData rows that share a workspace")
    func sharedWorkspaceRowsShowFolderName() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let sharedProject = try fixture.createWorkspace(folderName: "shared-repo", projectName: "Shared.xcodeproj")
        let soloProject = try fixture.createWorkspace(folderName: "solo-repo", projectName: "Solo.xcodeproj")
        try fixture.addDerivedData(folderName: "Shared-hash1", workspacePath: sharedProject.path, lastAccessed: now)
        try fixture.addDerivedData(folderName: "SharedCustom-kli453", workspacePath: sharedProject.path, lastAccessed: now)
        try fixture.addDerivedData(folderName: "Solo-hash2", workspacePath: soloProject.path, lastAccessed: now)

        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let snapshot = try await finalScanSnapshot(from: storage)
        let byFolder = Dictionary(
            uniqueKeysWithValues: try #require(snapshot.itemsByCategory[.derivedData])
                .map { ($0.path?.lastPathComponent ?? "", $0) }
        )

        #expect(byFolder["Shared-hash1"]?.subtitle.hasSuffix(" — Shared-hash1") == true)
        #expect(byFolder["SharedCustom-kli453"]?.subtitle.hasSuffix(" — SharedCustom-kli453") == true)
        #expect(byFolder["Solo-hash2"]?.subtitle.contains("Solo-hash2") == false)
    }

    /// The footer once hard-coded "Macintosh HD"; the system VM volume is named "VM", so a hard-coded name fails here.
    @Test("Snapshot names the volume holding the Xcode folder")
    func scanReadsNameOfVolumeHoldingXcodeFolder() async throws {
        let vmVolumeURL = URL(fileURLWithPath: "/System/Volumes/VM")
        let expectedName = try #require(
            vmVolumeURL.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        )

        let storage = XcodeStorage(
            xcodeRootURL: vmVolumeURL.appendingPathComponent("XcodeSweep-Missing-\(UUID().uuidString)/Xcode"),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )
        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.volume?.name == expectedName)
    }

    /// To replicate: open DerivedData; Xcode's own caches such as SDKExplicitPrecompiledModules
    /// appeared as Orphaned because they have no info.plist.
    @Test("Lists Xcode's shared DerivedData caches under Archives & Caches, not as orphaned projects")
    func sharedDerivedDataCachesAreNotProjects() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let derivedData = fixture.xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true)

        // Given: shared caches with no info.plist, a project folder that lost its info.plist,
        // and a project folder Xcode named without the usual hash
        for cache in ["SDKExplicitPrecompiledModules", "CompilationCache.noindex", "SymbolCache.noindex", "moduleCache"] {
            let url = derivedData.appendingPathComponent(cache, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 0xCC, count: 4096).write(to: url.appendingPathComponent("cache.bin"))
        }
        try fixture.addModuleCache(modifiedDate: now.addingTimeInterval(-35 * 86400))
        let lostPlist = derivedData.appendingPathComponent("LostPlist-abcdefghijklmnopqrstuvwxyzab", isDirectory: true)
        try FileManager.default.createDirectory(at: lostPlist, withIntermediateDirectories: true)
        try fixture.addDerivedData(
            folderName: "Custom-kli453",
            workspacePath: "/nonexistent/Custom.xcodeproj",
            lastAccessed: now
        )

        // When
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )
        let snapshot = try await finalScanSnapshot(from: storage)

        // Then: only project folders are DerivedData items
        let projects = try #require(snapshot.itemsByCategory[.derivedData])
        #expect(Set(projects.compactMap { $0.path?.lastPathComponent }) == [lostPlist.lastPathComponent, "Custom-kli453"])
        #expect(projects.allSatisfy { $0.status == .orphaned })

        // The caches are listed as caches, recommended only where they already were.
        let caches = Dictionary(
            uniqueKeysWithValues: try #require(snapshot.itemsByCategory[.archivesAndCaches]).map { ($0.name, $0) }
        )
        for cache in ["SDKExplicitPrecompiledModules", "CompilationCache.noindex", "SymbolCache.noindex"] {
            #expect(caches[cache]?.status == .active, "\(cache)")
            #expect(caches[cache]?.isReclaimable == false, "\(cache)")
            #expect((caches[cache]?.sizeBytes ?? 0) > 0, "\(cache)")
        }
        #expect(caches["ModuleCache.noindex"]?.status == .stale)
        // A cache folder whose name matches the module cache's id must not share it.
        #expect(caches["ModuleCache.noindex"]?.id != caches["moduleCache"]?.id)
    }

    /// Trashing a registered preview device leaves CoreSimulator's set pointing at a missing folder.
    /// To replicate: open a SwiftUI preview in Xcode → scan → the SwiftUI Previews row deletes via simctl.
    @Test("Lists registered preview devices for simctl deletion and leftover folders for Trash")
    func previewDevicesComeFromSimctl() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        // simctl reaches the folder through another path, a symlink: one folder and one device, so one row.
        let registeredURL = try fixture.addPreviewDevice(
            udid: "abcdef01-reg1", name: "iPhone 18 Pro", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-3", modifiedDate: now
        )
        let leftoverURL = try fixture.addPreviewDevice(
            udid: "LEFTOVER-1", name: "iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", modifiedDate: now
        )
        let registeredAlias = fixture.rootURL.appendingPathComponent("ABCDEF01-REG1")
        try FileManager.default.createSymbolicLink(at: registeredAlias, withDestinationURL: registeredURL)
        let previewJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-3":[{
          "dataPath":"\(registeredAlias.path)/data","dataPathSize":2000,"logPathSize":500,
          "udid":"ABCDEF01-REG1","lastUsedAt":"2026-09-01T00:00:00Z","isAvailable":true,"state":"Shutdown","name":"iPhone 18 Pro"
        }]}}
        """
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(previewDevicesJSON: previewJSON),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        let previews = try #require(snapshot.itemsByCategory[.previews])
        let registered = try #require(previews.first { $0.name == "iPhone 18 Pro" })
        #expect(registered.deletionMethod == .simctlDevice(udid: "ABCDEF01-REG1", deviceSet: .previews))
        #expect(registered.sizeBytes == 2500)
        // Aged by simctl's last use, not the recently modified folder.
        #expect(registered.lastUsedDate == testISO8601Date("2026-09-01T00:00:00Z"))
        #expect(registered.status == .stale)
        let leftover = try #require(previews.first { $0.name == "iPhone 17" })
        #expect(leftover.deletionMethod == .trashFile(leftoverURL))
        #expect(previews.count == 2)
        #expect(snapshot.failures.isEmpty)
    }

    /// Without simctl's answer, any folder might be registered, so none is offered for Trash.
    /// To replicate: make `xcrun simctl --set previews list` fail → scan → preview rows are protected.
    @Test("Protects preview folders and warns when simctl can't list the preview set")
    func previewFoldersProtectedWhenSimctlFails() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        try fixture.addPreviewDevice(
            udid: "UNKNOWN-1", name: "iPhone 17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", modifiedDate: now
        )
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(
                previewDevicesError: ProcessRunnerError.nonZeroExit(command: "xcrun", status: 1, stderr: "no previews set")
            ),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        let previews = try #require(snapshot.itemsByCategory[.previews])
        #expect(previews.count == 1)
        #expect(previews.first?.isDeletable == false)
        #expect(snapshot.failures[.previews]?.contains("no previews set") == true)
    }

    /// `simctl --set previews` fails when Xcode has never created the set.
    /// To replicate: on a Mac that has never run a SwiftUI preview, scan → no SwiftUI Previews failure.
    @Test("Skips the preview set, without a failure, when its folder doesn't exist")
    func missingPreviewSetIsQuiet() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.xcodeRootURL.appendingPathComponent("UserData"))
        let runner = RecordingCommandRunner()
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: runner,
            fileTrasher: RecordingFileTrasher()
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.itemsByCategory[.previews] == [])
        #expect(snapshot.failures.isEmpty)
        #expect(await !runner.calls.contains { $0.arguments.contains("previews") })
    }

    /// On a case-sensitive volume a folder spelled differently from simctl's UDID is a different
    /// folder; only the one simctl's data path names is the registered device.
    @Test("A preview folder simctl's data path doesn't name is a leftover, even with the same UDID")
    func sameUDIDDifferentFolderIsLeftover() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let setFolder = try fixture.addPreviewDevice(
            udid: "abcdef01-copy", name: "Copy", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-3", modifiedDate: now
        )
        let registeredFolder = fixture.rootURL.appendingPathComponent("Elsewhere/ABCDEF01-COPY", isDirectory: true)
        try FileManager.default.createDirectory(at: registeredFolder, withIntermediateDirectories: true)
        let previewJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-3":[{
          "dataPath":"\(registeredFolder.path)/data","udid":"ABCDEF01-COPY","isAvailable":true,"state":"Shutdown","name":"Registered"
        }]}}
        """
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(previewDevicesJSON: previewJSON),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let previews = try #require(try await finalScanSnapshot(from: storage).itemsByCategory[.previews])

        #expect(previews.map(\.name).sorted() == ["Copy", "Registered"])
        #expect(previews.first { $0.name == "Copy" }?.deletionMethod == .trashFile(setFolder))
    }

    /// Without a data path there is no folder to compare, so a folder named like the device is kept.
    @Test("A preview folder named like a registered device with no data path is protected")
    func unlocatedRegisteredDeviceProtectsItsFolder() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        try fixture.addPreviewDevice(
            udid: "abcdef01-nopath", name: "Folder", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-3", modifiedDate: now
        )
        let previewJSON = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-3":[{
          "udid":"ABCDEF01-NOPATH","isAvailable":true,"state":"Shutdown","name":"Registered"
        }]}}
        """
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(previewDevicesJSON: previewJSON),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let previews = try #require(try await finalScanSnapshot(from: storage).itemsByCategory[.previews])

        #expect(previews.first { $0.name == "Folder" }?.isDeletable == false)
        #expect(previews.first { $0.name == "Registered" }?.isDeletable == true)
    }

    /// A folder that exists but can't be read must not look empty.
    /// To replicate: `chmod 000 ~/Library/Developer/Xcode/iOS\ DeviceSupport` → scan → Device Support says it couldn't scan.
    @Test("Records a failure for each category whose folder can't be read, and keeps what it could read")
    func unreadableFoldersAreFailures() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        _ = try fixture.addDeviceSupport(platformFolder: "watchOS DeviceSupport", versionFolder: "11.2 (22S99)", modifiedDate: now)
        _ = try fixture.addDerivedData(folderName: "App-abcdefghijklmnopqrstuvwxyzab", workspacePath: nil, lastAccessed: now)
        try fixture.addArchive(
            dateFolder: "2026-08-01", archiveName: "App 8-1-26", appName: "App",
            shortVersion: "1.0", buildVersion: "1", bundleID: "com.example.app", creationDate: now
        )
        let lockedFolders = [
            fixture.xcodeRootURL.appendingPathComponent("iOS DeviceSupport", isDirectory: true),
            fixture.xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true),
            fixture.xcodeRootURL.appendingPathComponent("Archives", isDirectory: true),
        ]
        for folder in lockedFolders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        }
        defer {
            for folder in lockedFolders {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
        }
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(Set(snapshot.failures.keys) == [.deviceSupport, .derivedData, .archivesAndCaches])
        #expect(snapshot.failures[.deviceSupport]?.contains("iOS DeviceSupport") == true)
        #expect(snapshot.itemsByCategory[.deviceSupport]?.map(\.name) == ["11.2 (22S99)"])
    }

    /// A Mac that never used a feature has no folder for it, and that is no failure.
    @Test("Records no failures when the Xcode folder has none of the scanned folders")
    func missingFoldersAreNotFailures() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.xcodeRootURL.appendingPathComponent("UserData"))
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.failures.isEmpty)
    }

    /// A preview set that exists behind a folder the user can't search must not look missing.
    @Test("A preview set behind a folder that can't be read is a failure, not a missing set")
    func previewSetBehindUnreadableFolderIsFailure() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let previews = fixture.xcodeRootURL.appendingPathComponent("UserData/Previews", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: previews.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previews.path) }
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher()
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.failures[.previews] != nil)
    }

    /// To replicate: replace an Archives date folder with a symbolic link to it → scan → its archives still appear.
    @Test("Archives in a date folder reached through symbolic links are listed once")
    func linkedArchiveDateFolderIsScanned() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let elsewhere = try TempXcodeFixture()
        defer { elsewhere.cleanup() }
        let archive = try elsewhere.addArchive(
            dateFolder: "2026-08-01", archiveName: "Linked 8-1-26", appName: "LinkedApp",
            shortVersion: "1.0", buildVersion: "1", bundleID: "com.example.linked", creationDate: now
        )
        let archives = fixture.xcodeRootURL.appendingPathComponent("Archives", isDirectory: true)
        try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: archives.appendingPathComponent("2026-08-01"),
            withDestinationURL: archive.deletingLastPathComponent()
        )
        // A second link to the same folder adds nothing, and a stray file is skipped, not reported.
        try FileManager.default.createSymbolicLink(
            at: archives.appendingPathComponent("Latest"),
            withDestinationURL: archive.deletingLastPathComponent()
        )
        try Data().write(to: archives.appendingPathComponent("notes.txt"))
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.itemsByCategory[.archivesAndCaches]?.map(\.name) == ["LinkedApp"])
        #expect(snapshot.failures.isEmpty)
    }

    /// A linked date folder whose target can't be reached must not look empty.
    @Test("A linked archive folder that can't be reached is a failure, and its readable siblings still count")
    func unreachableLinkedArchiveFolderIsFailure() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        try fixture.addArchive(
            dateFolder: "2026-08-01", archiveName: "Readable 8-1-26", appName: "ReadableApp",
            shortVersion: "1.0", buildVersion: "1", bundleID: "com.example.readable", creationDate: now
        )
        let locked = fixture.rootURL.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("2026-09-01"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.xcodeRootURL.appendingPathComponent("Archives/2026-09-01"),
            withDestinationURL: locked.appendingPathComponent("2026-09-01")
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.failures[.archivesAndCaches]?.contains("2026-09-01") == true)
        #expect(snapshot.itemsByCategory[.archivesAndCaches]?.map(\.name) == ["ReadableApp"])
    }

    /// A folder listed but gone by the time it is identified might have been a registered device's
    /// folder, so it must not be offered for Trash.
    @Test("A preview folder that vanishes after listing is left out", .timeLimit(.minutes(1)))
    func previewFolderVanishingAfterListingIsLeftOut() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let kept = try fixture.addPreviewDevice(
            udid: "KEPT-1", name: "Kept", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-3", modifiedDate: now
        )
        let vanishing = try fixture.addPreviewDevice(
            udid: "VANISHING-1", name: "Vanishing", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-3", modifiedDate: now
        )
        // The set is listed before simctl runs, so removing a folder here lands between listing and lookup.
        let storage = XcodeStorage(
            xcodeRootURL: fixture.xcodeRootURL,
            commandRunner: RemovingOnPreviewListRunner(folder: vanishing),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let previews = try #require(try await finalScanSnapshot(from: storage).itemsByCategory[.previews])

        #expect(previews.map(\.path) == [kept])
        #expect(previews.first?.deletionMethod == .trashFile(kept))
    }
}

/// Answers like `StubCommandRunner`, and removes `folder` when the preview set is listed.
private struct RemovingOnPreviewListRunner: CommandRunning {
    let folder: URL

    func run(executableURL: URL, arguments: [String], timeout: Duration?) async throws -> CommandOutput {
        if arguments.contains("previews") {
            try FileManager.default.removeItem(at: folder)
        }
        return try await StubCommandRunner().run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }
}
