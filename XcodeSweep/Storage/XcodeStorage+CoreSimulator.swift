import Foundation

extension XcodeStorage {
    /// Timeout for read-only `simctl` list commands; deletions run without a timeout so a slow
    /// removal isn't aborted while it may still take effect (the user can cancel instead).
    static let simctlListTimeout: Duration = .seconds(60)

    // MARK: - Scanning

    func scanSimulatorRuntimes(now: Date) async throws -> [StorageItem] {
        let output = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl", "runtime", "list", "-j"],
            timeout: Self.simctlListTimeout
        )
        return try Self.decodeRuntimes(from: output.stdout, now: now)
    }

    func scanSimulatorDevices(now: Date) async throws -> [StorageItem] {
        try await listSimulatorDevices(in: .standard, now: now)
    }

    /// The devices registered in `deviceSet`, as items of the category that shows that set.
    func listSimulatorDevices(in deviceSet: SimulatorDeviceSet, now: Date) async throws -> [StorageItem] {
        let output = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl"] + deviceSet.simctlArguments + ["list", "devices", "-j"],
            timeout: Self.simctlListTimeout
        )
        return try Self.decodeDevices(from: output.stdout, in: deviceSet, now: now)
    }

    // MARK: - Deletion

    /// Permanently deletes a simulator device, trying to shut it down first.
    ///
    /// Tries every device rather than those booted at scan time: one may have booted since. A failed
    /// shutdown doesn't stop the delete, which reports its own error if the device can't go.
    func deleteSimulatorDevice(udid: String, in deviceSet: SimulatorDeviceSet) async throws {
        let simctl = ["simctl"] + deviceSet.simctlArguments
        do {
            _ = try await commandRunner.run(
                executableURL: Self.xcrunURL,
                arguments: simctl + ["shutdown", udid],
                timeout: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fails when the device is already shut down; delete reports any real problem.
        }
        // `removing` checks cancellation first, so a stop during shutdown skips the delete.
        try await Self.removing {
            _ = try await commandRunner.run(
                executableURL: Self.xcrunURL,
                arguments: simctl + ["delete", udid],
                timeout: nil
            )
        }
    }

    func deleteSimulatorRuntime(identifier: String) async throws {
        try await Self.removing {
            _ = try await commandRunner.run(
                executableURL: Self.xcrunURL,
                arguments: ["simctl", "runtime", "delete", identifier],
                timeout: nil
            )
        }
    }

    // MARK: - Shared Formatting

    /// A display name for a runtime identifier: `com.apple.CoreSimulator.SimRuntime.iOS-18-2` becomes `iOS 18.2`.
    static func readableRuntimeName(from runtimeIdentifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        let stripped = runtimeIdentifier.hasPrefix(prefix)
            ? String(runtimeIdentifier.dropFirst(prefix.count))
            : runtimeIdentifier

        let parts = stripped.split(separator: "-")
        guard let platform = parts.first else {
            return stripped
        }
        let versionParts = parts.dropFirst()
        if versionParts.isEmpty {
            return String(platform)
        }
        return "\(platform) \(versionParts.joined(separator: "."))"
    }

    // MARK: - Private JSON Decoding

    private static func decodeRuntimes(from data: Data, now: Date) throws -> [StorageItem] {
        let rawMap = try JSONDecoder().decode([String: SimRuntimeRecord].self, from: data)

        return rawMap.values.map { record in
            let platformName = readablePlatform(
                from: record.platformIdentifier,
                runtimeIdentifier: record.runtimeIdentifier
            )
            let lastUsedDate = record.lastUsedAt.flatMap(parseISO8601)
            let isDeletable = record.deletable ?? true

            let status: ItemStatus = isDeletable
                ? StorageCategory.simulatorRuntimes.ageStatus(lastUsed: lastUsedDate, now: now)
                : .systemManaged

            let method: DeletionMethod = isDeletable
                ? .simctlRuntime(identifier: record.identifier)
                : .notDeletable(reason: "Managed by Xcode or macOS")

            var metadata: [MetadataEntry] = [
                MetadataEntry(key: "Identifier", value: record.identifier),
                MetadataEntry(key: "Platform", value: platformName),
                MetadataEntry(key: "Version", value: record.version),
                MetadataEntry(key: "Build", value: record.build),
                MetadataEntry(key: "State", value: record.state),
            ]
            if let kind = record.kind {
                metadata.append(MetadataEntry(key: "Kind", value: kind))
            }
            if let path = record.path {
                metadata.append(MetadataEntry(key: "Image Path", value: path))
            }

            return StorageItem(
                id: "simRuntime:\(record.identifier)",
                category: .simulatorRuntimes,
                name: "\(platformName) \(record.version)",
                subtitle: "Build \(record.build) • \(record.kind ?? record.state)",
                sizeBytes: record.sizeBytes,
                lastUsedDate: lastUsedDate,
                path: record.path.map { URL(fileURLWithPath: $0) },
                workspacePath: nil,
                status: status,
                deletionMethod: method,
                metadata: metadata
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func decodeDevices(
        from data: Data,
        in deviceSet: SimulatorDeviceSet,
        now: Date
    ) throws -> [StorageItem] {
        let category: StorageCategory = deviceSet == .previews ? .previews : .simulatorDevices
        let payload = try JSONDecoder().decode(SimDeviceListPayload.self, from: data)
        var items: [StorageItem] = []

        for (runtimeKey, devices) in payload.devices {
            let runtimeLabel = readableRuntimeName(from: runtimeKey)

            for device in devices {
                let dataSize = device.dataPathSize ?? 0
                let logSize = device.logPathSize ?? 0
                let totalSize = dataSize + logSize
                let lastUsedDate = device.lastUsedAt.flatMap(parseISO8601)
                let isBooted = device.state.caseInsensitiveCompare("Booted") == .orderedSame

                let status: ItemStatus
                if !device.isAvailable {
                    status = .unavailable
                } else if isBooted {
                    status = .booted
                } else {
                    status = category.ageStatus(lastUsed: lastUsedDate, now: now)
                }

                let deviceURL = device.dataPath.map {
                    URL(fileURLWithPath: $0).deletingLastPathComponent()
                }

                var subtitleParts = [runtimeLabel, device.state]
                if let availabilityError = device.availabilityError, !availabilityError.isEmpty {
                    subtitleParts.append(availabilityError)
                }

                var metadata: [MetadataEntry] = [
                    MetadataEntry(key: "UDID", value: device.udid),
                    MetadataEntry(key: "Runtime", value: runtimeLabel),
                    MetadataEntry(key: "State", value: device.state),
                    MetadataEntry(key: "Available", value: device.isAvailable ? "Yes" : "No"),
                    MetadataEntry(
                        key: "Data Size",
                        value: ByteCountFormatter.string(fromByteCount: dataSize, countStyle: .file)
                    ),
                    MetadataEntry(
                        key: "Log Size",
                        value: ByteCountFormatter.string(fromByteCount: logSize, countStyle: .file)
                    ),
                ]
                if let dataPath = device.dataPath {
                    metadata.append(MetadataEntry(key: "Data Path", value: dataPath))
                }
                if let availabilityError = device.availabilityError, !availabilityError.isEmpty {
                    metadata.append(MetadataEntry(key: "Availability Error", value: availabilityError))
                }

                items.append(
                    StorageItem(
                        id: deviceSet == .previews ? "previewDevice:\(device.udid)" : "simDevice:\(device.udid)",
                        category: category,
                        name: device.name,
                        subtitle: subtitleParts.joined(separator: " • "),
                        sizeBytes: totalSize,
                        lastUsedDate: lastUsedDate,
                        path: deviceURL,
                        workspacePath: nil,
                        status: status,
                        deletionMethod: .simctlDevice(udid: device.udid, deviceSet: deviceSet),
                        metadata: metadata
                    )
                )
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func readablePlatform(from platformIdentifier: String?, runtimeIdentifier: String?) -> String {
        let source = (platformIdentifier ?? runtimeIdentifier ?? "").lowercased()
        if source.contains("iphone") || source.contains("ios") {
            return "iOS"
        }
        if source.contains("watch") {
            return "watchOS"
        }
        if source.contains("appletv") || source.contains("tvos") {
            return "tvOS"
        }
        if source.contains("xr") || source.contains("vision") {
            return "visionOS"
        }
        return "Simulator"
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}

// MARK: - Decoding DTOs

private struct SimRuntimeRecord: Decodable {
    let identifier: String
    let version: String
    let build: String
    let platformIdentifier: String?
    let runtimeIdentifier: String?
    let sizeBytes: Int64
    let state: String
    let kind: String?
    let deletable: Bool?
    let lastUsedAt: String?
    let path: String?
}

private struct SimDeviceListPayload: Decodable {
    let devices: [String: [SimDeviceRecord]]
}

private struct SimDeviceRecord: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let availabilityError: String?
    let dataPath: String?
    let dataPathSize: Int64?
    let logPathSize: Int64?
    let lastUsedAt: String?
}
