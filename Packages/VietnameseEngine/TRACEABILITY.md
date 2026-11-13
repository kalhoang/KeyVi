# Traceability: engine requirements to code and tests

Every `ENG-R`, `ENG-T` and `REG` identifier of `spec/01-engine.md`, with the code that implements it and
the tests that check it. `Scripts/check-traceability.py` fails when an identifier of the spec is missing
here (it runs in `TraceabilityTests`).

Paths: code under `Sources/VietnameseEngine/` unless another target is named; tests are
`Suite.function` names (files under `Tests/VietnameseEngineTests/`), corpus files are under
`Tests/VietnameseEngineTests/Corpus/`. "W", "B", "E" rows are the worked examples of 13.8 to 13.10
(`WorkedExampleTests`, `CommitDecisionTests`, `RestoreToggleTests`). "Fuzz" is `FuzzTests` with the
invariant checker `VietnameseEngineTesting/Fuzz/InvariantChecker.swift`; "corpus" is `QACorpusTests`.
Where the owner is another track, the row says so.

## 1. Scope

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R101 | Telex and VNI | `PublicAPI.swift` (`InputMethod`), `Composition/KeyRoles.swift` | W001-W200 (both methods), `GeneratedCorpusCompositionTests.orderCases` (both methods), Fuzz |
| ENG-R102 | NFC, precomposed letters only, no combining marks | `Generated/LetterTable.swift`, `Composition/Composition+Rendering.swift` | `LetterTableTests`, Fuzz (ENG-T34 on every insert), `RegressionTests.reg06` |
| ENG-R103 | Telex standalone `w`, default on | `PublicAPI.swift` (`TelexOptions`), `Composition/Composition+Transforms.swift` (`applyHornOrBreve`) | W013, W039-W045, `OptionAndEscapeTests.standaloneWOff`, `PublicAPITests.defaults` |
| ENG-R104 | Telex bracket keys, default off | `Composition/Composition+Transforms.swift` (`applyBracket`), `Engine/TokenKey.swift` | W244-W245, `OptionAndEscapeTests.bracketKeysOn`, `bracketKeysOffAreBoundaries`, `crash-regressions.tsv` CR040-CR041 |
| ENG-R105 | Traditional and modern placement | `Orthography/TonePlacement.swift` | `TonePlacementTests`, W062-W067, generated corpus (both styles) |
| ENG-R106 | Auto restore on by default, no download | `PublicAPI.swift` (`EngineConfiguration.autoRestore`) | `PublicAPITests.defaults`, `CommitRuleTests.emptyResourcesNeedNoDownload` |
| ENG-R107 | Free order always on, no setting | `Composition/Composition+Transforms.swift` | W033-W061, generated corpus O2-O4, `PublicAPITests.closedOptionSet` |
| ENG-R108 | Restore toggle event | `PublicAPI.swift` (`EngineEvent.restoreToggle`), `Engine/ActiveToken.swift` (`toggleRestore`) | `RestoreToggleTests` (E01-E08, E02b) |
| ENG-R109 | Standalone Swift package, MPL-2.0 | `Package.swift`, `LICENSE` | `StaticSourceTests.coreIsClean` (no imports) |
| ENG-R110 | Macros at commit, empty table shipped | `Macros/`, `Engine/Reducer+Commit.swift` (`expandMacro`) | `MacroExpansionTests`, `macros.tsv`, `PublicAPITests.defaults` |
| ENG-R120 | No legacy encodings | `PublicAPI.swift` (only NFC `TextEdit.insert`) | Fuzz (ENG-T34) |
| ENG-R121 | No Quick Telex shortcuts | absence (no rule exists) | `no-shortcuts.tsv`, `OptionAndEscapeTests.noQuickTelexShortcuts`, `RegressionTests.reg04`, `CorpusTargetTests.nonGoals` |
| ENG-R122 | No spell checking or suggestions | absence | `CorpusTargetTests.nonGoals` (only restore changes words) |
| ENG-R123 | No automatic capitalisation | absence | `CorpusTargetTests.nonGoals` |
| ENG-R124 | No prediction, autocomplete, translation, network | absence; `StaticSourceTests` forbids I/O | `StaticSourceTests.coreIsClean` |
| ENG-R125 | Withdrawn (macros are in v1) | - | - |
| ENG-R126 | No VIQR or other schemes | absence | `CorpusTargetTests.nonGoals` |
| ENG-R127 | No multi-syllable segmentation | `Composition/Composition.swift` (literal mode) | `CorpusTargetTests.nonGoals` |
| ENG-R128 | No file, network or logging I/O | whole core (no imports) | `StaticSourceTests.coreIsClean`, `RegressionTests.reg23` |

