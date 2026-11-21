import Foundation

/// Top-level storage categories managed by XcodeSweep.
enum StorageCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case derivedData
    case simulatorDevices
    case simulatorRuntimes
    case deviceSupport
    case previews
    case archivesAndCaches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .derivedData:
            "DerivedData"
        case .simulatorDevices:
            "Simulator Devices"
        case .simulatorRuntimes:
            "Simulator Runtimes"
        case .deviceSupport:
            "Device Support"
        case .previews:
            "SwiftUI Previews"
        case .archivesAndCaches:
            "Archives & Caches"
        }
    }

    var systemImage: String {
        switch self {
        case .derivedData:
            "hammer"
        case .simulatorDevices:
            "iphone.gen3"
        case .simulatorRuntimes:
            "opticaldiscdrive"
        case .deviceSupport:
            "cpu"
        case .previews:
            "rectangle.on.rectangle"
        case .archivesAndCaches:
            "archivebox"
        }
    }

    var summaryDescription: String {
        switch self {
        case .derivedData:
            "Per-project and per-worktree build artifacts in ~/Library/Developer/Xcode/DerivedData."
        case .simulatorDevices:
            "Simulator data containers in ~/Library/Developer/CoreSimulator/Devices."
        case .simulatorRuntimes:
            "Installed simulator runtime disk images managed by CoreSimulator."
        case .deviceSupport:
            "Debug symbols cached from physical iOS, watchOS, tvOS, and visionOS devices."
        case .previews:
            "Xcode SwiftUI Preview simulator devices in UserData/Previews."
        case .archivesAndCaches:
            "Xcode .xcarchive builds and DerivedData ModuleCache.noindex."
        }
    }
}

/// Sidebar navigation destination.
enum SidebarSelection: Hashable, Identifiable, Sendable {
    case overview
    case category(StorageCategory)

    var id: String {
        switch self {
        case .overview:
            "overview"
        case let .category(category):
            category.rawValue
        }
    }
}
