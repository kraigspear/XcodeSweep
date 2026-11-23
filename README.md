# XcodeSweep

A native macOS SwiftUI utility for inspecting and safely cleaning Xcode build and Simulator storage—especially orphaned `DerivedData` left behind by Git worktrees, oversized CoreSimulator devices, and unused Simulator runtime disk images.

![XcodeSweep Overview showing total Xcode storage, recommended cleanup, and storage by category](docs/screenshots/overview.png)

## What It Scans

- **DerivedData** (`~/Library/Developer/Xcode/DerivedData`) — project build folders, recognized by an `info.plist` or Xcode's `<Project>-<hash>` name. The `info.plist`'s workspace path identifies missing/orphaned workspaces, active Git worktrees, and unused projects; a hash-named folder without one is orphaned.
- **Simulator Devices** (`xcrun simctl list devices -j`) — shows allocated data + log size, runtime, boot state, and unavailable simulators.
- **Simulator Runtimes** (`xcrun simctl runtime list -j`) — lists installed iOS/watchOS/tvOS/visionOS disk images, build numbers, sizes, and last-used timestamps.
- **Device Support** (`~/Library/Developer/Xcode/* DeviceSupport`) — cached physical device symbols.
- **SwiftUI Previews** (`~/Library/Developer/Xcode/UserData/Previews/Simulator Devices`).
- **Archives & Caches** (`~/Library/Developer/Xcode/Archives`, plus the caches Xcode shares across projects in `DerivedData`, such as `ModuleCache.noindex` and `SDKExplicitPrecompiledModules`).

## Deletion Safety

- Filesystem items (`DerivedData`, `DeviceSupport`, `Previews`, `Archives`, shared caches) are moved to **Trash** (`FileManager.trashItem`) so deletions are reversible.
- Simulator devices and runtime disk images are removed through **`xcrun simctl`** after explicit confirmation (booted simulators are shut down first).
- App Sandbox is intentionally disabled (`com.apple.security.app-sandbox = false`) so the app can inspect `~/Library/Developer/` and invoke `/usr/bin/xcrun simctl`.

## Requirements

- macOS 15.0 or later
- Xcode 27 or later (project uses Xcode's native `project.xcproj` JSON format)

## Building & Testing

Build and test from the command line:

```bash
xcodebuild -project XcodeSweep.xcodeproj -scheme XcodeSweep -destination "platform=macOS" test
```

Open in Xcode:

```bash
open XcodeSweep.xcodeproj
```

## License

MIT License. See [LICENSE](LICENSE) for details.
