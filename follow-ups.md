# Follow-ups

Non-blocking findings recorded during review. None of these block the change that surfaced them.

## FU-001 — Unused explanation reads oddly on the first day past the limit

- **Severity**: FOLLOW-UP
- **Target**: PR #47 (`explain-item-status`), head `28857ee`, snapshot tree `f8db940`
- **Source**: `XcodeSweep/Inventory/StorageCategory.swift:95`
- **Issue**: Elapsed days are truncated, so an item 30 days and one second past its last use reads
  "Last used 30 days ago, past the 30-day limit for DerivedData." The status is correct; the
  sentence looks self-contradictory for one day.
- **Next action**: For that interval say "Last used more than 30 days ago", and assert the sentence
  in the existing boundary test.
- **Why it does not block**: The status and recommendation are right, and the wording is merely
  awkward for a 24-hour window.
- **Raised by**: Codex (gpt-6.2-astra), finding AGE-1.

## FU-002 — Tooltips and the "Recommended:" prefix are verified from source only

- **Severity**: FOLLOW-UP
- **Target**: PR #47 (`explain-item-status`), head `28857ee`, snapshot tree `f8db940`
- **Source**: `XcodeSweep/Inventory/CategoryDetailView.swift:64`,
  `XcodeSweep/Inventory/CategoryDetailView.swift:247`,
  `XcodeSweep/Inventory/StorageItemInspectorView.swift:57`
- **Issue**: The inspector line was seen in the running app for three items that are not
  recommended. The status-badge tooltip, the Select Recommended tooltip, and the "Recommended:"
  prefix were never observed, and no test fails if either `.help` modifier or the prefix is removed.
- **Next action**: Open a reclaimable row (the preview inventory has several) and check the prefix,
  then hover a status badge and Select Recommended.
- **Why it does not block**: Each is a one-line standard SwiftUI modifier or string prefix over
  tested model text, and nothing depends on it.
- **Raised by**: Codex (gpt-6.2-astra), finding UI-1.