## 3. Syllable model

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R301 | Generated table of the 146 letters, by code point | `Scripts/generate-letter-table.py`, `Generated/LetterTable.swift`, `Letters/LetterTableLookup.swift` | `LetterTableTests.tableHas146LettersOrderedByCodePoint`, `tableEqualsRederivationFromUnicodeData` |
| ENG-R302 | Tier A rhyme set exactly the 3.7 table plus 3.8, 3.9 | `Orthography/RhymeInventory.swift`, `Orthography/SyllableRules.swift` | `SyllableCountTests.rhymeCounts` |
| ENG-R303 | `ch`/`nh` codas only after the listed vowels | `Orthography/RhymeInventory.swift` (property of the table) | `SyllableCountTests.chAndNhCodasOnlyAfterTheListedVowels` |
| ENG-R304 | `qui`/`quy`, `quít`/`quýt` kept as typed | `Orthography/RhymeInventory.swift` | `ValidityTests.standard`, `rhymes-rare.tsv` RR024-RR025 |
| ENG-R305 | `gi` onset rhymes, `gi + êc`, `gi + êng` | `Orthography/SyllableRules.swift` | `ValidityTests.standard`, `rhymes-rare.tsv` RR019-RR023 |
| ENG-R306 | `g` + `i` rhyme | `Orthography/SyllableParser.swift` | `SyllableParserTests.parse`, `rhymes-rare.tsv` RR018, RR049 |
| ENG-R307 | `gi` decided on the current letters every time | `Orthography/SyllableParser.swift`, `Composition/Composition+Rendering.swift` | `SyllableParserTests.parse`, `TonePlacementTests.relocationWhileTyping`, `RegressionTests.reg11` |
| ENG-R310 | `k gh ngh` / `c g ng` spelling constraints | `Orthography/SyllableRules.swift` | `ValidityTests.invalid`, `RegressionTests.reg26` |
| ENG-R311 | `q` only as `qu` | `Orthography/SyllableRules.swift` | `ValidityTests.invalid`, `SyllableParserTests.parse` |
| ENG-R312 | Medial rhymes invalid after `c k gh ngh gi` and labials (Tier A) | `Orthography/SyllableRules.swift`, `Orthography/Onset.swift` | `ValidityTests.invalid`, `ValidityTests.extended` |
| ENG-R313 | `yê` only without onset, `iê` invalid without onset | `Orthography/SyllableRules.swift` | `ValidityTests`, `rhymes-rare.tsv` RR043-RR044 |
| ENG-R314 | Open `y` after the listed onsets; `i` and `y` both kept | `Orthography/RhymeInventory.swift` (`openYStandardOnsets`) | `ValidityTests`, `rhymes-rare.tsv` RR028-RR031 |
| ENG-R315 | `uơ` Tier A only after `h`, `th` | `Orthography/RhymeInventory.swift` (`uoStandardOnsets`) | `ValidityTests`, `rhymes-rare.tsv` RR004-RR007 |
| ENG-R316 | Vietnamese decided by the tiers only; attested data only breaks English ties; same result at every boundary (3.3) | `Commit/CommitRules.swift` (L7 before L8) | `RegressionTests.reg28`, `reg29`, B055-B056 |
| ENG-R317 | Open `ươ` never valid in committed text (3.10; numbered ENG-R316 in the first spec version) | `Composition/Composition+Rendering.swift` (`committedText`), `Orthography/HornNormalisation.swift` | `HornCompositionTests.commitFormOfAnOpenPair`, `ValidityTests.invalid` |
| ENG-R320 | `c ch p t` codas: sắc and nặng only | `Orthography/SyllableTables.swift` | `SyllableCountTests.tonesPerRhymeFollowTheCoda` |
| ENG-R321 | Tier B `k` coda takes all tones | `Orthography/SyllableTables.swift` | `ValidityTests.extended` |
| ENG-R330 | Composition uses Tier B | `Orthography/ViabilityAutomaton.swift` (built from `extendedPairs`) | `ViabilityTests.everyPrefixOfEveryTierBSyllableIsViable`, B036-B037 |
| ENG-R331 | Tier B kept unless the keys are English (L6) | `Commit/CommitRules.swift` | B017-B022, B036-B037, `proper-nouns.tsv` |
| ENG-R332 | Capitalisation carries no signal | `Commit/CommitRules.swift` (case-insensitive lookups) | `proper-nouns.tsv` PN211-PN212, `english.tsv` EN025-EN026 |
| ENG-R333 | Apostrophe names are two tokens | `Engine/TokenKey.swift` | `CommitRuleTests.apostropheAndHyphenAreBoundaries`, `proper-nouns.tsv` PN202-PN207 |
| ENG-R334 | Words outside Tier B only through the user lists | `Commit/CommitRules.swift` (L2) | `proper-nouns.tsv` PN208-PN210, `CommitRuleTests.l2UserLists` |
| ENG-R340 | Parse is a pure function of the letters | `Orthography/SyllableParser.swift` | `SyllableParserTests.parseIgnoresTheCollectionType`, `everyInventoryPairParsesBackToItself` |
| ENG-R345 | Viability: prefix of a Tier B syllable with the wildcard | `Orthography/ViabilityAutomaton.swift` | `ViabilityTests.viable`, `nonViable`, `automatonEqualsReferenceOnAllShortStrings` |
| ENG-R346 | Viability structure generated from the tables | `Orthography/ViabilityAutomaton.swift` (trie, subset construction, minimisation) | `ViabilityTests.automatonEqualsReferenceOnSingleLetterMutations` |
| ENG-R350 | Generator prints its counts in CI | `Orthography/SyllableTables.swift` | `SyllableCountTests` (prints), `docs/decisions/0100-engine-syllable-counts.md` |

