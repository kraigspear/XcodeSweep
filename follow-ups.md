# Follow-ups

Non-blocking findings recorded during review. None of these block the change that surfaced them.

## FU-003: Skip the rebuild when a scan starts with no failures

- **Source:** Codex review of PR #52 (PERF-1), `XcodeSweep/Inventory/StorageInventory.swift` `clearingFailures()`.
- **Issue:** `clearingFailures()` rebuilds the inventory (totals and item-ID index) on the main actor even when there are no failures to clear; before PR #52 a scan start only reset a dictionary.
- **Fix:** return `self` when `scanFailures` is empty. Unmeasured; only worth doing if a large inventory shows lag on ⌘R.
