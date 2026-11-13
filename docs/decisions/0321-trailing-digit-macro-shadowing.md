# 0321. A trailing digit shadows a macro like trailing punctuation

- Status: accepted, 2026-11-13
- Requirements: ENG-R1103, PRD-R29, PRD-R31, PLT-R1005
- Context: the product owner decided on 13/11/2026 (review section of [0005](0005-pa-decisions-2026-11-13.md)) that
  macro shortcuts that differ only by a trailing main-row digit are treated like shortcuts that differ by trailing
  punctuation. Until then the editor only warned about such a pair in Telex and accepted it silently in VNI, so every
  earlier build could save a pair like `k` and `k1`. Workstream W5-B.

## Decision

1. **One rule on both sides.** The engine's `MacroTable` validation throws `shadowedByShorterTrigger` for a trigger
   that is a shorter trigger plus a digit, and the editor's mirror (`SettingsStore.MacroValidator`) refuses the same
   pair in both directions, for every typing method. Agreement tests on both sides pin the documented pairs
   (`MacroTests.trailingDigitShadowsLikePunctuation_ENGR1103`, `MacroEngineAgreementTests`).
2. **No warning level.** The non-blocking Telex digit warning of the editor is removed; the pair is a blocking
   `shadowedBy` or `shadows` problem with the same text as punctuation ("dấu câu hoặc chữ số").

## Upgrade path for pairs saved by an earlier build

- `macros.json` keeps loading unchanged (PLT-R1005): nothing is rewritten or deleted on upgrade.
- At the next publication the engine bridge skips the longer trigger (`k1`) and reports it per macro ID; the shorter
  one keeps working.
- The Macros pane flags both rows (`MacroListState.rowIssues`: `shadows` on `k`, `shadowedBy` on `k1`).
- Saving any macro while such a pair is in the list is refused with the engine's message naming the row to fix
  ("k1" ...), because the editor never saves a table the engine rejects. Deleting or renaming one of the pair
  unblocks saving. Pinned by `MacroEditorTests.aPairSavedBeforeTheDigitRuleStillLoadsAndNamesTheRowToFix_ENGR1103`.
- The release notes of the version that ships this change mention it as a behaviour change (requested from the
  documentation workstream).

## Alternatives considered

- **Save an unrelated macro while an old pair remains, as long as the save adds no new engine problem.** Rejected
  for now: `MacroTable` reports only the first problem, so a new problem could hide behind the old one, and the rule
  "never save a table the engine rejects" would need an exception. The block names the row and is lifted by one
  delete.
- **Rename `k1` automatically on upgrade.** Rejected: it would change user data without consent.
