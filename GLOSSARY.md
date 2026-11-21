# XcodeSweep

A macOS utility for inspecting and safely reclaiming local Xcode build artifacts, caches, and CoreSimulator storage.

## Language

**XcodeStorage**:
The local Xcode and CoreSimulator storage locations on disk that XcodeSweep inspects and cleans, including DerivedData, Simulator devices and runtimes, DeviceSupport symbols, SwiftUI Previews, Archives, and build caches.
_Avoid_: StorageService, LiveStorageService, StorageManager, StorageEngine
