import Foundation
import Testing
@testable import XcodeSweep

@Suite("Xcode locations")
struct XcodeLocationsTests {
    private let xcodeRoot = URL(filePath: "/Users/test/Library/Developer/Xcode", directoryHint: .isDirectory)

    @Test("Without custom locations, DerivedData and Archives sit in the Xcode folder")
    func defaultsSitInXcodeFolder() throws {
        let locations = try XcodeLocations(xcodeRootURL: xcodeRoot, settings: emptySettings())

        #expect(locations.derivedDataURL.path == "/Users/test/Library/Developer/Xcode/DerivedData")
        #expect(locations.archivesURL.path == "/Users/test/Library/Developer/Xcode/Archives")
    }

    /// To replicate: Xcode Settings → Locations → set DerivedData and Archives to Custom → scan.
    @Test("Absolute custom locations from Xcode's settings are used")
    func absoluteCustomLocationsAreUsed() throws {
        let settings = try emptySettings()
        settings.set("/Volumes/Fast/DerivedData", forKey: "IDECustomDerivedDataLocation")
        settings.set("~/Archives", forKey: "IDECustomDistributionArchivesLocation")

        let locations = XcodeLocations(xcodeRootURL: xcodeRoot, settings: settings)

        #expect(locations.derivedDataURL.path == "/Volumes/Fast/DerivedData")
        #expect(locations.archivesURL.path == NSString("~/Archives").expandingTildeInPath)
    }

    /// A workspace-relative location puts DerivedData beside each workspace, so there is no one folder to scan.
    @Test("A relative or empty custom location falls back to the Xcode folder")
    func relativeCustomLocationFallsBack() throws {
        let settings = try emptySettings()
        settings.set("DerivedData", forKey: "IDECustomDerivedDataLocation")
        settings.set("", forKey: "IDECustomDistributionArchivesLocation")

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
            locations: XcodeLocations(
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

    private func emptySettings() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "XcodeSweepTests-\(UUID().uuidString)"))
    }
}
