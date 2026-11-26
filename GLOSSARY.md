# XcodeSweep

A macOS utility for inspecting and safely reclaiming local Xcode build artifacts, caches, and CoreSimulator storage.

## Language

**XcodeStorage**:
The local Xcode and CoreSimulator storage locations on disk that XcodeSweep inspects and cleans, including DerivedData, Simulator devices and runtimes, DeviceSupport symbols, SwiftUI Previews, Archives, and build caches.
_Avoid_: StorageService, LiveStorageService, StorageManager, StorageEngine

**StorageInventory**:
The scanned items in every category, the totals derived from them, and each category's scan failure. Changing the items always produces a new inventory, so totals never disagree with the items, and failures are kept, replaced, or restored along with them.
_Avoid_: ScanSummary, summary, scanFailures (as separate state)

**Browsing**:
Where the user is and what they've narrowed to: destination, search, filter, sort, and selection. Moving to a new destination clears the selection, filter, and search; sort order persists.
_Avoid_: UI state, navigation state, view model

**Reclaimable**:
An item that is deletable and has a reclaimable status: orphaned, unavailable, or unused. The UI labels this "Recommended".
_Avoid_: recommended, cleanup candidate (in code; "Recommended" is UI text only); cleanable (anywhere)

**Protected**:
A selected item that cannot be deleted, such as a system-managed simulator runtime. A deletion plan counts protected items but never deletes them.
_Avoid_: non-deletable, locked
