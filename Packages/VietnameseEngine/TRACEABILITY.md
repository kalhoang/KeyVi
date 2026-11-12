# Traceability: engine requirements to code and tests

Requirement IDs are from `spec/01-engine.md`. Paths are relative to this package (source paths under
`Sources/VietnameseEngine/`, test paths under `Tests/VietnameseEngineTests/`). Rows are added as the
commit and quality work lands.

| Requirement | Code | Tests |
|---|---|---|
| ENG-R102, ENG-R301 (146 precomposed letters, generated from Unicode data, ordered by code point) | `Scripts/generate-letter-table.py`, `Sources/VietnameseEngine/Generated/LetterTable.swift`, `Letters/LetterTableLookup.swift` | `Letters/LetterTableTests.swift` |
| 3.2 letters and modifiers | `Letters/Letter.swift` | `Letters/LetterTableTests.swift` (`LetterTests`) |
| 3.3 onsets (Tier A, Tier B clusters, `z`, `dz`), ENG-R316 | `Orthography/Onset.swift` | `Orthography/SyllableParserTests.swift`, `Orthography/ValidityTests.swift` |
| 3.7, 3.8, 3.9, 3.12 rhyme lists, ENG-R302, ENG-R303, ENG-R305 | `Orthography/RhymeInventory.swift` | `Orthography/SyllableCountTests.swift` |
| 3.4, 3.10, 3.11, 3.12 rules, ENG-R304 to ENG-R315, ENG-R320, ENG-R321, ENG-R330 | `Orthography/SyllableRules.swift`, `Orthography/Rhyme.swift`, `Orthography/SyllableTables.swift` | `Orthography/ValidityTests.swift`, `Orthography/SyllableCountTests.swift` |
| 3.13 parse, ENG-R340 | `Orthography/SyllableParser.swift` | `Orthography/SyllableParserTests.swift` |
| 3.14 viability, ENG-R345, ENG-R346 | `Orthography/ViabilityAutomaton.swift` | `Orthography/ViabilityTests.swift` |
| 3.15 counts, ENG-R350 | `Orthography/SyllableTables.swift` | `Orthography/SyllableCountTests.swift` (prints counts); `docs/decisions/0100-engine-syllable-counts.md` |
| 5.1, 5.2, ENG-R501, ENG-R502, ENG-R510, ENG-R511 | `Orthography/TonePlacement.swift` | `Orthography/TonePlacementTests.swift` |
| 5.5, ENG-R530 to ENG-R532 | `Orthography/HornNormalisation.swift` | `Orthography/HornNormalisationTests.swift` |
| ENG-R1212 `Orthography.analyze`, `validity(of:)` | `Orthography/Orthography.swift` | `Orthography/OrthographyAnalyzeTests.swift`, `Orthography/ValidityTests.swift` |
| ENG-T01 oracle | `Sources/VietnameseEngineTesting/Oracle/SyllableOracle.swift` | `Oracle/SyllableOracleTests.swift` |
| ENG-T02, ENG-T03, ENG-T04 generated corpus | `Sources/VietnameseEngineTesting/Oracle/KeySequenceGenerator.swift`, `GeneratedCorpus.swift` | `Oracle/GeneratedCorpusTests.swift` (prints case counts) |
| 13.8, 13.9, 13.9.1, 13.10 worked examples | `Scripts/extract-spec-examples.py`, `Tests/VietnameseEngineTests/Corpus/*.tsv`, `Sources/VietnameseEngineTesting/Fixtures/` | `Fixtures/SpecFixtureFileTests.swift` |
| ENG-R1201, ENG-R1202 (standard library only, no mutable static state), ENG-R128, ENG-R1220 | whole core target | `RegressionTests.reg23` (no `import`, logging or I/O symbols, no `static var` in the core sources) |
| 4.1, 4.2, ENG-R401 to ENG-R403 (key maps, keypad and shifted digits, method isolation) | `Composition/KeyRoles.swift`, `Engine/TokenKey.swift` | `Composition/TokenLifecycleTests.swift` (`digitsByMethod`), worked examples W159-W200, `CompositionPropertyTests` (ENG-T35) |
| 4.3, 4.4, ENG-R410 to ENG-R416 (order of interpretation, transforms, viability gating) | `Composition/Composition.swift`, `Composition/Composition+Transforms.swift` | `Composition/WorkedExampleTests.swift`, `Composition/GeneratedCorpusCompositionTests.swift`, `Composition/CompositionRuleTests.swift` |
| 4.5, ENG-R420, ENG-R421 (literal mode) | `Composition/Composition.swift` (`enterLiteral`), `Composition/Composition+Rendering.swift` | `CompositionRuleTests` (`literalModeFreezesTheDisplay`), W211-W225 |
| 4.6, ENG-R430 to ENG-R432 (free order) | `Composition/Composition+Transforms.swift` | W033-W061, generated corpus orders O2 to O4 |
| 4.7, ENG-R440 to ENG-R442 (escape by doubling, sticky kinds) | `Composition/KeyRoles.swift` (`EscapeKinds`), `Composition/Composition.swift` (`escape`) | W131-W150, `CompositionRuleTests` (`escapeIsStickyPerKind`, ENG-T36 tests) |
| 4.8, ENG-R103, ENG-R104 (standalone w, bracket keys) | `Composition/Composition+Transforms.swift` (`applyHornOrBreve`, `applyBracket`) | W244-W248, `CompositionRuleTests` (`standaloneWOff`, `bracketKeysOn`, `bracketKeysOffAreBoundaries`) |
| 5.1 to 5.4, ENG-R501, ENG-R502, ENG-R520 (placement on every key, relocation) | `Composition/Composition+Rendering.swift`, `Composition/ComposedLetter.swift` (`DisplayLetterView`) | `TonePlacementCompositionTests`, `EditTraceTests` (`relocationIsMinimal`), generated corpus O4 |
| 5.5, ENG-R530 to ENG-R534 (horns on `u o`, commit form of open `ươ`) | `Orthography/HornNormalisation.swift`, `Composition/Composition+Transforms.swift`, `Composition.committedText(style:)` | `HornCompositionTests`, W121-W130, generated corpus (committed form of every case) |
| 6.1, ENG-R601, ENG-R602 (recompute from raw keys) | `Composition/Composition.swift` (fold, `init(replaying:)`), `Composition/Composition+Rendering.swift` (`backspace`, `removeLastKey`) | `CompositionPropertyTests` (replay equivalence after every event, ENG-T33) |
| 6.2, ENG-R610, ENG-R611 (passThrough, edit, swallow, minimal edits) | `Engine/DisplayEdit.swift`, `Engine/ActiveToken.swift` | `EditTraceTests` (6.2 traces exactly), simulated field in every composition test |
| 6.3, ENG-R620 (`composingText`) | `Engine/Reducer.swift` | `EngineDriver` checks it after every event |
| 6.4, ENG-R630, ENG-R631 (delete counts) | `Engine/DisplayEdit.swift` | `SimulatedTextField` (never deletes more than the field holds, UTF-16 span check), `deleteCount == deleteUTF16Count` asserted for every edit |
| 6.5, ENG-R640, ENG-R641 (growable storage, 64-key cap) | `Composition/Composition.swift` (`composingKeyLimit`), `Composition/ComposedLetter.swift` (`KeySet`) | `LongTokenTests` (33 to 100,000 keys, REG-02) |
| 7.2, ENG-R701 to ENG-R705 (restore toggle) | `Engine/ActiveToken.swift` (`toggleRestore`), `Engine/Reducer.swift` | `RestoreToggleTests` (E01-E08, E02b) |
| 7.3, ENG-R411 (tone removal) | `Composition/Composition+Transforms.swift` (`removeTone`) | W151-W158, W183, W184, `CompositionRuleTests` (`toneRemovalWithoutVowelNeverCrashes`) |
| 7.4, ENG-R710 to ENG-R712 (Backspace inside a token) | `Composition/Composition+Rendering.swift` (`backspace`), `Engine/ActiveToken.swift` | W236-W243, `EditTraceTests` (`backspaceActions`) |
| 9.1, ENG-R901 to ENG-R905 (case, camel case) | `Composition/ComposedLetter.swift` (`CamelCaseTracker`), `Composition/Composition.swift` | W201-W210, `CaseTests` |
| 8.1, ENG-R801 to ENG-R803 (rules L0-L11 in order, reason codes, auto restore off, restore as edit then boundary) | `Commit/CommitRules.swift` (`CommitPolicy`, rule-to-`CommitRule` table), `Commit/CommittedTextFacts.swift`, `Engine/Reducer+Commit.swift` | `Commit/CommitDecisionTests.swift` (B001-B064), `Commit/CommitRuleTests.swift` |
| 8.3, ENG-R822, ENG-R823 (entry order, language of committed tokens, English run) | `Commit/TokenLanguage.swift` (`RecentLanguages`), `Engine/History.swift` (`languagesBefore`) | `EnglishRunTests`, B025-B033 |
| 8.4, 8.5, ENG-R830 to ENG-R832, ENG-R840 to ENG-R843 | `Commit/CommitRules.swift`, `Engine/Reducer.swift` (reset) | `CommitRuleTests`, `GeneratedCorpusCommitTests` (ENG-R843, ENG-R870) |
| 8.6, ENG-R850 (app context `code`, L9) | `Commit/CommitRules.swift` | B035, `CommitRuleTests.l4ToL11` |
| 8.7, ENG-R860, ENG-R861 (user lists, learning signals) | `Commit/CommitRules.swift` (`learningSignal`) | `CommitRuleTests` (`l1UserChoiceWithLearningSignals`, `l2UserLists`), `RestoreToggleTests.e04UndoesTheAutomaticRestore` |
| ENG-R532 at commit, ENG-R704 (undo of an automatic restore) | `Engine/Reducer+Commit.swift`, `Engine/History.swift` (`reopened`) | `CommitRuleTests.openHornPairIsWrittenUoAtCommit`, E04, `editing.tsv` ED018, ED019 |
| ENG-R870 (generated corpus committed in Vietnamese context) | - | `Commit/GeneratedCorpusCommitTests.swift` (lists the excluded `en` rows and the L8 restores of the 13.9 unattested list) |
| ENG-T12 spot list | - | `Commit/SpotListTests.swift` (documents which words need real data) |
| 9.2, ENG-R910 to ENG-R912 (every boundary key, history recording, Return and Tab) | `Engine/TokenKey.swift`, `Engine/Reducer+Commit.swift` | `CommitDecisionTests.sameDecisionAtEveryBoundaryKey` (13.9.1 over 66 keys), `BoundaryAndResetTests`, REG-29, REG-30 |
| 10.1, ENG-R1001 to ENG-R1004 (history limit, re-open across boundaries) | `Engine/History.swift`, `Engine/Reducer+Backspace.swift` | `Commit/HistoryTests.swift`, `editing.tsv`, REG-07 |
| 10.2, ENG-R1010 to ENG-R1012 (resets) | `Engine/Reducer.swift` | `ResetTests` (every `ResetReason`), REG-18, REG-22 |
| 11, ENG-R1101 to ENG-R1105 (macro validation, span, expansion, history token, hash lookup) | `Macros/MacroTable+Validation.swift`, `Macros/MacroKey.swift`, `Macros/MacroSpan.swift`, `Macros/MacroCase.swift`, `Engine/Reducer+Commit.swift` (`expandMacro`), `Engine/ActiveToken.swift` (macro tokens) | `Commit/MacroTests.swift`, `macros.tsv` + `macro-table.tsv` (`QACorpusTests`), `CommitPropertyTests` (1,000 random triggers), `EngineBenchmarkTests` (10,000 entries) |
| 13.5 REG-01 to REG-30 | whole engine | `Commit/RegressionTests.swift` (one test per id) |
| ENG-T31 (simulated field equals the engine view, no over-deletion), ENG-T32, ENG-T33 | `Sources/VietnameseEngineTesting/Simulation/SimulatedTextField.swift` (`EngineDriver`, `viewText`) | every driver-based test, `CommitPropertyTests` |
| ENG-R1210 (determinism), ENG-R1230 (budget, sanity only) | `Engine/Reducer.swift` | `CompositionPropertyTests` (`determinism`), `EngineBenchmarkTests`, `Scripts/bench-composition.sh` |
