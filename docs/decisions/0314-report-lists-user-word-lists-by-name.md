# 0314. The diagnostics report names the user word lists, never their entries

- Status: accepted, 2026-11-13
- Requirements: PRD-R6, PRD-R45, PLT-R901, PLT-R1202, PLT-R1203
- Context: the settings section of the diagnostics report lists which settings the user set explicitly
  (`DiagnosticsReport.SettingsSection.explicitlySetKeys`, PRD-R6). ShellCore first kept its own table of key
  names next to SettingsStore's; the wave 2a integration replaced it with `UserSettings.explicitlySetKeys`, and
  W1-B asked whether the three user lists belong in the report: `keepAsTyped` and `keepVietnamese` (ENG-R860)
  hold words the user chose, and `optedInRules` holds rule IDs that can name an app.

## Decision

1. The report's list is exactly `UserSettings.explicitlySetKeys`: the JSON names of the set `Setting` values in
   declaration order, then `keepAsTyped`, `keepVietnamese` and `optedInRules`, each only when non-empty.
   SettingsStore owns the names; ShellCore keeps no copy.
2. The three list names stay in the report. A name says only that the user customised that behaviour, which a
   maintainer needs to reproduce an English-restore or opt-in report; it carries no word and no rule ID.
3. The entries of those lists never reach the report, the issue block, the plain text or the log
   (PRD-R45, PLT-R901). `ReportAssemblerTests.explicitlySetKeysAreTheStoresNamesAndNeverListEntries_PRDR6_PLTR901`
   fills every setting and all three lists with canary values and checks the JSON, the issue block and the plain
   text in both languages.

## Consequences

- A new setting in `SettingFields` appears in the report as soon as it is set; the ShellCore test pins the
  expected order, so adding one is a visible, reviewed change.
- If a future list holds content that must not even be acknowledged, it needs its own decision before it is
  added to `explicitlySetKeys`.