## 4. Key maps and composition rules

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R401 | Keypad digits are boundaries | `Engine/TokenKey.swift` | `BoundaryAndResetTests.digitsByMethod`, Fuzz (keypad digits) |
| ENG-R402 | Shifted digits are symbols, boundaries | `Engine/TokenKey.swift` | `RegressionTests.reg14`, `layouts.tsv` (AZERTY digits with Shift) |
| ENG-R403 | Telex and VNI never mix; VNI restore gives the digits | `Composition/KeyRoles.swift` | `RegressionTests.reg05`, Fuzz (ENG-T35), `restore-exact.tsv` |
| ENG-R410 | Tone applies with a vowel group; same tone escapes | `Composition/Composition+Transforms.swift` (`applyTone`) | W001-W005, W131-W150, `OptionAndEscapeTests.doubledToneEndsWithTheKeyOverTheCorpus` |
| ENG-R411 | Tone removal; `qu` with no vowel | `Composition/Composition+Transforms.swift` (`removeTone`) | W151-W158, `crash-regressions.tsv` CR001-CR009, `RegressionTests.reg01`, `editing.tsv` ED033-ED042 (Backspace after a removal) |
| ENG-R412 | Circumflex targets, viability, escape | `Composition/Composition+Transforms.swift` (`applyCircumflex`) | W006-W009, W121-W130, `OptionAndEscapeTests.readingsOfDecision0102` |
| ENG-R413 | Horn and breve, pair first, escape, standalone `ư` | `Composition/Composition+Transforms.swift` (`applyHornOrBreve`) | W010-W013, W121-W130, W246-W248 |
| ENG-R414 | VNI `7` and `8` | `Composition/KeyRoles.swift` (`HornBreveScope`) | W159-W200, `OptionAndEscapeTests.readingsOfDecision0102` |
| ENG-R415 | Stroke on a first `d` | `Composition/Composition+Transforms.swift` (`applyStroke`) | W012, W038, `RegressionTests.reg21`, `crash-regressions.tsv` CR015 |
| ENG-R416 | A transform that breaks viability is not applied | `Composition/Composition+Transforms.swift` (try, check, revert) | W141-W150, `RegressionTests.reg13`, `reg20` |
| ENG-R420 | Literal mode freezes the display | `Composition/Composition.swift` (`enterLiteral`) | `OptionAndEscapeTests.literalModeFreezesTheDisplay`, W211-W225, `RegressionTests.reg19` |
| ENG-R421 | Literal mode ends at the token end or when Backspace removes its key | `Composition/Composition+Rendering.swift` (`removeLastKey`) | `RequirementGapTests.literalModeEndsWithItsKey` |
| ENG-R430 | Free-order entry | `Composition/Composition+Transforms.swift` | W033-W061, generated corpus O2-O4, `RegressionTests.reg09` |
| ENG-R431 | Circumflex after the coda | `Composition/Composition+Transforms.swift` | W034, `OptionAndEscapeTests.literalModeFreezesTheDisplay` (`cana`), `proper-nouns.tsv` PN203 |
| ENG-R432 | Tone key before any vowel is a letter | `Composition/Composition+Transforms.swift` (`applyTone` guard) | `OptionAndEscapeTests.literalModeFreezesTheDisplay` (`tsa`), `no-shortcuts.tsv` NS014 |
| ENG-R440 | Escape by doubling | `Composition/Composition.swift` (`escape`) | W131-W150, Fuzz (ENG-T36), `OptionAndEscapeTests.doubledTransformEndsWithTheKey` |
| ENG-R441 | Escape is sticky per kind | `Composition/KeyRoles.swift` (`EscapeKinds`) | `OptionAndEscapeTests.escapeIsStickyPerKind` |
| ENG-R442 | The escaped letter counts for viability | `Composition/Composition.swift` (`appendLetterOrLiteral`) | B014, `crash-regressions.tsv` CR015, CR028-CR030 |
| ENG-R450 | No other engine option | `PublicAPI.swift` | `PublicAPITests.closedOptionSet` |

## 5. Tone placement

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R501 | Placement on the current letters, never stored | `Composition/Composition+Rendering.swift`, `Orthography/TonePlacement.swift` | `TonePlacementCompositionTests.relocationWhileTyping`, generated corpus O4 |
| ENG-R502 | `qu` and `gi` agree in both styles | `Orthography/TonePlacement.swift` | `TonePlacementTests.quAndGiOnsetsAgreeInBothStyles` |
| ENG-R510 | Default traditional | `PublicAPI.swift` | `PublicAPITests.defaults` |
| ENG-R511 | Article 8.2 two-letter nuclei | `Orthography/TonePlacement.swift` | `TonePlacementTests.article82TwoLetterNuclei` |
| ENG-R520 | Relocation is a minimal edit | `Engine/DisplayEdit.swift` | `EditTraceTests.relocationIsMinimal` |
| ENG-R530 | Horn on either letter of `u o` means both | `Orthography/HornNormalisation.swift` | `HornNormalisationTests.hornOnEitherLetterMeansBoth`, `HornCompositionTests` |
| ENG-R531 | Open pair shown `ươ` while typing | `Orthography/HornNormalisation.swift` | `HornCompositionTests`, `rhymes-rare.tsv` RR005 |
| ENG-R532 | Open `ươ` written `uơ` at commit | `Composition/Composition+Rendering.swift` (`committedText`) | `CommitRuleTests.openHornPairIsWrittenUoAtCommit`, B042-B043 |
| ENG-R533 | Circumflex on `ươ` gives `uô`, `w` on `uô` gives `ươ` | `Composition/Composition+Transforms.swift` | `HornCompositionTests.circumflexAndHornReplaceEachOther`, W121-W130 |
| ENG-R534 | Second `w` on a full pair escapes | `Composition/Composition+Transforms.swift` | W130, `RegressionTests.reg12` |

