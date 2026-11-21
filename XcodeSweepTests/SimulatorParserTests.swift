import Foundation
import Testing
@testable import XcodeSweep

@Suite("SimulatorScanner JSON Parsing")
struct SimulatorParserTests {
    @Test("Decodes simctl runtime list JSON with size, build, deletable flag, and lastUsedAt")
    func decodesRuntimes() throws {
        let json = """
        {
          "2D298A53-55CE-4471-8D0C-3B22FBDDA23A": {
            "build": "24B114",
            "deletable": true,
            "identifier": "2D298A53-55CE-4471-8D0C-3B22FBDDA23A",
            "kind": "Patchable Cryptex Disk Image",
            "lastUsedAt": "2026-08-01T09:27:36Z",
            "path": "/System/Library/AssetsV2/iOS27.2",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            "sizeBytes": 8311163745,
            "state": "Ready",
            "version": "27.2"
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

        let referenceNow = try #require(SimulatorScanner.parseISO8601("2026-11-21T10:00:00Z"))
        let items = try SimulatorScanner.decodeRuntimes(from: Data(json.utf8), now: referenceNow)

        #expect(items.count == 2)

        let ios = try #require(items.first)
        #expect(ios.name == "iOS 27.2")
        #expect(ios.sizeBytes == 8_311_163_745)
        #expect(ios.status == .stale)
        #expect(ios.isDeletable)
        #expect(ios.deletionMethod == .simctlRuntime(identifier: "2D298A53-55CE-4471-8D0C-3B22FBDDA23A"))

        let watch = try #require(items.last)
        #expect(watch.name == "watchOS 12.0")
        #expect(watch.status == .systemManaged)
        #expect(!watch.isDeletable)
    }

    @Test("Decodes simctl list devices JSON and flags unavailable and booted devices")
    func decodesDevices() throws {
        let json = """
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
              }
            ]
          }
        }
        """

        let referenceNow = try #require(SimulatorScanner.parseISO8601("2026-11-21T10:00:00Z"))
        let items = try SimulatorScanner.decodeDevices(from: Data(json.utf8), now: referenceNow)

        #expect(items.count == 2)

        let booted = try #require(items.first)
        #expect(booted.name == "iPhone 17 Pro")
        #expect(booted.sizeBytes == 4_000_500_000)
        #expect(booted.status == .booted)
        #expect(booted.deletionMethod == .simctlDevice(udid: "AAA", isBooted: true))

        let unavailable = try #require(items.last)
        #expect(unavailable.name == "iPhone 15")
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.isReclaimableCandidate)
        #expect(unavailable.deletionMethod == .simctlDevice(udid: "BBB", isBooted: false))
    }
}
