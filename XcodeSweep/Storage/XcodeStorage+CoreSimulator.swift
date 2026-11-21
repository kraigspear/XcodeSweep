import Foundation

extension XcodeStorage {
    // MARK: - Scanning

    func scanSimulatorRuntimes(now: Date) async throws -> [StorageItem] {
        let output = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl", "runtime", "list", "-j"]
        )
        return try Self.decodeRuntimes(
            from: output.stdout,
            now: now,
            thresholdDays: StalenessPolicy.simulatorRuntimesDays
        )
    }

    func scanSimulatorDevices(now: Date) async throws -> [StorageItem] {
        let output = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl", "list", "devices", "-j"]
        )
        return try Self.decodeDevices(
            from: output.stdout,
            now: now,
            thresholdDays: StalenessPolicy.simulatorDevicesDays
        )
    }

    // MARK: - Deletion

    func deleteSimulatorDevice(udid: String, isBooted: Bool) async throws {
        if isBooted {
            do {
                _ = try await commandRunner.run(
                    executableURL: Self.xcrunURL,
                    arguments: ["simctl", "shutdown", udid]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Best-effort shutdown: proceed to delete even if simulator is already shut down.
            }
            try Task.checkCancellation()
        }
        _ = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl", "delete", udid]
        )
    }

    func deleteSimulatorRuntime(identifier: String) async throws {
        _ = try await commandRunner.run(
            executableURL: Self.xcrunURL,
            arguments: ["simctl", "runtime", "delete", identifier]
        )
    }

    // MARK: - Shared Formatting

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

    private static func decodeRuntimes(
        from data: Data,
        now: Date,
        thresholdDays: Int
    ) throws -> [StorageItem] {
        let rawMap = try JSONDecoder().decode([String: SimRuntimeRecord].self, from: data)
        let staleThreshold = StalenessPolicy.threshold(days: thresholdDays)

        return rawMap.values.map { record in
            let platformName = readablePlatform(
                from: record.platformIdentifier,
                runtimeIdentifier: record.runtimeIdentifier
            )
            let lastUsedDate = record.lastUsedAt.flatMap(parseISO8601)
            let isDeletable = record.deletable ?? true

            let status: ItemStatus
            if !isDeletable {
                status = .systemManaged
            } else if let lastUsedDate, now.timeIntervalSince(lastUsedDate) > staleThreshold {
                status = .stale
            } else {
                status = .active
            }

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
        now: Date,
        thresholdDays: Int
    ) throws -> [StorageItem] {
        let payload = try JSONDecoder().decode(SimDeviceListPayload.self, from: data)
        let staleThreshold = StalenessPolicy.threshold(days: thresholdDays)
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
                } else if let lastUsedDate, now.timeIntervalSince(lastUsedDate) > staleThreshold {
                    status = .stale
                } else {
                    status = .active
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
                        id: "simDevice:\(device.udid)",
                        category: .simulatorDevices,
                        name: device.name,
                        subtitle: subtitleParts.joined(separator: " • "),
                        sizeBytes: totalSize,
                        lastUsedDate: lastUsedDate,
                        path: deviceURL,
                        workspacePath: nil,
                        status: status,
                        deletionMethod: .simctlDevice(udid: device.udid, isBooted: isBooted),
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
