# Follow-ups

Non-blocking findings recorded during review. None of these block the change that surfaced them.

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

## FU-003 — "Review N Recommended" truncates on the narrowest card with 100 or more recommended

- **Severity**: FOLLOW-UP
- **Target**: PR #48 (`rename-cleanable-to-recommended`), head `edd5334`, snapshot tree `eaa9ed4`
- **Source**: `XcodeSweep/Inventory/OverviewView.swift:246`
- **Issue**: At the Overview grid's 290-point minimum card width, 159 items with 130 recommended
  renders "Review 130 Recommend…". With 1,059 items and 999 recommended the button stays truncated
  at 300 points and is whole at 320. "Review N Cleanable" fit in each case.
- **Next action**: Let the card's footer reflow when its controls don't fit, and cover 159 items
  with 130 recommended at 290 points in `AppSceneTests`.
- **Why it does not block**: It needs 100 or more recommended items in one category and a card
  within 10 to 30 points of its minimum width, and the truncated label still shows the count and
  "Recommend…".
- **Raised by**: The coordinator's layout probe; graded by Codex (gpt-6.2-astra), finding UI-1.
