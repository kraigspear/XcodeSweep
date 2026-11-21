# XcodeSweep

A macOS utility for inspecting and safely reclaiming local Xcode build artifacts, caches, and CoreSimulator storage.

## Language

**XcodeStorage**:
The local Xcode and CoreSimulator storage locations on disk that XcodeSweep inspects and cleans, including DerivedData, Simulator devices and runtimes, DeviceSupport symbols, SwiftUI Previews, Archives, and build caches.
_Avoid_: StorageService, LiveStorageService, StorageManager, StorageEngine

**StorageInventory**:
The scanned items in every category together with the totals derived from them. Changing the items always produces a new inventory, so totals never disagree with the items.
_Avoid_: ScanSummary, summary