## 6. Composition model

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R601 | Display is a pure function of (raw keys, configuration) | `Composition/Composition.swift` (fold), `Composition/Composition+Rendering.swift` | `CompositionPropertyTests.randomStreams`, Fuzz (replay check every event) |
| ENG-R602 | Raw keys kept exactly as typed | `Composition/Composition.swift` (`raw`) | `restore-exact.tsv`, Fuzz (ENG-T32) |
| ENG-R610 | passThrough, edit, swallow | `Engine/DisplayEdit.swift` (`actionForKey`) | `EditTraceTests` (6.2 traces), `swallowedKeyChangesNothingVisible` |
| ENG-R611 | Minimal edits | `Engine/DisplayEdit.swift` (`edit`) | `EditTraceTests.relocationIsMinimal`, Fuzz (ENG-T31) |
| ENG-R620 | `composingText` on every output | `Engine/Reducer.swift` | Fuzz (every event), `EngineDriver` |
| ENG-R630 | Delete counts only what the engine produced | `Engine/DisplayEdit.swift` | Fuzz (ENG-T31: delete within the engine's view) |
| ENG-R631 | `deleteCount` and `deleteUTF16Count` both, equal | `Engine/DisplayEdit.swift` | Fuzz (ENG-T34 on every edit), `MacroExpansionTests.expansionOutsideTheBasicMultilingualPlane` |
| ENG-R632 | Host maps clusters to Backspace or UTF-16 ranges | host (`02-platform.md`) | - |
| ENG-R640 | Growable storage, no trap at any length | `Composition/Composition.swift`, `Engine/History.swift` | `FuzzTests.longTokens` (to 100,000 keys), `LongTokenTests`, `crash-regressions.tsv` |
| ENG-R641 | Literal after 64 composing keys | `Composition/Composition.swift` (`composingKeyLimit`) | `LongTokenTests.composingTokenGoesLiteralAfter64Keys`, `crash-regressions.tsv` CR017-CR020 |

## 7. Escape, restore and tone removal

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R701 | Toggle: raw keys (user-restored) or composed form (user-kept) | `Engine/ActiveToken.swift` (`toggleRestore`) | E01-E08, `RestoreToggleTests.tokenRestoredByARuleComposesOnToggle`, Fuzz (ENG-T32) |
| ENG-R702 | A consecutive toggle passes through | `Engine/Reducer.swift` (`toggleRestore`) | E02, `crash-regressions.tsv` CR038 |
| ENG-R703 | Toggle with nothing to do passes through | `Engine/Reducer.swift` | E05, E06, `RestoreToggleTests.toggleWithoutTokenPassesThrough`, `no-shortcuts.tsv` NS010-NS012 |
| ENG-R704 | Undo an automatic restore: Backspace, toggle | `Engine/History.swift` (`reopened`) | E04, `RestoreToggleTests.e04UndoesTheAutomaticRestore`, `editing.tsv` ED018-ED019 |
| ENG-R705 | Restore reproduces digits and doubled letters | `Engine/ActiveToken.swift` | E03, E07, E08, `restore-exact.tsv`, `RestoreToggleTests.vniRestoreReproducesDigits` |
| ENG-R710 | Backspace removes the letter's keys and recomputes | `Composition/Composition+Rendering.swift` (`backspace`, `Composition.placementOffset`) | W236-W243, `editing.tsv` ED001-ED006, ED033-ED044, `InvariantChecker` (Backspace shortens the token, every fuzz event) |
| ENG-R711 | Backspace on an escape letter removes only its key | `Composition/Composition+Rendering.swift` | W241, `RegressionTests.reg24`, `editing.tsv` ED043-ED044 |
| ENG-R712 | passThrough when one character goes, else an edit | `Engine/DisplayEdit.swift` (`actionForBackspace`) | `EditTraceTests.backspaceActions` |
| ENG-R713 | Backspace with no token: history rules | `Engine/Reducer+Backspace.swift` | `HistoryTests.reopenAcrossBoundaries` |

## 8. Restore policy

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R801 | Rules L0-L11 in order (L3 never keeps a token with an escape), a reason code per commit | `Commit/CommitRules.swift` (`CommitPolicy.decide`) | B001-B064, `CommitRuleTests` (one test per rule) |
| ENG-R802 | Auto restore off: L3b-L11 never restore | `Commit/CommitRules.swift` (`restore`) | `CommitRuleTests.autoRestoreOff`, `collisions.tsv` CO034 |
| ENG-R803 | Restore is an edit then the boundary key | `Engine/Reducer+Commit.swift` | `CommitRuleTests.restoreIsAnEditThenTheBoundaryKey`, B064 |
| ENG-R810 | Resources built reproducibly from pinned inputs | `lexicon-builder` (`build`, `check`, `pin`), `data/inputs/MANIFEST.sha256` | `LexiconBuilderTests.buildTwiceGivesIdenticalBytesEqualToTheCommittedResources`, `checkPassesOnTheCommittedOutputs`, `BuilderUnitTests.buildIsAPureFunctionOfThePinnedInputs`, `manifestVerificationNamesChangedUnpinnedAndMissingFiles`, `portableSHA256MatchesCryptoKit` |
| ENG-R811 | SCOWL notice in the app | `Resources.bundledNotices()` (`NOTICES.txt`); display: app track | `BundledResourcesTests.bundledNoticesCarryTheScowlNotice` |
| ENG-R812 | Core does not embed data | `Package.swift` (data in `VietnameseEngineData`), `PublicAPI.swift` (`Resources`) | `CommitRuleTests.emptyResourcesNeedNoDownload`, every test passes its resources |
| ENG-R820 | Ambiguity candidates generated by typing the lexicon | `lexicon-builder ambiguity-candidates` (`AmbiguityCandidates.swift`; also unattested Tier A displays and VNI digit words, `docs/decisions/0202`); `data/derived/ambiguity-candidates.tsv` | `AmbiguityCandidateTests`, `LexiconBuilderTests.ambiguityCandidatesRunAgainstTheRealEngine`, `EnglishCorpusGateTests.vietnameseContext`, `CorpusTargetTests.englishCorpus` |
| ENG-R821 | Every candidate a row; unreviewed rows act as `vi` | `Commit/CommitRules.swift` (L11); `data/inputs/ambiguity.tsv` (619 rows), `--merge` policy (generated `en` rows in their own block), `Builder.checkGeneratedRows`, loader `ResourceDirectory.ambiguityTable` | B024-B034, `collisions.tsv`, `AmbiguityCandidateTests.mergeAppendsOnlyMissingRowsAndKeepsExistingDecisions`, `AmbiguityCandidateTests.mergeGroupsGeneratedEnRowsUnderTheirOwnBlockAndViRowsBeforeIt`, `BuilderUnitTests.buildRejectsGeneratedRowsWhoseReasonNoLongerHolds`, `MalformedResourceTests.validFixtureLoads`, `BundledResourcesTests.loadsAndContainsTheSpecifiedData` |
| ENG-R822 | Table keyed by the exact raw keys | `Commit/CommitRules.swift` | B026, `collisions.tsv` CO020 |
| ENG-R823 | Token language and English run | `Commit/TokenLanguage.swift` (`RecentLanguages`) | `EnglishRunTests`, B025-B033, `collisions.tsv` CO030-CO033 |
| ENG-R824 | Retroactive correction out of scope | - (v1.1) | `docs/decisions/0103` |
| ENG-R830 | Decisions only at commit | `Engine/Reducer+Commit.swift` | `CommitRuleTests.noMidWordRestore` |
| ENG-R831 | Reset commits and restores nothing | `Engine/Reducer.swift` | `ResetTests.resetClearsTokenAndHistory` |
| ENG-R832 | First word after focus treated like any other | `Engine/Reducer.swift` | `CommitRuleTests.firstWordAfterFocusIsTreatedLikeAnyOther`, `RegressionTests.reg18` |
| ENG-R840 | No-vowel tokens without an escape never restored | `Commit/CommitRules.swift` (L3) | B040-B041, `CommitRuleTests.l3Abbreviations`, `RegressionTests.reg17` |
| ENG-R841 | Toggled tokens never restored by the rules | `Commit/CommitRules.swift` (L1) | `RequirementGapTests.neverRestored`, `CommitRuleTests.l1UserChoiceWithLearningSignals` |
| ENG-R842 | Display equal to the keys: nothing to decide | `Commit/CommitRules.swift` (L0) | `CommitRuleTests.l0NothingTransformed`, `RequirementGapTests.neverRestored` |
| ENG-R843 | Valid Vietnamese and names kept | `Commit/CommitRules.swift` | `GeneratedCorpusCommitTests.committedTextEqualsTheOracle`, `proper-nouns.tsv`, `rhymes-rare.tsv`, `RegressionTests.reg08` |
| ENG-R850 | `appContext` general / code, L9 | `Commit/CommitRules.swift` | B035, `collisions.tsv` CO029 |
| ENG-R851 | No app information reaches the engine | `PublicAPI.swift` (no such field) | `PublicAPITests.closedOptionSet` |
| ENG-R860 | User keep-as-typed and keep-Vietnamese lists | `Commit/CommitRules.swift` (L2) | `CommitRuleTests.l2UserLists`, `proper-nouns.tsv` PN208 |
| ENG-R861 | Learning signal when the user's toggle disagrees | `Commit/CommitRules.swift` (`learningSignal`) | `CommitRuleTests.l1UserChoiceWithLearningSignals`, E04 |
| ENG-R862 | Host policy: learned entries stored per app, typed entries global | host: AppCore `SettingsStore/LearnedWords.swift` (`UserSettings.learn`, `wordLists(for:)`), `InputHost/Integration/LearningTracker.swift`, `TapSettingsPublisher.focusChanged(to:)` (ADR 0320); the engine only emits the signal (ENG-R861) and receives the lists (ENG-R860) | AppCore `LearnedWordsModelTests`, `LearnedWordsCodecTests`, `LearnedWordsStoreTests`, `LearningTrackerTests`, `FocusedAppWordListTests`, `HostPerAppLearningTests`, `LearnedWordsPaneTests` |
| ENG-R870 | Generated corpus committed: 100 % (`en` rows excluded, generated L8 and tech-always rows included) | - | `GeneratedCorpusCommitTests` (fixtures), `GeneratedCorpusGateTests` (bundled data, 269,500 cases, exclusions listed per shard and in total) |
| ENG-R871 | English corpus in an English run: 99.5 % unchanged | harness `VietnameseEngineTesting/Corpora/CorpusTargets.swift` | `EnglishCorpusGateTests.englishRun` (bundled lexicon and tech lists, 40,701 words, 99.87 %), `CorpusTargetTests.englishCorpus` (fixture words) |
| ENG-R872 | English corpus in Vietnamese context: at most 3 % changed, all `vi` candidates | same harness | `EnglishCorpusGateTests.vietnameseContext` (0.97 %; `vi` rows or ENG-T11 entries), `CorpusTargetTests.englishCorpus` (candidate rule) |
| ENG-R873 | Prose by three typists: 99.95 % identical | `ProseCorpusCheck` | `ProseCorpusGateTests.typist` (`data/corpus/prose-vi.txt`, 250,006 tokens, both methods, both tone styles), `CorpusTargetTests.proseToneStyle`, `CorpusTargetTests.prose` (sample text) |
| ENG-R874 | VNI words without digits never changed | `Composition/KeyRoles.swift` | `CorpusTargetTests.vniWithoutDigits`, `vniStreamsPassThrough` |
| ENG-R875 | Zero crashes in fuzzing | whole engine | `FuzzTests` (1,000,000+ events), `Packages/VietnameseEngineFuzz` |

## 9. Case, numbers, punctuation and boundaries

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R901 | Each letter in the case of its key | `Composition/ComposedLetter.swift`, `Composition/Composition+Rendering.swift` | W201-W210, `CaseTests.outputLettersTakeTheCaseOfTheirKeys` |
| ENG-R902 | Transform keys' case ignored | `Composition/KeyRoles.swift` | `CaseTests`, `restore-exact.tsv` RE018 |
| ENG-R903 | Standalone `ư` and escape letters take the key's case | `Composition/Composition+Transforms.swift` | `CaseTests` |
| ENG-R904 | Camel case goes literal, restored at commit | `Composition/ComposedLetter.swift` (`CamelCaseTracker`) | `CaseTests.camelCaseGoesLiteral`, `CommitRuleTests.l3bCamelCase` |
| ENG-R905 | Case operations locale independent | `Composition/KeyRoles.swift` (`ASCII`), `Macros/MacroCase.swift` | `StaticSourceTests.coreIsClean` (no `Locale`) |
| ENG-R906 | Bracket letters uppercase under Caps Lock or in an all-caps word | `PublicAPI.swift` (`KeyInput.capsLock`), `Composition/Composition.swift` (`capsLockKeys`), `Composition/Composition+Transforms.swift` (`applyBracket`), `Composition/Composition+Rendering.swift`; host: AppCore `InputHost` `KeyPipeline` passes the Caps Lock state with every key (PLT-R350, decision 0005) | `BracketCaseTests`; AppCore `KeyPipelineCapsLockTests` |
| ENG-R910 | Boundaries commit and are delivered; recorded in history | `Engine/Reducer+Commit.swift`, `Engine/TokenKey.swift` | `CommitDecisionTests.sameDecisionAtEveryBoundaryKey`, `BoundaryAndResetTests` |
| ENG-R911 | Apostrophe and hyphen are boundaries | `Engine/TokenKey.swift` | `CommitRuleTests.apostropheAndHyphenAreBoundaries` |
| ENG-R912 | Return and Tab clear the history | `Engine/Reducer+Commit.swift` (`finishBoundary`) | `BoundaryAndResetTests.returnAndTabClearTheHistory`, `editing.tsv` ED011-ED012 |

## 10. Context

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R1001 | History keeps tokens and boundaries, limit 16 | `Engine/History.swift` | `HistoryTests.historyLimitComesFromTheConfiguration`, `HistoryTests.hugeHistoryLimitNeverTraps`, Fuzz (bound every event) |
| ENG-R1002 | Backspace re-opens the previous word across boundaries | `Engine/Reducer+Backspace.swift` | `HistoryTests.reopenAcrossBoundaries`, `RegressionTests.reg07`, `editing.tsv` |
| ENG-R1003 | Backspace continues into the re-opened token | `Engine/Reducer+Backspace.swift` | `HistoryTests.backspaceContinuesIntoTheTokenAndPastItsStart` |
| ENG-R1004 | Empty history: passThrough | `Engine/Reducer+Backspace.swift` | `HistoryTests.emptyHistoryBackspacePassesThrough` |
| ENG-R1010 | Host sends resets | host (`02-platform.md`); `PublicAPI.swift` (`ResetReason`) | `ResetTests` (every reason) |
| ENG-R1011 | Reset clears token and history, no edit | `Engine/Reducer.swift` | `ResetTests.resetClearsTokenAndHistory`, `RegressionTests.reg22` |
| ENG-R1012 | After a reset the next key is a first key | `Engine/Reducer.swift` | `RegressionTests.reg18` |

## 11. Macros

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R1101 | Trigger and expansion limits | `Macros/MacroTable+Validation.swift` | `MacroValidationTests` |
| ENG-R1102 | Span since the last whitespace, 32 characters | `Macros/MacroSpan.swift` | `MacroExpansionTests.spanIncludesPunctuationAndDigits`, `spanOfMoreThan32CharactersIsNotLookedUp` |
| ENG-R1103 | Expansion before L0, terminator delivered, casing, shadowed triggers rejected | `Engine/Reducer+Commit.swift` (`expandMacro`), `Macros/MacroCase.swift`; host: AppCore SettingsStore import check and the Macros pane editor apply the same trailing-digit shadowing rule, with the upgrade path for saved pairs in ADR 0321 | `MacroExpansionTests.examplesOfSection11`, `caseAdaptation`, `MacroValidationTests.shadowedByShorterTrigger`, `trailingDigitShadowsLikePunctuation_ENGR1103`, `macros.tsv`; AppCore `MacroEditorTests`, `MacroEngineAgreementTests` |
| ENG-R1104 | Expansion is one literal history token; toggle brings the span back | `Engine/ActiveToken.swift` (macro tokens) | `MacroExpansionTests.expansionIsOneLiteralHistoryToken`, `toggleAfterBackspaceBringsTheSpanBack` |
| ENG-R1105 | Hash lookup, 10,000 entries within budget | `Macros/MacroKey.swift` | `MacroValidationTests.tenThousandEntries`, `engine-benchmark` (10,000-entry table) |
| ENG-R1106 | Macro contents never logged | no logging (REG-23); errors carry triggers only | `RequirementGapTests.validationErrorsCarryNoExpansion`, `StaticSourceTests.coreIsClean` |
| ENG-R1107 | Host decides whether macros are active | host; `PublicAPI.swift` (`Resources.macros`) | `MacroExpansionTests.emptyTableNeverMatches` |

## 12. API, privacy and performance

| ID | Requirement | Code | Tests |
|---|---|---|---|
| ENG-R1201 | Swift 6, strict concurrency, macOS 13 floor, Linux build | `Package.swift` (`swiftLanguageModes: [.v6]`, `.macOS(.v13)`) | builds; Linux build: CI track (VERIFY) |
| ENG-R1202 | No global or static mutable state | whole core | `StaticSourceTests.coreIsClean` |
| ENG-R1203 | Public types Sendable, listed ones Hashable | `PublicAPI.swift`, `Orthography/Orthography.swift` | `PublicAPITests.conformances` |
| ENG-R1210 | `reduce` deterministic, side-effect free | `Engine/Reducer.swift` | Fuzz (pure `reduce` against `Session`, digest replay), `CompositionPropertyTests.determinism`, `FuzzTests.determinism` |
| ENG-R1211 | Configuration change means a new engine | `PublicAPI.swift` (`let configuration`) | `PublicAPITests.configurationIsFixed` |
| ENG-R1212 | `Orthography.analyze` for diagnostics | `Orthography/Orthography.swift` | `OrthographyAnalyzeTests` |
| ENG-R1220 | No logging or persistence of keys or text | whole core | `StaticSourceTests.coreIsClean`, `RegressionTests.reg23` |
| ENG-R1230 | p50 5 µs, p99 25 µs, p99.9 100 µs, worst 1 ms | whole engine; `Engine/Reducer.swift` (`prepareSharedTables`) | `engine-benchmark` + `Benchmarks/compare.py` (M4: p50 0.125 µs, p99 under 1.5 µs, p99.9 under 12 µs, worst under 70 µs), `EngineBenchmarkTests` |
| ENG-R1231 | `Resources.bundled` within 50 ms and 8 MB | `VietnameseEngineData` (`ResourceDirectory`: byte-level parsing, sorted-list uniqueness without hashing) | `BundledResourcesTests.staysWithinLoadTimeAndMemoryBudget` (debug: CPU time, heap), `engine-benchmark` + `Benchmarks/compare.py` (release cold load and resident growth) |
| ENG-R1232 | Work proportional to the token, not history or lexicon | `Engine/History.swift`, `Macros/MacroSpan.swift`, `PublicAPI.swift` (`WordSet`) | `LongTokenCostTests`, `engine-benchmark` long-token figures |
| ENG-R1233 | CI fails above budget or 20 % over baseline after calibration | `Benchmarks/compare.py`, `Benchmarks/baseline.json`, `Scripts/benchmark.sh` | CI track runs `Scripts/benchmark.sh` |

## 13. Acceptance tests

| ID | Test | Code | Tests |
|---|---|---|---|
| ENG-T01 | Independent oracle | `VietnameseEngineTesting/Oracle/SyllableOracle.swift` | `SyllableOracleTests` |
| ENG-T02 | Generated corpus O1-O4, both methods and styles | `VietnameseEngineTesting/Oracle/KeySequenceGenerator.swift`, `GeneratedCorpus.swift` | `GeneratedCorpusCompositionTests.orderCases`, `GeneratedCorpusCommitTests` |
| ENG-T03 | Titlecase, uppercase, explicit `uwow` variants | same | `GeneratedCorpusCompositionTests.variantCases` |
| ENG-T04 | 100 % of the 237,824 O1-O4 cases and 31,676 variants | same | `GeneratedCorpusTests.caseCounts` (prints counts) |
| ENG-T10 | English lexicon in both contexts | `VietnameseEngineTesting/Corpora/CorpusTargets.swift` (`EnglishCorpusCheck`) | `EnglishCorpusGateTests` (bundled data), `CorpusTargetTests.englishCorpus` (fixtures) |
| ENG-T11 | `known-exceptions.txt` | `Corpus/known-exceptions.txt` (53 entries: 50 L4, 1 L6, 2 L7; accepted as known issues on 13/11/2026, docs/decisions/0005) | `EnglishCorpusGateTests` (every English-run change listed, no stale entry), `CorpusTargetTests.englishCorpus` |
| ENG-T12 | Spot list unchanged | `VietnameseEngineTesting/Fixtures/SpotList.swift` | `SpotListTests` (13.9 fixtures), `SpotListGateTests` (bundled data) |
| ENG-T20 | Prose corpus, three typists | `ProseCorpusCheck`; corpus `data/corpus/prose-vi.txt` (`lexicon-builder prose-corpus`) | `ProseCorpusGateTests`, `LexiconBuilderTests.proseCorpusHasAtLeast200000SyllablesAndIsReproducible`, `CorpusTargetTests.prose` |
| ENG-T30 | No crash, bounded memory | `InvariantChecker` | `FuzzTests.randomStreams`, `longTokens`, `Packages/VietnameseEngineFuzz` |
| ENG-T31 | Simulated field equals the engine's view; no over-deletion | `InvariantChecker`, `Simulation/SimulatedTextField.swift` | Fuzz, every corpus case |
| ENG-T32 | Restore exact; a consecutive toggle passes through, a later one gives the composed display | `InvariantChecker.checkRestore` | Fuzz, `restore-exact.tsv` |
| ENG-T33 | Determinism and replay | `InvariantChecker` (replay, pure `reduce`) | Fuzz, `FuzzTests.determinism`, `CompositionPropertyTests` |
| ENG-T34 | NFC, no combining marks, equal counts | `InvariantChecker.checkEdit` | Fuzz (Foundation NFC check in tests) |
| ENG-T35 | VNI method isolation | `InvariantChecker.checkMethodIsolation` | Fuzz (VNI combinations) |
| ENG-T36 | Escape: T + K + K ends with K | `InvariantChecker.checkEscape` | Fuzz, `OptionAndEscapeTests.doubledTransformEndsWithTheKey` |
| ENG-T37 | No non-viable composing display | `InvariantChecker.checkState` | Fuzz, `CompositionPropertyTests` |
| ENG-T40 | Benchmark replays the corpus, three typists, fuzz stream | `Benchmarks/EngineBenchmark/` (prose corpus and generated corpus typists, fuzz, bundled resources) | `Scripts/benchmark.sh`, `Benchmarks/baseline.json` |

## 13.5 Regressions

| ID | Lesson | Code | Tests |
|---|---|---|---|
| REG-01 | `qu` + tone removal crashed | `Composition/Composition+Transforms.swift` (`removeTone`) | `RegressionTests.reg01`, `crash-regressions.tsv` CR001-CR009 |
| REG-02 | Tokens over 32 keys crashed | `Composition/Composition.swift` (growable storage) | `RegressionTests.reg02`, `FuzzTests.longTokens`, `crash-regressions.tsv` CR010-CR043 |
| REG-03 | English restore off by default | `PublicAPI.swift` (defaults), `Commit/CommitRules.swift` | `RegressionTests.reg03`, B001-B007, `SpotListTests` |
| REG-04 | Quick Telex on by default | absence | `RegressionTests.reg04`, `no-shortcuts.tsv` |
| REG-05 | VNI restore emitted Telex keys | `Engine/ActiveToken.swift` | `RegressionTests.reg05`, `restore-exact.tsv` RE001-RE005 |
| REG-06 | Legacy encodings broken | `Generated/LetterTable.swift` | `RegressionTests.reg06`, Fuzz (ENG-T34) |
| REG-07 | Backspace across `", "` lost the word | `Engine/Reducer+Backspace.swift` | `RegressionTests.reg07`, `editing.tsv` ED007-ED010 |
| REG-08 | Valid words and names damaged; `uych` missing | `Orthography/RhymeInventory.swift`, `Commit/CommitRules.swift` | `RegressionTests.reg08`, `rhymes-rare.tsv`, `proper-nouns.tsv` |
| REG-09 | Keys after the coda ignored | `Composition/Composition+Transforms.swift` | `RegressionTests.reg09`, W033-W060 |
| REG-10 | `ddid` corrected to `ddi` | `Commit/CommitRules.swift` (L4) | `RegressionTests.reg10`, B015 |
| REG-11 | Wrong tone position | `Orthography/TonePlacement.swift` | `RegressionTests.reg11`, W062-W067 |
| REG-12 | `thuơ`, `ươi`/`uôi`, `thuo` + `w` | `Composition/Composition+Transforms.swift` | `RegressionTests.reg12`, W121-W130 |
| REG-13 | Stretched words lost marks | `Composition/Composition+Transforms.swift` (ENG-R416) | `RegressionTests.reg13`, W141-W150 |
| REG-14 | VNI shifted digits became marks | `Engine/TokenKey.swift` | `RegressionTests.reg14`, `layouts.tsv` LY-VN04, LY-VN05 |
| REG-15 | Brackets became `ư` / `?` | `Engine/TokenKey.swift` | `RegressionTests.reg15`, `crash-regressions.tsv` CR041 |
| REG-16 | QWERTZ `y`/`z` confusion | `PublicAPI.swift` (`KeyInput` carries characters) | `RegressionTests.reg16`, `layouts.tsv`, `LayoutCorpusTests`; real layouts in the host test (platform track) |
| REG-17 | `ĐL` restored to `DDL` | `Commit/CommitRules.swift` (L3) | `RegressionTests.reg17`, B040-B041 |
| REG-18 | First word after re-focus not restored | `Engine/Reducer.swift` | `RegressionTests.reg18` |
| REG-19 | `password` got two marks | `Composition/Composition.swift` (literal mode) | `RegressionTests.reg19`, B008 |
| REG-20 | `qw` gave `qư`; standalone `w` | `Composition/Composition+Transforms.swift` | `RegressionTests.reg20`, W039-W041 |
| REG-21 | `dda` gave `â` | `Composition/Composition+Transforms.swift` (`applyStroke`) | `RegressionTests.reg21` |
| REG-22 | No reset after the tap was re-enabled | `Engine/Reducer.swift` | `RegressionTests.reg22` |
| REG-23 | Keystrokes written to a file | whole core | `RegressionTests.reg23`, `StaticSourceTests` |
| REG-24 | Tone not re-applicable after deleting the extra key | `Composition/Composition+Rendering.swift` (ENG-R711) | `RegressionTests.reg24`, W241 |
| REG-25 | Teencode `zá` impossible | `Composition/Composition+Transforms.swift` (ENG-R411) | `RegressionTests.reg25`, W156-W157 |
| REG-26 | Misspellings accepted | `Orthography/SyllableRules.swift` | `RegressionTests.reg26`, B044-B045 |
| REG-27 | Restore lost a doubled letter | `Engine/ActiveToken.swift` (raw keys) | `RegressionTests.reg27`, `restore-exact.tsv` RE006-RE009 |
| REG-28 | `dz` onset | `Orthography/Onset.swift` | `RegressionTests.reg28`, B053-B054, `rhymes-rare.tsv` RR048 |
| REG-29 | `hẹo` restored at Space only | `Commit/CommitRules.swift` (ENG-R316) | `RegressionTests.reg29`, B055-B056 |
| REG-30 | Restore fired only on Space | `Engine/Reducer+Commit.swift` | `RegressionTests.reg30`, B057-B064, `english.tsv` EN022 |
