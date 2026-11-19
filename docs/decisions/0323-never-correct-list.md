# 0323. The never-correct list and the typo correction switch in the host

- Status: accepted, 2026-11-19
- Requirements: ENG-R1115, ENG-R1117, ENG-R1118, ENG-R1119, ENG-R1121, PRD-R4A, PRD-R6, PRD-R26, PRD-R27, PRD-R45,
  PRD-R72, PRD-R80, PRD-R81, PLT-R304, PLT-R305, PLT-R353, PLT-R901, PLT-R904A, PLT-R1002, PLT-R1005, PLT-R1010,
  PLT-R1202
- Context: {{AppName}} 1.1.0 corrects one clearly mistyped English word at its commit (`01-engine.md` section 11A,
  on by default by the decision of the product owner of 18/11/2026, [0009](0009-pa-decisions-2026-11-18.md) item 10).
  The engine decides the correction; the host owns the user's switch D30, the never-correct list the restore key
  teaches, the inputs of the switch and what diagnostics may say about them. The engine's data and rules are
  ADR 0203 and section 11A; the copy and the Typing pane are PRD-R80 and PRD-R81. This record
  covers the store and the host (plan of 19/11/2026, track A1).

## Decision

1. **Storage next to the keep lists, schema version 1.** D30 is `settings.typoCorrection` in `settings.json`; absent
   is unset, so the shipped default (on) applies and can change later (PRD-R6). The list is
   `englishRestoreLists.neverCorrect`, a sorted array of entries that `NeverCorrectEntry` accepts: lowercase ASCII
   letters, 1 to 64 of them (the engine compares the lowercased typed word, which is ASCII letters only, ENG-R1111).
   An entry it refuses is dropped on load, left out of the next rewrite and listed by position among the skipped
   fields of an import (PLT-R1010). No migration step: a file written by 1.0.x reads as D30 at its default and an
   empty list, and a 1.0.x build keeps both keys through its rewrites, because they sit inside the `settings` and
   `englishRestoreLists` objects whose unknown keys every build keeps (PLT-R1002). `MigrationChain.shipped` records
   this; `NeverCorrectListStoreTests` loads the released v1 fixture.
2. **One signal is enough, per user, in every app.** The restore toggle that undoes a correction carries
   `LearningSignal.neverCorrect(raw)` (ENG-R1117). The pipeline now forwards a toggle's learning signal to main as it
   forwards a commit's (`KeyPipeline` `restoreLastWord`; the 1.0 engine never put one on a toggle, so nothing else
   changes). `InputHostController.noteLearning` adds the word to the list at once through
   `UserSettings.neverCorrect(_:)`, with or without a known app, and never hands it to the per-app
   `LearningTracker`, which counts two signals per app for the keep lists (ENG-R862). Nothing is shown when a word is
   corrected or taken back (PRD-R80, principle 3). The word is content: it goes to the settings store only, never to a
   log (PLT-R901).
3. **Resets, export and import.** The Typing pane reset and the full reset clear the list with the keep lists
   (PRD-R26); the other panes leave it. The list travels in the `settings` section of an export, so it has no
   checkbox of its own (PRD-R72, PRD-R81), and the import summary names `neverCorrect` when it would change. An
   export written by 1.0.x has no list: imported into a store at the defaults it changes nothing for it; imported
   into a store that has a list, it replaces the settings as it replaces the keep lists, the summary names the list,
   and the files are backed up first (PLT-R1010).
4. **The switch, one conjunction.** `EngineSettingsMapping.typoCorrection(_:variant:)` is D30 AND D4 AND the rule's
   `features.englishRestore` AND the rule's `features.restoreHotkey` AND D8 on (any binding), so no word is corrected
   where the restore key cannot undo it: Spotlight and the overlay panels, whose rules turn the key off, every app
   while D8 is off, and every app while D4 is off (ENG-R1119, PRD-R80).
5. **Thirty-two prebuilt engines.** The rule's `restoreHotkey` is bit 4 of the catalog index (`EngineVariant`), next
   to the code context, English restore, macros and revisions, so the catalog holds 32 engines, each looked up by an
   array index on the tap (PLT-R304). They are built from one `Resources` value, so the bundled data, the correction
   data of ADR 0203 among it, is held once (`EngineCatalogTests` pins the shared storage of
   the guard filter). Before this, a variant without the restore key shared the slot of the one with it and a catalog
   built for it handed out its fallback engine.
6. **Engine inputs and revisions.** D30, D8's on or off state and the list are `EngineInputs`: a change rebuilds the
   catalog and bumps its revision, so no engine keeps correcting after D30 or D8 is turned off. Rebinding D8 to
   another key is not an engine input and keeps the revision and the word being typed (PRD-R27). The list is the same
   in every app (`UserSettings.neverCorrect`), so a focus change, which republishes only when the focused app's keep
   lists differ (ENG-R862), never republishes for it; the engines get it as `Resources.userNeverCorrect` from both
   `EngineBridge.resources` entry points.
7. **Replay follows the host.** The dev recorder writes D30 in the settings line and the rule's restore key in the
   focus line (`rhk`, optional, so the trace format version stays). `ReplayEngineFactory.typoCorrection` rebuilds the
   same conjunction from the recorded inputs; a trace without D30 replays with the switch off, as engines without the
   correction ran it. `ReplayTypoCorrectionTests` pins replay against the host mapping for all 32 combinations,
   recorded as the recorder writes them. The engine identity of the traces digests four worked examples of 13.12 with
   the switch on, so a build whose correction differs gets another identity (ADR 0007 decision 13).
8. **Counts, never words.** `HostCounters` counts corrected commits and corrections taken back on the tap thread
   with relaxed atomics (no lock, no allocation, PLT-R305). The diagnostics report shows D30 as a non-content setting
   (PLT-R1202), the list as its entry count and the two counters (`settings.typoCorrection`,
   `settings.neverCorrectEntries`, `counters.corrections`, `counters.correctionUndos` in the copied block, added
   within format v1 under rule 4 of [0501](0501-diagnostics-block-format.md)); the integration hooks' state carries
   the counters next to the tap recoveries, optional on the wire so a newer harness reads an older build. No word of
   the list reaches a report, a hook answer or a log (PRD-R45, ENG-R1121).

## Alternatives considered

- **A per-app list, like the learned keep-list words.** Rejected: ENG-R1118 makes the list per user across apps, and
  a correction taken back in one app would come back in the next.
- **Two signals before learning, as for the keep lists.** Rejected: the user acted against a change they saw; one
  signal is enough (ENG-R1118).
- **A new compat rule flag for the correction.** Rejected: ENG-R1119 needs none; the code context and the restore key
  already decide where it runs, and the rule's `restoreHotkey` reaches the engine as a variant bit.
- **D8's binding as an engine input.** Rejected: rebinding the key would reset the word being typed (PRD-R27); only
  its on or off state changes what the engines do.
- **Schema version 2 for `settings.json`.** Rejected: every older build would open the file read-only (PLT-R1007)
  for two optional keys it already keeps unread.

## Consequences

- The report's counters reach the report through `ReportSections.counters`; `ReportAssembler.report` passes it to the
  report (one argument of the report initialiser), until then the counters section is absent and its block keys are
  empty.
- The trace field `rhk` and the settings value `typoCorrection` join the documented trace format
  (`docs/runbooks/dev-recorder.md`).
