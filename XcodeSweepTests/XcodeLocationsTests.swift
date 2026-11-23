import Foundation
import Testing
@testable import XcodeSweep

@Suite("Xcode locations")
struct XcodeLocationsTests {
    private let xcodeRoot = URL(filePath: "/Users/test/Library/Developer/Xcode", directoryHint: .isDirectory)

    @Test("Without custom locations, DerivedData and Archives sit in the Xcode folder")
    func defaultsSitInXcodeFolder() {
        let locations = XcodeLocations(xcodeRootURL: xcodeRoot, settings: [:])

        #expect(locations.derivedDataURL.path == "/Users/test/Library/Developer/Xcode/DerivedData")
        #expect(locations.archivesURL.path == "/Users/test/Library/Developer/Xcode/Archives")
    }

    /// To replicate: Xcode Settings → Locations → set DerivedData and Archives to Custom → scan.
    @Test("Absolute custom locations from Xcode's settings are used")
    func absoluteCustomLocationsAreUsed() {
        let settings = [
            "IDECustomDerivedDataLocation": "/Volumes/Fast/DerivedData",
            "IDECustomDistributionArchivesLocation": "~/Archives",
        ]

        let locations = XcodeLocations(xcodeRootURL: xcodeRoot, settings: settings)

        #expect(locations.derivedDataURL.path == "/Volumes/Fast/DerivedData")
        #expect(locations.archivesURL.path == NSString("~/Archives").expandingTildeInPath)
    }

    /// A workspace-relative location puts DerivedData beside each workspace, so there is no one folder to scan.
    @Test("A relative or empty custom location falls back to the Xcode folder")
    func relativeCustomLocationFallsBack() {
        let settings = ["IDECustomDerivedDataLocation": "DerivedData", "IDECustomDistributionArchivesLocation": ""]

        let locations = XcodeLocations(xcodeRootURL: xcodeRoot, settings: settings)

        #expect(locations.derivedDataURL.path == "/Users/test/Library/Developer/Xcode/DerivedData")
        #expect(locations.archivesURL.path == "/Users/test/Library/Developer/Xcode/Archives")
    }

    @Test("A scan reads DerivedData and Archives from their custom locations")
    func scanUsesCustomLocations() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let movedFixture = try TempXcodeFixture()
        defer { movedFixture.cleanup() }
        // Build the custom folders with the fixture helpers, then point the locations at them.
        _ = try movedFixture.addDerivedData(folderName: "Moved-abcdefghijklmnopqrstuvwxyzab", workspacePath: nil, lastAccessed: now)
        try movedFixture.addArchive(
            dateFolder: "2026-08-01", archiveName: "Moved 8-1-26", appName: "MovedApp",
            shortVersion: "1.0", buildVersion: "1", bundleID: "com.example.moved", creationDate: now
        )
        _ = try fixture.addDerivedData(folderName: "Default-abcdefghijklmnopqrstuvwxyzab", workspacePath: nil, lastAccessed: now)
        let storage = XcodeStorage(
            xcodeLocations: XcodeLocations(
                xcodeRootURL: fixture.xcodeRootURL,
                derivedDataURL: movedFixture.xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true),
                archivesURL: movedFixture.xcodeRootURL.appendingPathComponent("Archives", isDirectory: true)
            ),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)

        #expect(snapshot.itemsByCategory[.derivedData]?.map(\.name) == ["Moved"])
        #expect(snapshot.itemsByCategory[.archivesAndCaches]?.map(\.name) == ["MovedApp"])
    }


    /// A custom DerivedData folder may also hold a repository or other folders; only Xcode's own
    /// artifacts there may be offered for cleanup.
    @Test("In a custom DerivedData folder, only Xcode's artifacts can be deleted")
    func customDerivedDataProtectsUnrecognizedFolders() async throws {
        let fixture = try TempXcodeFixture()
        defer { fixture.cleanup() }
        let now = testISO8601Date("2026-11-21T10:00:00Z")
        let custom = fixture.rootURL.appendingPathComponent("CustomDerivedData", isDirectory: true)
        let project = custom.appendingPathComponent("App-abcdefghijklmnopqrstuvwxyzab", isDirectory: true)
        let recorded = custom.appendingPathComponent("Recorded", isDirectory: true)
        let moduleCache = custom.appendingPathComponent("ModuleCache.noindex", isDirectory: true)
        let repository = custom.appendingPathComponent("MyRepo", isDirectory: true)
        let unrelated = custom.appendingPathComponent("Notes", isDirectory: true)
        for folder in [project, recorded, moduleCache, repository, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: folder.appendingPathComponent("file.bin"))
        }
        let xcodePlist: [String: Any] = ["WorkspacePath": "/nonexistent/Recorded.xcodeproj", "LastAccessedDate": now]
        try PropertyListSerialization.data(fromPropertyList: xcodePlist, format: .xml, options: 0)
            .write(to: recorded.appendingPathComponent("info.plist"))
        // An app's Info.plist, which a case-insensitive volume also finds as info.plist.
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.repo"], format: .xml, options: 0)
            .write(to: repository.appendingPathComponent("Info.plist"))
        let storage = XcodeStorage(
            xcodeLocations: XcodeLocations(xcodeRootURL: fixture.xcodeRootURL, derivedDataURL: custom),
            commandRunner: StubCommandRunner(),
            fileTrasher: RecordingFileTrasher(),
            now: { now }
        )

        let snapshot = try await finalScanSnapshot(from: storage)
        let everything = snapshot.itemsByCategory.values.flatMap(\.self)
        let plan = DeletionPlan(selection: everything)

        let deletablePaths = Set(plan.deletableItems.compactMap(\.path).map(\.standardizedFileURL.path))
        #expect(deletablePaths == Set([project, recorded, moduleCache].map(\.standardizedFileURL.path)))
        #expect(everything.contains { $0.path?.standardizedFileURL == repository.standardizedFileURL && !$0.isDeletable })
        #expect(everything.contains { $0.path?.standardizedFileURL == unrelated.standardizedFileURL && !$0.isDeletable })
    }
}
