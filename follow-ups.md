# Follow-ups

Non-blocking findings recorded during review. None of these block the change that surfaced them.

## FU-005: Decide whether a runner's own CancellationError should hide a category

- **Source:** Codex review of PR #55 (COMPAT-1), `XcodeSweep/Storage/XcodeStorage.swift` `CategoryScan.catchingFailure`.
- **Issue:** a `CommandRunning` that throws `CancellationError` while the scan isn't cancelled now yields an empty, successful Devices or Runtimes category; before PR #55 that category was left out of the events and snapshot. The live `ProcessRunner` throws it only on task cancellation, so only an injected runner can tell.
- **Fix:** if independently cancelled commands become supported, keep such a category out of the scan and pin it with a test; otherwise nothing to do.

## FU-004: Append deletion failures without copying the list each time

- **Source:** Codex review of PR #54 (PERF-1), `XcodeSweep/Deletion/DeletionPlan.swift` `recordingFailure(_:)`.
- **Issue:** each recorded failure builds `failures + [failure]`, so a batch where every item fails copies a growing list per item (quadratic in the failure count). Before PR #54 the stream appended to its own array.
- **Fix:** profile a large all-failure batch first; only if it lags, accumulate failures more cheaply while keeping each progress's report a correct snapshot.

## FU-003: Skip the rebuild when a scan starts with no failures

- **Source:** Codex review of PR #52 (PERF-1), `XcodeSweep/Inventory/StorageInventory.swift` `clearingFailures()`.
- **Issue:** `clearingFailures()` rebuilds the inventory (totals and item-ID index) on the main actor even when there are no failures to clear; before PR #52 a scan start only reset a dictionary.
- **Fix:** return `self` when `scanFailures` is empty. Unmeasured; only worth doing if a large inventory shows lag on ⌘R.
