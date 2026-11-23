import Foundation

/// Where Xcode keeps the data XcodeSweep scans. DerivedData and archives default to the Xcode folder,
/// and Xcode's Locations settings can move each one elsewhere.
struct XcodeLocations: Equatable, Sendable {
    /// `~/Library/Developer/Xcode` for the real Xcode.
    let xcodeRootURL: URL
    let derivedDataURL: URL
    let archivesURL: URL

    /// Locations under `xcodeRootURL`, unless given.
    init(xcodeRootURL: URL, derivedDataURL: URL? = nil, archivesURL: URL? = nil) {
        self.xcodeRootURL = xcodeRootURL
        self.derivedDataURL = derivedDataURL ?? xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true)
        self.archivesURL = archivesURL ?? xcodeRootURL.appendingPathComponent("Archives", isDirectory: true)
    }

    /// Locations under `xcodeRootURL`, moved where `settings`, Xcode's preferences, say.
    ///
    /// Only an absolute custom location is used. A relative one puts DerivedData beside each
    /// workspace, which leaves no single folder to scan.
    init(xcodeRootURL: URL, settings: [String: Any]) {
        self.init(
            xcodeRootURL: xcodeRootURL,
            derivedDataURL: Self.customLocation(settings["IDECustomDerivedDataLocation"] as? String),
            archivesURL: Self.customLocation(settings["IDECustomDistributionArchivesLocation"] as? String)
        )
    }

    /// Whether DerivedData is somewhere other than its default in the Xcode folder; such a folder
    /// may hold things Xcode didn't create.
    var hasCustomDerivedData: Bool {
        derivedDataURL.standardizedFileURL.path
            != xcodeRootURL.appendingPathComponent("DerivedData", isDirectory: true).standardizedFileURL.path
    }

    /// The real Xcode folder, with the locations Xcode's settings choose.
    static func current() -> XcodeLocations {
        XcodeLocations(
            xcodeRootURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode", isDirectory: true),
            settings: UserDefaults(suiteName: "com.apple.dt.Xcode")?.dictionaryRepresentation() ?? [:]
        )
    }

    private static func customLocation(_ path: String?) -> URL? {
        guard let path else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
