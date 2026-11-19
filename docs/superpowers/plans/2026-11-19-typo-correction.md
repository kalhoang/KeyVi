# Typo and spelling correction (1.1.0) implementation plan

Steps use checkbox (`- [ ]`) syntax for tracking. Revised on 19/11/2026 after the independent review of the plan;
every finding of that review is addressed in the task it names (none was found wrong).

**Goal:** At the commit of a word, {{AppName}} 1.1.0 replaces one clearly mistyped English word with the only word it
can be (`androdi` gives `android`, `gramar` gives `grammar`), offline, from bundled data, never touching Vietnamese,
with the restore key as the undo that also teaches a per-user never-correct list; on by default (D30).

**Architecture:**
- **Engine (MPL-2.0):** one more step at the commit, after the 8.1 decision and before the edit is formed
  (`Commit/TypoCorrection.swift`), reading the token alone and the resources. The edit model and the one-word rule
  run on hash lookups over preallocated sets behind a trigram prefilter, so a commit costs time proportional to the
  token's length. Five data resources (guard list as an approximate membership filter, keyboard neighbours, unmarked
  shapes, Vietnamese keyings, the existing lexicon) are built by `lexicon-builder` from pinned inputs.
- **Host (GPL-3.0-or-later):** D30 and the never-correct list live in `SettingsStore` next to the keep lists; the
  engine switch is D30 AND D4 AND the rule's `englishRestore` AND the restore key (D8 and the rule's `restoreHotkey`),
  one prebuilt engine per variant; a `neverCorrect` signal is stored at once; the undo rides the existing restore path
  (PLT-R353). No new compat rule flag, no new edit job kind.
- **Work shape:** an API stage first (types and signatures), then two tracks with disjoint file ownership (engine:
  data E1 and logic E2; app: store and host A1, UI and copy A2), then integration on `integration/1.1.0`, which is
  not merged into `main` before stable 1.0.1 ships.

**Tech Stack:** Swift 6 (strict concurrency, Swift Testing), SwiftPM packages `Packages/VietnameseEngine` and
`Packages/AppCore`, the AppKit and SwiftUI app under `App/`, Python 3 (`python3 -I`) for the reference model and the
repository checks.

**Spec:** `spec/01-engine.md` section 11A (ENG-R1110 to ENG-R1125, ENG-T50 to ENG-T57), 12.2 (the API lines of
1.1.0), 13.12 (rows S01 to S84), section 15 (Q10, Q11); `spec/03-product.md` PRD-R4A, D30, PRD-R80, PRD-R81;
`docs/superpowers/specs/2026-11-18-spelling-correction-design.md` (the approved design, with the measurements of
18/11/2026 and the alternatives rejected). Read these before any task; section numbers below refer to them.

## Global Constraints

- **Clean room (CLAUDE.md, `spec/05-clean-room.md`):** work only from `spec/` and public documentation. The QWERTY
  table is written from the public layout and its origin recorded (provenance note N6 of
  `docs/provenance/reports/2026-11-18-1.0.1.md`).
- **Decisions already taken by the product owner (18/11/2026, `docs/decisions/0009-pa-decisions-2026-11-18.md`):**
  1.1.0 is built while 1.0.1 waits out its 72 h beta; correction is on by default (D30); Q10 and Q11 stay open, so the
  recommendations are built with each choice in ONE named place (`CorrectionPolicy`, section "Q10 and Q11" below)
  and the D30 copy follows the Q10 recommendation (`từ viết hoa toàn bộ` / `words in all capitals`).
- **The switch has three defaults (section "The switch: three defaults, one rule" below):** the product's D30 is on;
  `EngineConfiguration().typoCorrection` is true (12.2); every 1.0 suite, corpus, benchmark and tool constructs its
  configuration with `typoCorrection: false` explicitly, so the 1.0 behaviour is held with the switch off
  (ENG-R1119, ENG-T54) and only the 11A suites and the host run with it on.
- **Licences and headers:** new files under `Packages/VietnameseEngine/`, `data/` and `spec/reference-model/` start
  with `// SPDX-License-Identifier: MPL-2.0` (`# SPDX-License-Identifier: MPL-2.0` as the first line of a Python
  file); everything else `GPL-3.0-or-later`. `scripts/check-spdx.sh` (in `scripts/lint.sh`) enforces it. Never edit a
  `LICENSE` file.
- **Engine rules:** standard library only in `Sources/VietnameseEngine` (`StaticSourceTests.coreIsClean`); no
  global or static mutable state (ENG-R1202); every public type `Sendable` (ENG-R1203); `Engine.reduce` pure
  (ENG-R1210); nothing logs, prints or persists text (ENG-R1220, ENG-R1121). Never use Swift's `Hasher` for anything
  that is written to a file or must agree between processes: it is seeded per process.
- **Hot path (PLT-R304, PLT-R305):** nothing new in `InputHost/Pipeline` or `InputHost/Tap` allocates, locks or does
  I/O in steady state; new state goes through the existing snapshot and notice channels.
- **Privacy:** the never-correct list and the typed words are user content: on disk and in Settings only, never in a
  log or a diagnostics report (counts only, PRD-R45, PRD-R81, PLT-R901).
- **Data (ENG-R810 to ENG-R812):** every bundled file is built by `lexicon-builder` from pinned inputs with recorded
  checksums and is byte-reproducible; the core never embeds data; the SCOWL notice covers the guard list (ENG-R811).
- **Budgets (the table "Budgets and the tests that pin them" below):** 50 µs p99 and 200 µs worst case per
  candidate commit (ENG-R1122); ENG-T40 percentiles unchanged within the benchmark's threshold (ENG-R1233); at most
  1 MB resident for the new data, 512 KB of it for the guard list, 8 MB and 50 ms for all resources (ENG-R1120,
  ENG-R1231).
- **Copy:** product copy verbatim from `spec/03-product.md` PRD-R80 and PRD-R81 (standard, neutral Vietnamese
  addressed to "bạn", PRD-R62), app name as a format argument, never the literal name (CLAUDE.md). No em dash or en
  dash anywhere: copy, comments, commit messages, this plan.
- **Wording of documents:** `scripts/tests/test_licences_and_wording.py` forbids a few words about development tools
  in `spec/` and `docs/`; `scripts/check-docs.py` requires `{{AppName}}` placeholders in `docs/` and resolvable
  relative links. New documents follow both.
- **Tests first (QA-R3), Swift Testing; coverage at least 95 % for `Sources/VietnameseEngine` and 80 % per AppCore
  module (QA-R2, `scripts/coverage.sh`).** Traceability: `Packages/VietnameseEngine/TRACEABILITY.md` needs one row per
  spec identifier (`Scripts/check-traceability.py`, `TraceabilityTests`); `docs/architecture/traceability.md` may
  cite only suites that exist (`scripts/tests/test_docs_and_workflows.py`), so a planned row names no suite in
  backticks until the suite exists.
- **Contracts:** a changed public signature in an included file is re-spliced into `docs/architecture/contracts.md`
  by `python3 -I docs/architecture/tools/sync_contracts.py` (CI runs it with `--check`).
- **Process:** English Conventional Commits, no attribution lines, no history rewriting (CLR-R12). Each track builds
  with a private scratch path: `swift build --scratch-path .build-<track>`. Integration merges with `--no-ff`.
- **On the product owner's Mac:** never launch the app or post events from a task; the tart integration run is the
  product owner's window (`docs/runbooks/`).

## Review Focus

1. **The undo after a punctuation closer.** `androdi.` gives `android.`; the restore key right after must give
   `androdi.` with the `.` untouched, in the engine (one edit over the correction and the closer) and in the host (a
   restore job whose deletion is wider than the empty active display). Tests: `TypoCorrectionUndoTests.undoAfterACloserKeepsTheCloser` (Task 15) and `KeyPipelineCorrectionTests.theUndoAfterACloserDeletesTheCloserToo` (Task 25).
2. **A reset in the middle of a line.** After a click or a focus change the history is empty, so `androdi` typed right
   after a `#`, `@` or `/` the engine never saw is a candidate and is corrected: the blind spot rule L9 already has
   (ENG-R850). Pinned, not fixed, by `TypoCorrectionContextTests.afterAResetTheWordIsACandidate` (Task 13); listed for
   the product owner.
3. **Settings files and exports from 1.0.x.** A `settings.json` or an export without `typoCorrection` and without
   `englishRestoreLists.neverCorrect` loads with D30 on and an empty list, reports nothing as changed, and a file
   written by 1.1.0 keeps its list through a 1.0.1 rewrite (PLT-R1002). Tests in Task 23.
4. **The corrected token as English evidence.** A corrected token is `en` for the window (ENG-R1116), so the
   collision word after it is decided by the English run: `androdi as` from an empty field gives `android as`, not
   `android á`. Test: `TypoCorrectionCommitTests.aCorrectedTokenCountsAsEnglishForTheRun_ENGR1116` (Task 14).
5. **Thirty-two prebuilt engines.** The catalog doubles (a `restoreHotkey` bit); every engine must share the one
   correction index and the one guard filter instead of copying them, or memory and the catalog rebuild time double.
   Test: `EngineCatalogTests.thirtyTwoEnginesShareTheCorrectionIndex` (Task 24) with the memory gate of Task 10.
6. **Every input of the switch rebuilds the engines.** `TapSettingsPublisher` rebuilds the catalog only when
   `EngineInputs` changes, and today D8 is not part of it (a hotkey change keeps the revision on purpose). D30 and
   the on/off state of D8 become engine inputs; the rule's `englishRestore` and `restoreHotkey` are catalog
   variants. Otherwise D8 switched off leaves engines that still correct with no key to undo (ENG-R1119, PRD-R80,
   row S66). Tests: `TapSettingsPublisherTests.turningTheRestoreKeyOffRebuildsWithTypoCorrectionOff` and
   `rebindingTheRestoreKeyKeepsTheRevision` (Task 24).

---

## Stages, branches, worktrees and owned paths

All worktrees live under `/Volumes/Data/Projects-2026/Kal-Key-wt/`. `main` is `7a4c06b6` (1.0.1 content merged;
`1.0.1-beta.1` published). Nothing here touches `main` until stable 1.0.1 is out.

| Stage | Branch | Worktree | Base | Runs |
|---|---|---|---|---|
| 0 API | `feat/v110-api` | `v110-api` | `main` at `7a4c06b6` | first, alone; reviewed, then `integration/1.1.0` is created from its head |
| E1 data | `feat/v110-engine-data` | `v110-engine-data` | `integration/1.1.0` | in parallel with E2a, A1, A2 |
| E2 logic | `feat/v110-engine-logic` | `v110-engine-logic` | `integration/1.1.0` | E2a (Tasks 11 to 18) in parallel; E2b (Tasks 19 to 22) after E1 is merged into `integration/1.1.0` and `integration/1.1.0` is merged into this branch (Task 19 Step 0) |
| A1 store and host | `feat/v110-app-host` | `v110-app-host` | `integration/1.1.0` | in parallel |
| A2 UI and copy | `feat/v110-app-ui` | `v110-app-ui` | `integration/1.1.0` | in parallel |
| Integration | `integration/1.1.0` | `v110-integration` | API head | merges in the order API, E1, A1, A2, E2a, E2b, then Tasks 31 to 36 |

How the branches get each other's work (CLR-R12: merges only, never a rebase): a track that needs another track's
merged result runs `git merge --no-ff integration/1.1.0` in its own worktree (E2 before Task 19). `main` is merged
into `integration/1.1.0` with `--no-ff` whenever a 1.0.1 fix lands during the beta (one did on 19/11/2026) and once
more at the stable 1.0.1 tag before any 1.1.0 beta (Task 36), so the 1.1.0 gates never run on a stale 1.0.1.
Nothing is merged into `main` before stable 1.0.1 ships (ADR 0009: 1.1.0 is built during the 72 h beta).

Ownership (edit only your paths; anything else is read-only and a request in your report):

| Track | Owned paths |
|---|---|
| 0 API | `Packages/VietnameseEngine/Sources/VietnameseEngine/PublicAPI.swift`, `Sources/VietnameseEngine/Commit/ApproximateWordSet.swift` (new), `Sources/VietnameseEngine/Commit/CorrectionPolicy.swift` (new, constants only), `Sources/VietnameseEngine/Commit/CommitRules.swift` (the `.corrected` arms of `CommitDecision.rule` and `restores`), `Sources/VietnameseEngineData/Bundled.swift` (signatures), `Sources/VietnameseEngineTesting/Fuzz/InvariantChecker.swift` and `Sources/site-demo-frames/FrameRecorder.swift` (the new enum cases only), `Tests/CollisionCorpusTests/Harness/CorpusScore.swift` (same), the `typoCorrection: false` sweep of Task 1 Step 4 (every `EngineConfiguration(` call site under `Sources/VietnameseEngineTesting/**`, `Sources/site-demo-frames/**`, `Benchmarks/**` and `Tests/**` of the engine package: that argument only), `Tests/VietnameseEngineTests/Quality/{PublicAPITests,StaticSourceTests}.swift`, `Tests/VietnameseEngineTests/Commit/ApproximateWordSetTests.swift` (new), `Tests/VietnameseEngineTests/Corpus/typo-corrections.tsv` (new, handed to E2), `Tests/VietnameseEngineDataTests/RealData/TypoCorrectionExampleTests.swift` (new, handed to E2), `Tests/VietnameseEngineDataTests/BundledResourcesTests.swift` (Task 2's test only); `Packages/AppCore/Sources/SettingsStore/{UserSettings,SettingFields}.swift`, `Packages/AppCore/Sources/InputHost/Snapshots/Snapshots.swift`, `Packages/AppCore/Sources/InputHost/Integration/LearningTracker.swift` (compile only), the AppCore call sites of Task 3 Step 3 (that argument only), `Packages/AppCore/Sources/TraceScanCore/Replay.swift` (the switch it derives and the identity's configuration, Task 3 Step 3), `Packages/AppCore/Tests/SettingsStoreTests/{TypoCorrectionDefaultTests,ExplicitSettingKeysTests}.swift`, `Packages/AppCore/Tests/TraceScanTests/ReplayTypoCorrectionTests.swift` (new); `scripts/tests/test_correction_policy.py` (new) and its name in `scripts/tests/run.sh`; `Sources/VietnameseEngine/Commit/TokenLanguage.swift` (the `.corrected` arm only, ENG-R1116, so that its switch compiles); `spec/01-engine.md` 12.2 (the amendments listed under "Interfaces between tracks") and 13.12 (the S46 reason and the re-check sentence, Task 4 Step 3) |
| E1 | `data/**`, `Packages/VietnameseEngine/Sources/lexicon-builder/**`, `Sources/VietnameseEngineData/**`, `Sources/VietnameseEngineTesting/Oracle/KeyingOracle.swift` (new: the independent keying computation of Task 10), `Tests/VietnameseEngineDataTests/{Builder/**,BundledResourcesTests.swift,MalformedResourceTests.swift,LexiconBuilderTests.swift,CorrectionDataTests.swift}`, `Packages/VietnameseEngine/README.md`, `spec/reference-model/correction*.py` and its `README.md`, `THIRD_PARTY_NOTICES.md` (the SCOWL rows), `docs/decisions/0203-correction-data.md` (new) |
| E2 | `Sources/VietnameseEngine/Commit/{TypoCorrection,EditModel,CorrectionIndex}.swift` (new), `Sources/VietnameseEngine/Commit/{CorrectionPolicy,CommitRules,TokenLanguage}.swift`, `Sources/VietnameseEngine/Engine/**`, `Sources/VietnameseEngine/PublicAPI.swift` (the `Resources` index only, after the API stage), `Sources/VietnameseEngineTesting/**` (except the API stage's enum edits and E1's `KeyingOracle.swift`), `Benchmarks/**`, `Scripts/benchmark.sh`, `Tests/VietnameseEngineTests/**`, `Tests/VietnameseEngineDataTests/RealData/TypoCorrection*.swift`, `Packages/VietnameseEngine/TRACEABILITY.md`, `Packages/VietnameseEngine/CHANGELOG.md` (E1 reports its rows and entries to E2) |
| A1 | `Packages/AppCore/Sources/SettingsStore/**` (after the API stage), `Packages/AppCore/Sources/InputHost/**`, `Packages/AppCore/Sources/Diagnostics/**`, `Packages/AppCore/Sources/TraceScanCore/**` and `Packages/AppCore/Tests/TraceScanTests/**` (Task 24: replay follows the host mapping), `Packages/AppCore/Sources/ShellCore/DevRecorderShell.swift` (the recorded `typoCorrection` value only, Task 24), `Packages/AppCore/Sources/ShellCore/ReportAssembly.swift`, `Packages/AppCore/Sources/TestSupport/Pipeline/ScriptedEngine.swift`, `Packages/AppCore/Sources/TestSupport/Fakes/Diagnostics/DiagnosticsFixtures.swift` (the new keys), `Packages/AppCore/Tests/{SettingsStoreTests,InputHostTests,DiagnosticsTests}/**`, `docs/decisions/0323-never-correct-list.md` (new), `docs/architecture/traceability.md` (the host rows), `docs/architecture/contracts.md` (re-spliced for A1's own included files, Task 27; Integration re-runs the tool) |
| A2 | `Packages/AppCore/Sources/ShellCore/**` (except `ReportAssembly.swift` and A1's line of `DevRecorderShell.swift`), `App/Sources/Settings/**`, `App/Resources/Localization/Settings.xcstrings`, `Packages/AppCore/Tests/ShellCoreTests/**`, `scripts/snapshots/SettingsSnapshots/SnapshotFixtures.swift`, `scripts/tests/test_correction_policy.py` (the catalog half, Task 29). The UI halves of the PRD-R80 and PRD-R81 rows of `docs/architecture/traceability.md` are filled by Task 33, not by A2 |
| Integration | everything above after the merges, plus `docs/architecture/contracts.md`, `CHANGELOG.md`, `CHANGELOG.vi.md`, `docs/provenance/**`, `Benchmarks/baseline.json`, `Benchmarks/results/**` |

Frozen for every track: `Packages/*/Package.swift`, `project.yml`, `Config/**`, `compat/**`, `App/Info.plist`,
`Packages/AppCore/Sources/AppModel/**`, `Packages/AppCore/Sources/TestSupport/Fakes/Common/**`.

## Interfaces between tracks

The contract every track builds against, fixed by the API stage (Tasks 1 to 5) and copied from spec 12.2 where it
fixes them. The API stage amends 12.2 in five places, all in Task 1 Step 3 and recorded again in ADR 0203 (Task 9):
(1) a new public type `ApproximateWordSet`; (2) `CorrectionData.guardList` is an `ApproximateWordSet` (12.2 writes
`WordSet` with a comment that it may answer yes for a word it lacks, which `WordSet` cannot); (3) `CorrectionData`'s
fields are `let` and it gains a public memberwise `init` (12.2 has `var` fields and no init: the engine derives an
index from these fields, so they change only through `Resources.correction`, whose `didSet` rebuilds the index);
(4) `EngineConfiguration.init` gains `typoCorrection: Bool = true` (12.2 lists the property but not the parameter);
(5) `vietnameseKeyings` is generated by the builder and never empty (12.2 says it MAY be empty when a parser computes
them); the parser is the named fallback of Task 10 and, if it is ever taken, 12.2 is amended again.

```swift
// Packages/VietnameseEngine/Sources/VietnameseEngine/PublicAPI.swift (MPL-2.0)
public struct EngineConfiguration: Sendable, Hashable {
    public var typoCorrection: Bool                      // default true (ENG-R1119)
    public init(inputMethod: InputMethod = .telex(TelexOptions()), toneStyle: ToneStyle = .traditional,
                autoRestore: Bool = true, appContext: AppContext = .general, historyLimit: Int = 16,
                lookaheadRevision: Bool = true, lineStartRevision: Bool = true, typoCorrection: Bool = true)
}
public enum CommitDecision: Sendable, Hashable { case kept(CommitRule), restored(CommitRule), macro, corrected(CommitRule) }
public enum LearningSignal: Sendable, Hashable { case preferredRaw(raw: String), preferredVietnamese(raw: String), neverCorrect(raw: String) }

// Packages/VietnameseEngine/Sources/VietnameseEngine/Commit/ApproximateWordSet.swift (new, stdlib only)
/// A Bloom filter over lowercase words: never a false "no", at most the configured false "yes" rate (ENG-R1120).
public struct ApproximateWordSet: Sendable {
    public init(bits: [UInt64], hashCount: Int, wordCount: Int)             // from the bundled file; bits.count a power of two
    public init<S: Sequence>(exactly words: S, bitsPerWord: Int = 12, hashCount: Int = 8) where S.Element == String
    public init<S: Sequence>(exactly words: S, bitCount: Int, hashCount: Int) where S.Element == String   // the builder's choice of size
    public func mayContain(_ word: some StringProtocol) -> Bool
    package func mayContain<Bytes: Sequence>(utf8 bytes: Bytes) -> Bool where Bytes.Element == UInt8   // no String allocation (ENG-R1122)
    public var bits: [UInt64] { get }; public var hashCount: Int { get }; public var wordCount: Int { get }
    public static let empty: ApproximateWordSet                              // answers false for every word
}
// Hashing: FNV-1a 64 over the UTF-8 bytes gives h1; h2 = h1 rotated left by 32 bits, forced odd; the i-th index is
// (h1 &+ UInt64(i) &* h2) & (bitCount - 1). Written once here, used by the builder (via the type) and the loader.

public struct CorrectionData: Sendable {                                     // ENG-R1120
    public let guardList: ApproximateWordSet                                 // SCOWL words 40 to 70 and proper names 10 to 70, minus the lexicon
    public let keyboardNeighbours: [Character: String]                       // the QWERTY table of ENG-R1113, 26 entries, symmetric
    public let unmarkedShapes: WordSet                                       // Tier A and B syllables, marks and stroke removed (ENG-R1110 (d))
    public let vietnameseKeyings: WordSet                                    // usual-order Telex keyings of Tier A syllables (ENG-R1125)
    public init(guardList: ApproximateWordSet, keyboardNeighbours: [Character: String], unmarkedShapes: WordSet, vietnameseKeyings: WordSet)
    public static let empty: CorrectionData
}
// `let`, not `var` (amendment 3 above): the engine derives an index from these; they change through `Resources.correction`.

public struct Resources: Sendable {
    public var userNeverCorrect: WordSet                                     // ENG-R1118
    public var correction: CorrectionData                                    // ENG-R1120
    public init(english:techAlways:techCodeOnly:techCodeCapitalized:attestedSyllables:ambiguity:userKeepRaw:userKeepVietnamese:
                macros: MacroTable = .empty, collision: CollisionLists = .empty, collisionMemory: CollisionMemorySnapshot = .empty,
                userNeverCorrect: WordSet = WordSet([]), correction: CorrectionData = .empty)
    package private(set) var correctionIndex: CorrectionIndex               // E2 (Task 12): built at the end of init from english,
    // techAlways and correction, and rebuilt by a `didSet` on exactly those three fields (the host assigns the user lists,
    // the macros and the memory after loading, EngineBridge.resources and EngineSettingsMapping.resources; those keep the
    // object, so the 32 engines of a catalog share one index). A stale index is impossible by construction: the same
    // prefilter gates the ENG-R1125 pass, so a stale one would not only miss corrections but also let `pahir` become `pair`.
}

// Packages/VietnameseEngine/Sources/VietnameseEngineData/Bundled.swift
extension Resources {
    public static func bundled(userKeepRaw: WordSet, userKeepVietnamese: WordSet, macros: MacroTable = .empty,
                               collisionMemory: CollisionMemorySnapshot = .empty, userNeverCorrect: WordSet = WordSet([])) throws -> Resources
    public static func load(from directory: URL, userKeepRaw: WordSet, userKeepVietnamese: WordSet, macros: MacroTable = .empty,
                            collisionMemory: CollisionMemorySnapshot = .empty, userNeverCorrect: WordSet = WordSet([])) throws -> Resources
}
```

Host side (API stage, so A1 and A2 compile against the same model):

```swift
// Packages/AppCore/Sources/SettingsStore/UserSettings.swift (GPL-3.0-or-later)
public struct UserSettings { public var typoCorrection: Setting<Bool> = .unset   // D30 "typoCorrection"
                             public var neverCorrect: Set<String> = [] }         // ENG-R1118, "englishRestoreLists.neverCorrect"
public struct EffectiveSettings { public var typoCorrection: Bool; public var neverCorrect: Set<String> }
// DefaultSettings.v1: typoCorrection: true (D30, decision of the product owner, 18/11/2026, ADR 0009 item 10)
// SettingFields.all: field("typoCorrection", \.typoCorrection, .typing)  // D30
// SettingListKey.neverCorrect = "neverCorrect"
public enum NeverCorrectEntry { public static func normalized(_ text: String) -> String?   // lowercase a-z only, 1 to 64 letters, else nil (PRD-R81)
                                public static let maximumLength = 64 }

// Packages/AppCore/Sources/InputHost/Snapshots/Snapshots.swift
public struct EngineVariant { public var restoreHotkey: Bool   // the rule's `features.restoreHotkey` (ENG-R1119); default true
                              public init(appContext:englishRestore:macros:lookaheadRevision: Bool = true, restoreHotkey: Bool = true) }

// Packages/AppCore/Sources/TraceScanCore/Replay.swift (API stage): replay rebuilds the switch from the recorded inputs with
// the host's conjunction; a settings line without `typoCorrection` (D30) replays with it off (Task 3 Step 3, Task 24).
extension ReplayEngineFactory { static func typoCorrection(settings: [String: String], focus: TraceLine?) -> Bool }

// Packages/AppCore/Sources/InputHost/Integration/TapSettingsPublisher.swift (A1, Task 24): the inputs of the switch that
// are not catalog variants become engine inputs, so a change rebuilds the catalog and bumps its revision (Review Focus 6).
public struct EngineInputs { public var typoCorrection: Bool        // D30
                             public var restoreKeyEnabled: Bool     // D8 on or off (`settings.restoreHotkey != nil`); the binding itself stays out
                             public var neverCorrect: Set<String> } // ENG-R1118, per user (not per app); content, never logged
```

Engine internals that E2 produces and the tests of E2 and the benchmark consume (package access):

```swift
// Sources/VietnameseEngine/Commit/CorrectionPolicy.swift: the ONE place for each open choice (created by the API stage,
// Task 1, so that every track and `scripts/tests/test_correction_policy.py` read the same file from the start)
package enum CorrectionPolicy {
    package enum SentenceStart { case corrected, neverCorrected }
    package static let sentenceStart: SentenceStart = .corrected                       // Q10 recommendation
    package enum CommitKeys { case everyCommitKey, spaceAndPunctuationOnly }
    package static let commitKeys: CommitKeys = .everyCommitKey                        // Q11 recommendation
    package static let minimumLetters = 5, maximumLetters = 24, minimumFitLetters = 4   // ENG-R1111, ENG-R1114
    package static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\""]   // ENG-R1112 (plus whitespace, Return, Tab per `commitKeys`)
    package static let openers: Set<Character> = [" ", "\u{00A0}", "(", "[", "{", "\"", "\u{201C}", "\u{2018}", "'"]
    package static let clusterOnsets: Set<String> = ["bl", "br", "dr", "đr", "gl", "gr", "kl", "kr", "pl", "pr"]   // ENG-R1110 (b)
}
// Sources/VietnameseEngine/Commit/EditModel.swift
package struct EditModel: Sendable {              // a plain value: neighbours table only, no stored scratch (ENG-R1202, ENG-R1203)
    package init(neighbours: [Character: String])
    /// Calls `body` with every word at distance one (ENG-R1113; `positionRules: false` for ENG-R1125); stops when it returns false.
    /// The scratch buffer is a stack allocation inside the call (`withUnsafeTemporaryAllocation`, 32 bytes), never a stored array.
    package func forEachEdit(of word: UnsafeBufferPointer<UInt8>, positionRules: Bool, _ body: (UnsafeBufferPointer<UInt8>) -> Bool)
}
// Sources/VietnameseEngine/Commit/CorrectionIndex.swift
package final class CorrectionIndex: Sendable {   // let properties only (ENG-R1203)
    package init(english: WordSet, techAlways: WordSet, correction: CorrectionData)
    package func mightHold(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool    // trigram and edge-bigram prefilter
    /// Membership in the correction lexicon (`english` plus the letter-only `techAlways` entries of at least 4 letters),
    /// keyed by bytes: an open-addressing table of FNV-1a hashes verified against a packed byte store, so a lookup
    /// allocates nothing at any length (`WordSet.contains` takes a `String`, which allocates above 15 bytes; it is used
    /// once per commit for the token itself, never per edit).
    package func lexiconContains(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool
    package func isVietnameseKeyingOrShape(_ candidate: UnsafeBufferPointer<UInt8>) -> Bool   // ENG-R1125, same byte-keyed store
    package static let empty: CorrectionIndex
}
// Sources/VietnameseEngine/Commit/TypoCorrection.swift
package struct Correction: Sendable, Hashable { package let text: String; package let rule: CommitRule }
package struct TypoCorrector: Sendable {
    package init(resources: Resources, configuration: EngineConfiguration)
    package func correction(for inputs: CommitInputs, decision: CommitDecision, token: ActiveToken, context: CommitContext) -> Correction?
}
// CommitContext gains `characterBefore: Character?` (the boundary right before the token, nil at the start of the history).
// CommitPolicy gains `let corrector: TypoCorrector?` (nil when `typoCorrection` is off, `appContext == .code`, or `autoRestore`
// is off: ENG-R802, the English data is not consulted; the host ANDs D4 in anyway, ENG-R1119, so this only protects
// consumers that build their own configuration, such as the onboarding "try it" field and the learned-choices preview).
```

## Budgets and the tests that pin them

| Budget | Value | Pinned by |
|---|---|---|
| Per candidate commit (ENG-R1122) | p99 at most 50 µs, worst case at most 200 µs, release build, baseline machine, bundled data, adversarial 24-letter candidates included in the maximum | ENG-T55: `engine-benchmark` workload `correction` (Task 17 writes it; Task 22 Step 2 runs the gated release run after E1's data is merged), gate in `Scripts/benchmark.sh`; debug sanity `EngineBenchmarkTests.candidateLatency` |
| ENG-T40 percentiles (ENG-R1233) | switch on and off differ by less than the benchmark threshold | `Scripts/benchmark.sh` runs the prose and fuzz workloads with `--typo-correction off` (the default, comparable with `Benchmarks/baseline.json`) and `on` (Task 17, run in Task 22) |
| New data resident (ENG-R1120) | at most 1 MB together; guard list at most 512 KB | `BundledResourcesTests.correctionDataStaysWithinItsResidentBudget` (Task 10) |
| All resources (ENG-R1231) | at most 8 MB resident, loads in at most 50 ms | `BundledResourcesTests.staysWithinLoadTimeAndMemoryBudget` (existing, re-run in Task 10) |
| Guard list false positives (ENG-R1120) | at most 0.5 % of 100,000 random letter strings | `CorrectionDataTests.guardListFalsePositivesStayUnder0_5Percent` (Task 10) |
| Correction targets (ENG-R1124) | the table of 11A.4 | ENG-T51 to ENG-T53, ENG-T57 (Tasks 19 to 21) |
| Coverage (QA-R2) | engine at least 95 %, AppCore modules at least 80 % | `scripts/coverage.sh` (Task 35) |

## The switch: three defaults, one rule

- **Product:** D30 is on (ADR 0009 item 10). The engine never sees D30 alone: it gets D30 AND D4 AND the rule's
  `englishRestore` AND the rule's `restoreHotkey` AND D8 on (ENG-R1119). Pinned by
  `TypoCorrectionDefaultTests.theShippedDefaultIsOn_D30` (Task 3) and
  `EngineBridgeConfigurationTests.typoCorrectionIsD30AndD4AndTheRuleSwitchesAndTheRestoreKey_ENGR1119` (Task 24).
- **Engine API:** `EngineConfiguration().typoCorrection == true` (12.2, ENG-R1119): a consumer that says nothing gets
  the correction. Pinned by `PublicAPITests.defaults` (Task 1).
- **The 1.0 suites, corpora, benchmark and tools:** the rule is that every `EngineConfiguration(` in the engine package
  outside `Sources/VietnameseEngine` names `typoCorrection:` explicitly (the one exception is `PublicAPITests.defaults`,
  which asserts the default). The 1.0 ones say `false`: the QA corpus (`QACorpus`), the worked examples of 13.8, 13.9
  and 13.10 (`SpecExamples`), the generated corpus, `SpotList`, the 1.0 fuzz combinations (`FuzzCampaign.all`), the
  1.0 corpus targets (`CorpusTargets`), the `RealData` suites, the W11 harness (`FixtureRuns`, `MemorySimulation`),
  the ENG-T40 workloads of `Benchmarks/` (comparable with `Benchmarks/baseline.json`, measured on 1.0) and
  `site-demo-frames` (the committed `site/demo/frames.json` stays the 1.0 rendering; showing the correction on the
  website is a website decision outside this plan). The 11A suites say `true`. Pinned by
  `StaticSourceTests.everyConfigurationOutsideTheCoreNamesTheSwitch` (Task 1 Step 4), which scans those directories.
  The AppCore call sites outside `EngineSettingsMapping` that build their own engine (the `EngineBridge` fallback engine,
  `LearnedChoices` and the tests that compare configurations) say `false` too (Task 3). Two places must not diverge
  from the live engines, so they do not take a constant (review of 19/11/2026, MEDIUM):
  - **Replay** (`TraceScanCore/Replay.swift`) rebuilds each segment's engine from the recorded settings and focus, so
    it derives the switch with the same ENG-R1119 conjunction the host passes, over the recorded inputs
    (`ReplayEngineFactory.typoCorrection(settings:focus:)`: the recorded D30 AND D4 AND the rule's `englishRestore`
    AND D8 set). A settings line without `typoCorrection` was written by engines that never corrected (1.0.x, and 1.1.0
    while the host passes the API stage's placeholder), so it replays with the switch off, which is the placeholder's
    value. Pinned by `ReplayTypoCorrectionTests`. Replay follows the host mapping from then on: Task 24 records D30
    and the rule's `restoreHotkey` and reads the latter in replay.
  - **The engine identity of dev traces** (`DevEngineIdentity+Engine` on the recorder's side,
    `ReplayEngineFactory.identity` on the scanner's) digests the engine with the product's default configuration,
    so it says `true`: an identity computed with the switch off would stay the same across builds whose correction
    differs, and replay would report rule changes as divergences (ADR 0007 decision 13). Task 24 adds probes that
    exercise the correction.
  - `lexicon-builder`'s `EngineTyper` (`Sources/lexicon-builder/AmbiguityCandidates.swift`, E1) is outside the scanned
    directories and still says nothing: it reads the active display of one token over empty resources, which the
    switch cannot change. E1 may name `typoCorrection: false` there for uniformity.
- **What runs with the switch on, per the spec:** ENG-T50 (the 13.12 rows, Task 19), ENG-T51 (the prose, unmarked
  prose, generated and W11 corpora and the word lists, re-run with the bundled data counting `corrected` outputs,
  Task 20), ENG-T52, ENG-T53 and ENG-T57 (Tasks 20 and 21), ENG-T54 (the fuzz on-half with fixture data in Task 16 and
  with the bundled data in Task 22) and ENG-T55 (Tasks 17 and 22). Everything else holds the 1.0 behaviour with the
  switch off, as ENG-R1119 and ENG-T54 ask.

## Q10 and Q11: one named place each

`Sources/VietnameseEngine/Commit/CorrectionPolicy.swift` (API stage, Task 1) is the ONE place:
`CorrectionPolicy.sentenceStart = .corrected` (Q10) and `CorrectionPolicy.commitKeys = .everyCommitKey` (Q11). Every
dependent either reads the constant or is checked against it; none carries the choice on its own.

| Dependent | How it follows the constant |
|---|---|
| `TypoCorrector` (Task 13) | reads it |
| `typo-corrections.tsv` rows S23 and S24 (Q10), S26 (Q11) | the `note` column carries `q10:<alternative text>` or `q11:<alternative text>`; `rowsWithTheSwitchOn` asserts `expected` under the recommendation and the alternative otherwise (Tasks 4 and 19). 13.12 has no Tab row and the fixture holds exactly the spec's rows, so Tab is kept by `theDecisionIsTheSameAtEveryCommittingKey_Q11`, which reads `commitKeys` (Task 14) |
| spec 13.12 rows S23, S24, S26, the ENG-R1111 and ENG-R1116 sentences, the section 15 answers | `TypoCorrectionExampleTests.theSpecRowsFollowThePolicy` (Task 4): the spec row's text is the corrected form exactly when the constant is the recommendation |
| PRD-R80 and the D30 row of `spec/03-product.md` (`từ viết hoa toàn bộ` / `words in all capitals`), the two String Catalog values (`settings.typing.typoCorrection.explanation*`), the `SpecDraftCopyTests` table | `scripts/tests/test_correction_policy.py` (Task 1; the catalog half added in Task 29) parses `sentenceStart` from the Swift file with a regular expression and asserts the matching words in the spec and, once the keys exist, in `Settings.xcstrings`; `SpecDraftCopyTests` pins the catalog to the spec text |

Flipping Q10 is: the constant (one line), then each keeper above goes red until its own file follows: the ENG-R1111
sentence, rows S23 and S24 and the Q10 answer in `spec/01-engine.md`; `expected` of S23 and S24 in the fixture
(swapped with the note); PRD-R80 and the D30 row in `spec/03-product.md`; the two catalog values and the
`SpecDraftCopyTests` table. Flipping Q11 is: the constant; the ENG-R1116 and ENG-R1112 sentences, row S26 and the Q11
answer; the fixture rows. The decision record of the answer lists exactly these files, so the flip is a short,
checked edit rather than a search.

---

## Stage 0: API (`feat/v110-api`)

### Task 1: Engine public types

**Files:**
- Modify: `Packages/VietnameseEngine/Sources/VietnameseEngine/PublicAPI.swift`
- Create: `Packages/VietnameseEngine/Sources/VietnameseEngine/Commit/ApproximateWordSet.swift`, `Sources/VietnameseEngine/Commit/CorrectionPolicy.swift` (the constants of "Interfaces between tracks", nothing else; E2 owns the file afterwards)
- Modify: `Packages/VietnameseEngine/Sources/VietnameseEngine/Commit/CommitRules.swift` (`CommitDecision.rule` and `restores` cover `.corrected`)
- Modify: `Packages/VietnameseEngine/Sources/VietnameseEngineTesting/Fuzz/InvariantChecker.swift` (`count`, `digest`: a `.corrected?` arm), `Packages/VietnameseEngine/Sources/site-demo-frames/FrameRecorder.swift` (`outcome` `"corrected"`, rule name as for `kept`), `Packages/VietnameseEngine/Tests/CollisionCorpusTests/Harness/CorpusScore.swift` (`"corrected"`)
- Modify (Step 4, the `typoCorrection: false` sweep): every `EngineConfiguration(` call site under `Sources/VietnameseEngineTesting/**`, `Sources/site-demo-frames/**`, `Benchmarks/**`, `Tests/VietnameseEngineTests/**`, `Tests/VietnameseEngineDataTests/**`, `Tests/CollisionCorpusTests/**` and `Tests/SiteDemoFramesTests/**` (about a hundred, most of them `EngineConfiguration()`)
- Create: `scripts/tests/test_correction_policy.py`
- Modify: `spec/01-engine.md` 12.2 (the five amendments named under "Interfaces between tracks")
- Test: `Packages/VietnameseEngine/Tests/VietnameseEngineTests/Quality/PublicAPITests.swift`, `Tests/VietnameseEngineTests/Quality/StaticSourceTests.swift`, `Tests/VietnameseEngineTests/Commit/ApproximateWordSetTests.swift`

**Interfaces:** Produces every engine signature of "Interfaces between tracks" except `correctionIndex`, with
`typoCorrection` read by nobody yet (E2 wires it), and `CorrectionPolicy` read by nobody yet.

- [x] **Step 1: Write the failing tests.**
  - `PublicAPITests.defaults`: add `#expect(EngineConfiguration().typoCorrection == true)`; `conformances`: `requireSendable(CorrectionData.self)`, `requireSendable(ApproximateWordSet.self)`, `requireHashable(CommitDecision.self)` still passes with the new case.
  - `PublicAPITests.resourcesCarryTheNeverCorrectListAndCorrectionData`: `Resources.empty.userNeverCorrect.contains("androdi") == false`, `Resources.empty.correction.keyboardNeighbours.isEmpty`.
  - `ApproximateWordSetTests.neverForgetsAWordItWasBuiltFrom`: 10,000 random lowercase words, `mayContain` true for each.
  - `ApproximateWordSetTests.falsePositivesStayUnderTheRate`: built from 100,000 random words with `bitsPerWord: 12`, 100,000 other random words give at most 0.5 % true.
  - `ApproximateWordSetTests.bitsRoundTripAndAreDeterministic`: `ApproximateWordSet(bits: a.bits, hashCount: a.hashCount, wordCount: a.wordCount)` answers like `a`; two builds from the same words give equal `bits` (no process seed).
  - `ApproximateWordSetTests.emptyAnswersNo`: `ApproximateWordSet.empty.mayContain("android") == false`.
  - `StaticSourceTests.everyConfigurationOutsideTheCoreNamesTheSwitch`: for every `EngineConfiguration(` in the directories of the sweep (the balanced argument text of each call), the arguments name `typoCorrection:`; the only exemption is the `defaults` test of `PublicAPITests.swift`. Red until Step 4.
  - `scripts/tests/test_correction_policy.py` (run by `scripts/tests/run.sh`): reads `sentenceStart` and `commitKeys` from `CorrectionPolicy.swift` with a regular expression; asserts that PRD-R80 and the D30 row of `spec/03-product.md` say `từ viết hoa toàn bộ` and `words in all capitals` when `sentenceStart` is `.corrected` (`từ viết hoa` and `capitalised words` otherwise), that rows S23 and S24 of `spec/01-engine.md` read `Android ` and `xong. Receive ` in that case (`Androdi ` and `xong. Recieve ` otherwise), and that row S26 reads `android` and the Return when `commitKeys` is `.everyCommitKey` (`androdi` otherwise); the `Settings.xcstrings` half is added in Task 29 and skips while the key is absent.
- [x] **Step 2: Run them and see them fail.** `swift test --package-path Packages/VietnameseEngine --scratch-path .build-api --filter "PublicAPITests|ApproximateWordSetTests|StaticSourceTests"`. Expected: compile errors for the missing members.
- [x] **Step 3: Implement** the types as written in "Interfaces between tracks" and the five 12.2 amendments (`ApproximateWordSet`; `guardList`'s type; `let` fields and the public init of `CorrectionData`; the `typoCorrection` init parameter; keyings generated, never empty). `bitCount` is `bits.count * 64`, a power of two; `init(exactly:)` picks the smallest power of two at or above `bitsPerWord * words.count` (at least 64 bits). `CommitDecision.rule` returns the rule for `.corrected`; `restores` stays false for it. The doc comment of `typoCorrection` says what the host passes (ENG-R1119) and that the engine also leaves the corrector out with `autoRestore` off (ENG-R802).
- [x] **Step 4: The sweep and the exhaustive switches.** Pass `typoCorrection: false` at every call site named under Files (a scripted edit, reviewed by eye: the argument goes last, Swift's declared order; multi-line calls such as `FuzzCampaign.all` and `SpecExamples` by hand). Fix every exhaustive switch the new cases break (the files listed above). Run the whole engine test suite. Expected: green, with every suite's behaviour unchanged; `StaticSourceTests.coreIsClean` green (no Foundation in the new files); `everyConfigurationOutsideTheCoreNamesTheSwitch` green; `swift run site-demo-frames --check` green (the frames are the 1.0 rendering).
- [x] **Step 5: Commit.** `feat(engine): add the typo correction API of spec 11A`

### Task 2: Data loader signatures

**Files:**
- Modify: `Packages/VietnameseEngine/Sources/VietnameseEngineData/Bundled.swift`
- Test: `Packages/VietnameseEngine/Tests/VietnameseEngineDataTests/BundledResourcesTests.swift`

- [x] **Step 1: Write the failing test** `BundledResourcesTests.passesTheNeverCorrectListThrough`: `Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]), userNeverCorrect: WordSet(["androdi"]))` has `userNeverCorrect.contains("androdi")` and `correction.keyboardNeighbours.isEmpty` (E1 fills it).
- [x] **Step 2: Run it, see it fail to compile.**
- [x] **Step 3: Add the `userNeverCorrect` parameter to `bundled` and `load(from:)`, passing `correction: .empty`.**
- [x] **Step 4: Run `swift test --filter VietnameseEngineDataTests`.** Expected: green.
- [x] **Step 5: Commit.** `feat(data): accept the never-correct list in Resources.bundled`

### Task 3: Host model types (D30, the list, the variant bit)

**Files:**
- Modify: `Packages/AppCore/Sources/SettingsStore/UserSettings.swift`, `Packages/AppCore/Sources/SettingsStore/SettingFields.swift`
- Create: `Packages/AppCore/Sources/SettingsStore/NeverCorrectEntry.swift`
- Modify: `Packages/AppCore/Sources/InputHost/Snapshots/Snapshots.swift` (`EngineVariant.restoreHotkey`, default true, `default` variant true)
- Modify: `Packages/AppCore/Sources/InputHost/Integration/LearningTracker.swift` (`LearningProposal.init(_:app:)` becomes failable, `nil` for `.neverCorrect`; `note` returns nil for it; A1 adds the real routing)
- Test: `Packages/AppCore/Tests/SettingsStoreTests/TypoCorrectionDefaultTests.swift` (new)

**Interfaces:** Produces the host signatures of "Interfaces between tracks".

- [x] **Step 1: Write the failing tests** (`@Suite struct TypoCorrectionDefaultTests`):
  - `theShippedDefaultIsOn_D30`: `DefaultSettings.v1.typoCorrection == true`; `UserSettings().resolved().typoCorrection == true`.
  - `theKeyIsTypoCorrectionInTheTypingGroup`: `SettingFields.all.first { $0.key == "typoCorrection" }?.group == .typing`.
  - `entriesAreLowercaseLettersOnly_PRDR81`: `NeverCorrectEntry.normalized(" Androdi ") == "androdi"`, nil for `"android1"`, `"well-known"`, `"việt"`, `""`, a 65-letter word.
  - `explicitlySetKeysNameTheListNeverItsContent`: with `neverCorrect = ["androdi"]`, `explicitlySetKeys` contains `"neverCorrect"` and no element contains `"androdi"`.
- [x] **Step 2: Run them** (`swift test --package-path Packages/AppCore --scratch-path .build-api --filter TypoCorrectionDefaultTests`), see them fail to compile.
- [x] **Step 3: Implement**: the two `UserSettings` fields, the `EffectiveSettings` fields and `resolved(over:)`, the `DefaultSettings.v1` value, the `SettingFields` row, `SettingListKey.neverCorrect`, `explicitlySetKeys` (the list after `learnedWords`), `NeverCorrectEntry`, the `EngineVariant` field, the `LearningTracker` compile fix. The AppCore half of the sweep: `typoCorrection: false` at the `EngineConfiguration(` call sites outside `EngineSettingsMapping.swift` that build their own engine (`InputHost/Engine/EngineBridge.swift` fallback engine, `ShellCore/Settings/LearnedChoices.swift`, and in `Packages/AppCore/Tests` the sites that build or compare configurations: `EngineBridgeTests`, `LookaheadRevisionContinuationTests`, `OnboardingTryItContentTests`, `TraceBuilder`). Replay does not hard-code the switch (review of 19/11/2026): `ReplayEngineFactory.engine(settings:focus:)` passes `typoCorrection: Self.typoCorrection(settings:focus:)`, the ENG-R1119 conjunction over the recorded D30, D4, rule `englishRestore` and D8, which is off for every trace without a recorded D30, the placeholder's value (test `ReplayTypoCorrectionTests`, red with a constant). The engine identity (`InputHost/DevRecorder/DevEngineIdentity+Engine.swift`, `ReplayEngineFactory.identity`) passes `typoCorrection: true`, the product's default, so that it follows the live engines (section "The switch"). `EngineSettingsMapping.configuration(for:variant:)` passes `typoCorrection: false` as a placeholder (one argument, with a comment naming Task 24), so the host's engines never run with the correction on until A1 wires the conjunction of ENG-R1119.
- [x] **Step 4: Run the AppCore suite and build the app** (`xcodegen generate && xcodebuild -project App.xcodeproj -scheme App -configuration Debug build CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/v110-api-dd`). Expected: green; existing `ExplicitSettingKeysTests` updated if it enumerates keys.
- [x] **Step 5: Commit.** `feat(settings): add the D30 switch, the never-correct list and the restore-key variant bit`

### Task 4: The 13.12 fixture and the switch-off re-check (early task)

The rows were checked against the engine at `8926c798`, before rules L4a and L9's REG-38 change shipped in 1.0.1.
This task turns the check into a permanent test and runs it against the current engine while the correction does
not exist yet (the switch off is the 1.0 behaviour).

**Files:**
- Create: `Packages/VietnameseEngine/Tests/VietnameseEngineTests/Corpus/typo-corrections.tsv`
- Create: `Packages/VietnameseEngine/Tests/VietnameseEngineDataTests/RealData/TypoCorrectionExampleTests.swift`

**Interfaces:** Produces the fixture E2 completes (Task 19). Columns, tab-separated, with the escapes of
`Scripts/extract-spec-examples.py` (`\n` Return, `\t` Tab, `\s` a leading or trailing space) and the markers `⌫`
(Backspace) and `⎋` (restore toggle):
`id  method  setup  keys  expected  expected_off  decision  signal  note`, where `setup` is `-`, `code`, `off`,
`never:<word>`, `keep:<word>`, `macro:<trigger>=<expansion>` or `after:<id>`; `expected` is the field text with the
switch on, `expected_off` the text the 1.0 rules leave (from the "What decided" column: `grẩm\s` for S02,
`whcih\s` for S04, `chính\s` for S39, `message\s` for S74, `yess\s` for S83); `decision` is the last commit's
`CommitDecision` written as `corrected(<rule>)`, `kept(<rule>)`, `restored(<rule>)` or `macro` with the rule's case
name (`unchanged`, `invalid`, `escape`, `extendedSpelling`, `notEnglish`, `userChoice`, `userList`, `toneRemoval`,
`codeContext`, ...: S67 is `macro`, S73 after the toggle is `kept(userChoice)`, S74 is `kept(escape)`, S83 is
`kept(escape)`, S41 to S44 are `kept(unchanged)` or `restored(...)` as the 1.0 engine decides them), or `-`;
`signal` is `neverCorrect(androdi)` or `-`; `note` is free text, except the prefixes `q10:<alternative text>` (S23,
S24) and `q11:<alternative text>` (S26; 13.12 has no Tab row), which carry the expectation under the other answer.

- [x] **Step 1: Write the fixture**, all 84 rows, every `expected` copied from the spec's text column.
- [x] **Step 2: Write the tests** (`@Suite("13.12 typo correction with the bundled data")`):
  - `tableMatchesTheSpec`: parse the `| S` rows of section 13.12 from `spec/01-engine.md` (as `CollisionWorkedExampleTests.rows` does for 13.9.3) and assert the fixture has the same ids in the same order and the same `expected` text per id.
  - `theSpecRowsFollowThePolicy`: the spec's text for S23 and S24 is the corrected form exactly when `CorrectionPolicy.sentenceStart == .corrected`, and for S26 exactly when `CorrectionPolicy.commitKeys == .everyCommitKey` (the keeper of the "Q10 and Q11" section).
  - `rowsWithTheSwitchOffMatchThe1_0Engine(row)` (arguments: every row whose `setup` is not `after:`): type `keys` with `EngineConfiguration(inputMethod:, appContext: setup == "code" ? .code : .general, typoCorrection: false)` and the named list entries, assert `driver.field.string == expected_off` and that no output carries `corrected` or `neverCorrect`.
  - `rowsWithTheSwitchOn(row)`: written now, disabled with `.disabled("E2 Task 19 enables it")`; for a row with a `q10:` or `q11:` note it asserts `expected` under the recommendation and the note's text otherwise, reading `CorrectionPolicy`.
- [x] **Step 3: Run `rowsWithTheSwitchOffMatchThe1_0Engine`.** Expected: green for every row. A red row means the 1.0 side of a spec row drifted since `8926c798`: fix the row's `expected_off` and report the row id (the spec table's "What decided" column is amended in the same commit). Result on 19/11/2026 (engine of 1.0.1): the 83 standalone rows give the spec's switch-off text; every row the spec corrects is left as typed by 8.1 (L0, or a restore by L4 or L5) or is the L6 cluster case (S02); one reason was wrong: S46 is decided by L0 before L2, so the keep list excludes it through ENG-R1110 (c), and its "What decided" cell now says so. Rows decided by L4 restoring (`tomorow` S11, `messi` S54, `pajama` S55, `leecher` S57) are candidates by (b), as ENG-R1115's `escape` rule name says.
- [x] **Step 4: Commit.** `test(engine): pin the 1.0 side of the 13.12 rows against the current engine`

### Task 5: Hand-off

- [x] Run `python3 -I docs/architecture/tools/sync_contracts.py` (the included `UserSettings.swift` and `Snapshots.swift` change; `Report.swift` changes in Task 26, A1) and `scripts/lint.sh`; run `scripts/tests/run.sh` (the new `test_correction_policy.py` included); commit `docs(contracts): sync the 1.1.0 API`.
- [ ] Review the stage (signatures only, every suite green on both packages, the app builds), then create `integration/1.1.0` at its head and the four track worktrees from it. The integrator does this after the review; the run of the API stage does not create the branch or the worktrees. Note for the tracks: `sync_contracts.py --check` is red on a track branch that changes an included file until that track re-splices `contracts.md` for its own files (A1 does in Task 27; the other tracks change no included file).

---

## Engine track E1: data (`feat/v110-engine-data`)

### Task 6: SCOWL import of the guard list sources

**Files:**
- Modify: `Packages/VietnameseEngine/Sources/lexicon-builder/Importers.swift` (`Scowl`), `Sources/lexicon-builder/Inputs.swift` (`EnglishLexicon.load` keeps levels 10, 20, 35 and the `words` lists only)
- Modify: `data/inputs/english/SOURCES.tsv` (no change expected; the archive is the same pin), `data/inputs/MANIFEST.sha256` (by `pin`)
- Create (by `import scowl`): the 26 guard-list members of the pinned archive (listed under Interfaces)
- Test: `Packages/VietnameseEngine/Tests/VietnameseEngineDataTests/Builder/BuilderUnitTests.swift`

**Interfaces:** `Scowl.guardListFiles` is the exact list of the members the pinned archive (`sha256 5587667c...`)
holds for the spec's sources (ENG-R1120: words 40 to 70 and proper names 10 to 70 of the four components): the 20
files `{english,american,british,british_z}-words.{40,50,55,60,70}` and the 6 proper-names files that exist,
`english-proper-names.{35,40,50,60,70}` and `american-proper-names.50` (the archive has no proper-names list at 10 or
20, none at 55, and none for `british` or `british_z` at or below 70; the review of 19/11/2026 listed the archive and
Step 4 confirms it). The spec's "proper names 10 to 70" therefore covers six files in practice; ADR 0203 says so.

- [ ] **Step 1: Write the failing tests**: `Scowl.guardListFiles` equals that 26-name list exactly; `Scowl.componentFiles` (the lexicon) is unchanged (12 files); `importArchive` throws on a missing guard member (a fixture archive without one file); `EnglishLexicon.load` on a layout that also holds a `words.40` file returns the same dictionary as before (no word above level 35).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement** `Scowl.guardListFiles` as the literal list, and extend `importArchive` to extract them; a missing member is fatal (a list dropped by mistake must not pass unnoticed).
- [ ] **Step 4: Fetch and import**: `data/fetch.sh` (verifies the pinned SHA-256), then `lexicon-builder import scowl`, then check `git status data/` shows only the 26 new files and `MANIFEST.sha256`. Record the file list and byte counts for the ADR of Task 9.
- [ ] **Step 5: Run `swift test --filter VietnameseEngineDataTests` and `lexicon-builder check`.** Expected: `check` fails only because `manifest.json` records the inputs digest (fixed by the build of Task 8); every test green.
- [ ] **Step 6: Commit.** `feat(data): pin the SCOWL words 40 to 70 and proper names for the guard list`

### Task 7: Keyboard neighbours input and the shapes and keyings generators

**Files:**
- Create: `data/inputs/keyboard-neighbours.txt` (26 lines `letter<TAB>neighbours`, a header comment that states the origin: the three letter rows of the standard ANSI QWERTY layout, `qwertyuiop`, `asdfghjkl`, `zxcvbnm`, with a key's neighbours its row mates on each side plus the staggered keys of the rows above and below; reviewed with the lists)
- Create: `Packages/VietnameseEngine/Sources/lexicon-builder/CorrectionInputs.swift` (`KeyboardNeighbours`, `UnmarkedShapes`, `VietnameseKeyings`)
- Test: `Packages/VietnameseEngine/Tests/VietnameseEngineDataTests/Builder/CorrectionInputTests.swift` (new)

**Interfaces:**
- `enum KeyboardNeighbours { static func load(_ url: URL) throws -> [Character: String]; static func derived() -> [Character: String]; static func check(_ table: [Character: String]) throws }` where `derived()` computes the table from the three rows (a key at index `i` of a row neighbours indices `i - 1` and `i` of the row below and `i` and `i + 1` of the row above) and `check` fails on asymmetry, a missing letter or a difference from `derived()`.
- `enum UnmarkedShapes { static func generate() -> Set<String> }` from `SyllableTables.extendedPairs` (package access, same package): each pair's letters with `ă â` to `a`, `ê` to `e`, `ô ơ` to `o`, `ư` to `u`, `đ` to `d`, tone ignored.
- `enum VietnameseKeyings { static func generate() -> Set<String> }` from `SyllableTables.standardPairs` and each pair's allowed tones, producing **the keying set** defined once here, in the spec's terms (ENG-R1125), and computed independently by Task 10's oracle: for each Tier A syllable (onset, rhyme, allowed tone), (i) the onset keys (`đ` as `dd`); (ii) the vowel letters each as its keys, a marked letter as its two keys (`aa aw ee oo ow uw`), with `ươ` written both as `uwow` and as `uow`; (iii) when the rhyme's first vowel letter is `ư` and the onset is a consonant other than `q`, additionally the standalone form, that `ư` as `w` alone (`thw` for `thư`, `twngf` for `từng`, and with (ii) `thwowng` for `thương`); (iv) the coda letters; (v) the tone key (`s f r x j`, none for the level tone) last and, when a coda exists, also right before the coda. Every combination of (ii), (iii) and (v) is a keying; nothing else is (`gamar` is not: free order is not the usual order).

- [ ] **Step 1: Write the failing tests**: `theNeighboursTableIsSymmetricCoversTheAlphabetAndEqualsTheDerivation` (`load` of the input equals `derived()`; `derived()` lists each letter's neighbours in the spec's order, `["q"] == "wa"`, `["s"] == "weadzx"`, `["m"] == "jkn"`, and `check` compares the two tables as sets per letter); `anAsymmetricTableFailsTheBuild`; `shapesHoldTheSpecExamples` (`truong`, `nguoi`, `khong`, `thuong`, `chuop`, `thach`, `gruop`, `glong` present; `android` absent; every shape matches `^[a-z]+$`); `keyingsHoldTheSpecExamples` (`phair`, `phis`, `chinhs`, `thieeus`, `hoanf` present; `thuwowngf`, `thuowngf`, `thwowngf` and `thuwowfng` all present for `thường`; `gamar` absent because it is not the usual order; count printed).
- [ ] **Step 2: Run, see them fail. Step 3: Implement. Step 4: Run, green.** Record the shape and keying counts (the spec quotes 27,367 keyings on 18/11/2026; a different count is reported, not hidden).
- [ ] **Step 5: Commit.** `feat(data): keyboard neighbours input and the shape and keying generators`

### Task 8: Build, format 3 and the loader

**Files:**
- Modify: `Packages/VietnameseEngine/Sources/lexicon-builder/Build.swift` (`resourceFormat = 3`; new outputs `guard-list.bloom`, `keyboard-neighbours.txt`, `unmarked-shapes.txt`, `vietnamese-keyings.txt`; manifest entries; stats `guardListWords`, `guardListBits`, `unmarkedShapes`, `vietnameseKeyings`)
- Create: `Packages/VietnameseEngine/Sources/lexicon-builder/GuardList.swift` (`enum GuardList { static func words(_ layout: Layout, lexicon: Set<String>) throws -> Set<String>; static func filter(_ words: Set<String>) -> ApproximateWordSet; static func encode(_ filter: ApproximateWordSet) -> Data }`)
- Modify: `Sources/VietnameseEngineData/ResourceDirectory.swift` (`ResourceFile` cases `guardList = "guard-list.bloom"`, `keyboardNeighbours`, `unmarkedShapes`, `vietnameseKeyings`; `supportedFormat = 3`; `guardList()`, `neighbours()` readers), `Sources/VietnameseEngineData/Bundled.swift` (`load` builds `CorrectionData`)
- Modify: `data/licenses/bundled-notices.txt` (the SCOWL paragraph names the guard list and sizes 40 to 70 and the proper names), `data/NOTICES.md`, `THIRD_PARTY_NOTICES.md` (the SCOWL row), `data/README.md` (layout, commands, format 3), `Packages/VietnameseEngine/README.md` (generated data)
- Test: `Tests/VietnameseEngineDataTests/LexiconBuilderTests.swift`, `MalformedResourceTests.swift`, `BundledResourcesTests.swift`

**Interfaces:**
- `guard-list.bloom`: 32-byte header (`KVGL` magic, `UInt32` version 1, `UInt32` hashCount, `UInt64` bitCount, `UInt64` wordCount, 4 bytes zero), then the bits as little-endian `UInt64`. The builder chooses the smallest power of two `bitCount` with an analytic false-positive rate at or under 0.4 % for `hashCount = 8` and fails when the file exceeds 512 KB.
- Guard words: lowercase `a-z` entries of 5 letters or more (shorter words are never looked up, ENG-R1111) from every guard list file, minus the correction lexicon (the English lexicon and the letter-only tech-always entries).
- `keyboard-neighbours.txt`: 26 lines `letter<TAB>neighbours`, sorted; `unmarked-shapes.txt` and `vietnamese-keyings.txt`: format-2 ASCII word lists (sorted, final newline).

- [ ] **Step 1: Write the failing tests**: `buildTwiceGivesIdenticalBytesEqualToTheCommittedResources` (existing; now covers the four files), `checkPassesOnTheCommittedOutputs`, `theGuardListHoldsNoLexiconWordAndNothingShorterThanFive` (`GuardList.words` against `EnglishLexicon.load`), `theGuardFilterIsUnder512KB`, `MalformedResourceTests.correctionFileProblems` (a truncated `.bloom`, a bad magic, an asymmetric table, a 25-line table, a shape with a digit each throw the named `LoadError`), `BundledResourcesTests.loadsTheCorrectionData` (`correction.keyboardNeighbours.count == 26`, `unmarkedShapes.contains("truong")`, `vietnameseKeyings.contains("phair")`, `guardList.mayContain(<a proper name of the input, lowercased>)`, `!guardList.mayContain("android")`); the `keyboardNeighbours.isEmpty` assertion that Task 2 left in `passesTheNeverCorrectListThrough` is replaced by `count == 26`.
- [ ] **Step 2: Run, see them fail. Step 3: Implement.** `Builder.build` writes the four files in manifest order after the collision lists and before `NOTICES.txt`; the loader validates every file through the manifest as today.
- [ ] **Step 4: Build the resources** (`lexicon-builder build`, then `pin` is not needed; `check` must pass) and run `swift test --filter VietnameseEngineDataTests`. Expected: green, `english.txt` byte-identical to before (`git diff --stat` shows only the new files, `manifest.json`, `NOTICES.txt`).
- [ ] **Step 5: Commit** inputs, manifest and resources together: `feat(data): build the guard list, neighbours, shapes and keyings (resource format 3)`

### Task 9: Measurement scripts and the data decision record

**Files:**
- Create: `spec/reference-model/correction.py` (the model of ENG-R1110 to ENG-R1114 and ENG-R1125 over `english.txt`, the tech lists, the neighbours table, the shapes and the keyings generated by `ortho.py`; `python3 -I correction.py --self-check` checks the 13.12 rows it can decide), `spec/reference-model/correction_measure.py` (ENG-T52 injected typos with `--seed`, ENG-T53 rare words from `/usr/share/dict/words`, ENG-T57 one-key Vietnamese typos; prints the table of ENG-R1124)
- Modify: `spec/reference-model/README.md` (the two scripts, what they measured on 18/11/2026 and how to re-run them)
- Create: `docs/decisions/0203-correction-data.md`: the guard list sources (the exact 26 files of Task 6, why proper names are six files, the licence check: the SCOWL `Copyright` file, included whole in `data/licenses/bundled-notices.txt`, covers levels 40 to 70 and the Census names; the README's note on COCA-derived additions is recorded), the Bloom filter and its parameters with the figures the build gives (the review of 19/11/2026 computed, from the pinned archive and the plan's hashing: 77,488 guard words of five or more letters outside the correction lexicon, `2^20` bits = 128 KB at `hashCount = 8`, 0.157 % false positives on 100,000 random strings; the ADR records what the build measures and any difference), resource format 3, the origin of the QWERTY table (provenance N6), the shape and keying counts, the measurement scripts and the figures they give at this commit, and the five 12.2 amendments of the API stage (listed under "Interfaces between tracks").

- [ ] **Step 1: Rebuild the model** from the design note's description and the spec; `--self-check` must pass on every 13.12 row that does not need the engine's composition (the rows whose `expected_off` is the typed word).
- [ ] **Step 2: Run `correction_measure.py --seed 18112026`** and compare with the design note's table (85.7, 95.2, 86.7, 57.5, 75.8 %; 0, 0, 0.05, 1.32, 1.20 %; 3.42 % rare words without the guard list; 1 of 3,371 and 0 of 579 Vietnamese typos). Differences are recorded in the ADR with their cause (the model is a cross-check; ENG-T52, ENG-T53 and ENG-T57 on the engine are the gates).
- [ ] **Step 3: Run `python3 -I scripts/tests/test_licences_and_wording.py`** (SPDX first line, README needles). Expected: green.
- [ ] **Step 4: Commit.** `docs(data): record the correction data sources, the model scripts and the measurements`

### Task 10: Resident budget gates

**Files:**
- Create: `Packages/VietnameseEngine/Tests/VietnameseEngineDataTests/CorrectionDataTests.swift`
- Create: `Packages/VietnameseEngine/Sources/VietnameseEngineTesting/Oracle/KeyingOracle.swift` (`public enum KeyingOracle { public static func keyings(onset: String, rhyme: String, tone: Tone) -> Set<String> }`: the keying set of Task 7's Interfaces computed from the oracle's side, out of `KeySequenceGenerator.keys(onset:rhyme:tone:method: .telex, order:)` for `.o1` and `.o2` (which write `ươ` as `uow` only), `CorpusVariant.explicitUwow` (the ENG-T03 `uwow` spelling, O1 only) and two new helpers written here: the O2 `uwow` form (tone before the coda) and the standalone-`w` form for a leading `ư` after a consonant other than `q`. Nothing in `VietnameseEngineTesting` produced the last two before; `ENG-T03` is not a standalone-`w` variant.)
- Modify: `Tests/VietnameseEngineDataTests/BundledResourcesTests.swift`

- [ ] **Step 1: Write the tests** (ENG-T56 data half):
  - `guardListFalsePositivesStayUnder0_5Percent`: 100,000 random lowercase strings of 5 to 12 letters (seeded generator), at most 500 `mayContain` true.
  - `theGuardFilterNeverForgetsAnInputWord`: every word of `GuardList.words(layout, lexicon:)` answers true (`@testable import lexicon_builder`).
  - `shapesAndKeyingsEqualAnIndependentComputation`: shapes from `SpecFixtures.allStandardSyllables` and the Tier B pairs spelled by `SyllableOracle.spell` with the marks stripped; keyings as the union of `KeyingOracle.keyings` over every Tier A syllable and allowed tone; both equal the bundled sets exactly (differences printed). The builder (Task 7, `SyllableTables`) and the oracle (`SpecFixtures`, `KeySequenceGenerator`) are the two independent computations ENG-T56 asks for; a difference is a bug in one of them, never a reason to drop a form the spec requires.
  - `correctionDataStaysWithinItsResidentBudget`: resident memory of loading the resources with and without the four files differs by at most 1 MB and the guard filter's `bits` by at most 512 KB (the measurement style of `staysWithinLoadTimeAndMemoryBudget`). If it fails, the named fallback is a packed `[UInt64]` sorted array for the keyings (5 bits per letter) before a parser; record the choice in ADR 0203.
- [ ] **Step 2: Run them.** Expected: green; the printed counts and the resident delta go into the ADR and E1's report (for the TRACEABILITY rows ENG-R1120 and ENG-T56 that E2 owns).
- [ ] **Step 3: Commit.** `test(data): gate the correction data on size, false positives and the independent computation`

---

## Engine track E2: logic (`feat/v110-engine-logic`)

E2a (Tasks 11 to 18) uses fixture resources only and runs in parallel with E1. E2b (Tasks 19 to 22) needs the
bundled data of E1 merged into `integration/1.1.0`.

### Task 11: Policy constants and the edit model

**Files:**
- Create: `Sources/VietnameseEngine/Commit/EditModel.swift`
- Modify: `Sources/VietnameseEngine/Commit/CorrectionPolicy.swift` (created by Task 1; only if a constant is missing)
- Test: `Tests/VietnameseEngineTests/Commit/EditModelTests.swift`

- [ ] **Step 1: Write the failing tests** (`@Suite struct EditModelTests`, neighbours from the spec table written as a literal in the test):
  - `transpositionsDeletionsInsertionsAndNeighbourSubstitutions_ENGR1113`: edits of `androdi` include `android`; of `untill` include `until`; of `gramar` include `grammar` once only (the set of distinct edits); of `servet` include `server`; of `grammer` never include `grammar` (`e` and `a` are not neighbours).
  - `positionRulesProtectFirstAndLastLetters`: with `positionRules: true`, edits of `kbang` never include `bang`, of `messi` never `mess`, of `pajama` never `pajamas`, of `leecher` never `leeched`; of `aabout` include `about`, of `helpp` include `help`, of `committ` include `commit`.
  - `withoutPositionRulesEveryEditIsEnumerated_ENGR1125`: with `positionRules: false`, edits of `pahir` include `phair`, of `pehis` include `phis`, of `hoand` include `hoanf`, of `htach` include `thach`.
  - `enumerationStopsWhenTheBodyReturnsFalse` and `enumerationAllocatesNothingForWordsUpTo24Letters` (the callback receives a view of a stack buffer; measured as `PipelineHotPathTests` measures allocations, or by the `LongTokenCostTests` style of the engine tests).
- [ ] **Step 2: Run, see them fail. Step 3: Implement** `EditModel.forEachEdit` with `withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32)` for the scratch (a stack allocation per call; no stored buffer, so `EditModel` stays a plain `Sendable` value and `reduce` stays pure, ENG-R1202, ENG-R1210).
- [ ] **Step 4: Run, green. Step 5: Commit.** `feat(engine): edit model of the typo correction`

### Task 12: The correction index

**Files:**
- Create: `Sources/VietnameseEngine/Commit/CorrectionIndex.swift`
- Modify: `Sources/VietnameseEngine/PublicAPI.swift` (`Resources.init` builds `correctionIndex`; `Resources.empty` uses `.empty`)
- Test: `Tests/VietnameseEngineTests/Commit/CorrectionIndexTests.swift`

- [ ] **Step 1: Write the failing tests**: `aCandidateWithAnUnseenTrigramIsRejected` (index over `["android", "about"]`: `mightHold("andxoid")` false, `mightHold("android")` true, `mightHold("about")` true); `edgeBigramsAreChecked` (`mightHold("ndroid")` false: `^nd` never starts a word of the set); `theIndexIsSharedByCopiesOfResources` (`ObjectIdentifier(a.correctionIndex) == ObjectIdentifier(b.correctionIndex)` for `var b = a` followed by assignments to `userKeepRaw`, `userKeepVietnamese`, `macros`, `collisionMemory` and `userNeverCorrect`: the fields the host assigns after loading); `mutatingAnInputAfterInitRebuildsTheIndex` (`var r = SpecFixtures.correctionResources(...)` with an empty `correction`, then `r.correction = <the fixture data>`: `r.correctionIndex.isVietnameseKeyingOrShape("phair")` is true and the index is a new object; the same for `r.english` and `r.techAlways`); `lexiconLookupsAreByteKeyedAndAllocateNothing` (`lexiconContains` for a 20-letter word, measured as in Task 11); `emptyResourcesHaveAnEmptyIndex`.
- [ ] **Step 2: Run, see them fail. Step 3: Implement**: a 17,576-bit trigram table and two 676-bit edge tables (`^ab`, `yz$`) as `[UInt64]`, plus the byte-keyed stores behind `lexiconContains` and `isVietnameseKeyingOrShape`, built from `english`, the letter-only `techAlways` entries of at least four letters, `correction.unmarkedShapes` and `correction.vietnameseKeyings`; `Resources.init` builds it last and a `didSet` on exactly `english`, `techAlways` and `correction` rebuilds it (a rebuild allocates, which is fine: it runs where the host builds a catalog, never on the tap). A false "yes" only costs lookups. The doc comment says why the index can never be stale: the same prefilter gates the ENG-R1125 pass, so a stale one would let `pahir` become `pair`.
- [ ] **Step 4: Run, green; `StaticSourceTests.coreIsClean` green. Step 5: Commit.** `feat(engine): trigram prefilter shared by every engine of a resources value`

### Task 13: Candidate rules (ENG-R1110 to ENG-R1112)

**Files:**
- Create: `Sources/VietnameseEngine/Commit/TypoCorrection.swift`
- Modify: `Sources/VietnameseEngine/Commit/CommitRules.swift` (`CommitContext.characterBefore`, `CommitPolicy.corrector`), `Sources/VietnameseEngine/Engine/Reducer+Commit.swift` (passes `characterBefore` from the history's last entry)
- Create: `Sources/VietnameseEngineTesting/Fixtures/CorrectionFixtures.swift` (`SpecFixtures.correctionResources(...)`: the 13.9 lexicon plus `android grammar which hello server about help their tier thief weird wired pair hand penis chins hatch group truing chop still bank mess pajamas leeched leecher example local known wren`, guard `["biden", "kbang"]`, shapes `["truong", "chuop", "thach", "gruop", "glong"]`, keyings `["phair", "phis", "hoanf", "chinhs"]`, the spec neighbours table)
- Test: `Tests/VietnameseEngineTests/Commit/TypoCorrectionCandidateTests.swift`, `TypoCorrectionContextTests.swift`

- [ ] **Step 1: Write the failing tests** (each types keys with `EngineDriver` on `correctionResources`, commits with a space unless stated, asserts the field and the decision):
  - Candidates (ENG-R1110): `aTokenShownAsTypedIsACandidate` (`androdi` gives `android `, `.corrected(.unchanged)`); `aRestoredTokenIsACandidate` (`whcih`: `.corrected(.invalid)`); `theClusterCaseNeedsATransformedDisplayKeptByL6` (`gramar` gives `grammar `, `.corrected(.extendedSpelling)`; `glong` stays; `Gramar` after `ddi` stays `Grẩm`); `aUserToggleOrListEntryIsNeverACandidate` (`androdi` toggled, `keep:androdi`, `never:androdi`); `aWordOfAnyListIsNeverACandidate` (`ability`, `oauth`, `gradle`, a collision-supplement word); `aVietnameseWordOrShapeIsNeverACandidate` (`chinhs` gives `chính `, `truong`, `chuop`, `gruop` stay); `aReopenedRestoredOrCorrectedTokenIsNeverACandidate` (ENG-R1110 (b), ENG-R1117: a token restored by the toggle, re-opened with Backspace and committed again; a corrected token re-opened and committed again: no second correction, `corrected` reported again); `tokensOfL3L9cAndTheRevisionAreNeverCandidates` (an abbreviation of L3 such as `btw` padded to five letters where the fixture allows, a word the collision memory holds (L9c) and a token ENG-R828 revises: none is corrected, in the same inputs where a plain token would be); `withAutoRestoreOffNothingIsCorrected_ENGR802` (`EngineConfiguration(autoRestore: false, typoCorrection: true)`: `androdi` stays).
  - Letters and case (ENG-R1111): `fourLettersAreTooFew` (`wiht`), `twentyFiveLettersAreTooMany`, `aDigitOrBracketLetterExcludesTheToken` (`androd1`, a VNI `6`), `sentenceCaseOnlyAtASentenceStart` (`Androdi` gives `Android `; `xong. Recieve` gives `Receive`; `ddi Androdi` stays; `ANDRODI`, `AndroDi` stay), `aChatElongationIsNotATypo` (`stilll`).
  - Context (ENG-R1112): `neverInTheCodeContext`; `onlyWhitespaceReturnTabAndTheAsciiClosersCommitACorrection` (`androdi.` gives `android.`, `(androdi)`, `androdi\n` gives `android\n`; `androdi…`, `weren't`, `androdi/` stay); `nothingGluedBeforeTheWord` (`www.exapmle.com`, `kal@exapmle.com`, `/opt/locla`, `#androdi`, `well-knwon` stay; `- androdi` and `# androdi` at a line start and after a Return are corrected); `afterAResetTheWordIsACandidate` (type `#`, send `.reset(.pointerClicked)`, type `androdi `: corrected; Review Focus 2).
- [ ] **Step 2: Run, see them fail. Step 3: Implement** `TypoCorrector.correction(for:decision:token:context:)` up to and including the context checks (the edit search comes in Task 14; return nil for now), `CommitContext.characterBefore`, `CommitPolicy.corrector` (nil with the switch off, in `.code`, or with `autoRestore` off), and the call site in `Reducer+Commit.commitToken` right after the RV5 block: a non-nil correction replaces `result.text`, `result.decision` (`.corrected(rule)` with `rule` the 8.1 rule's `CommitRule`), `result.action` (`DisplayEdit.edit(from: token.display, to: text)`, `thenPassThrough: true`), `result.language = .english`, clears `learning`, `strongSignal` and `collision.listWord`, and `mayRevise` is forced false for it (ENG-R1116).
- [ ] **Step 4: Run; the candidate tests that expect a correction stay red until Task 14, the exclusion tests are green. Commit.** `feat(engine): candidate rules of the typo correction (ENG-R1110 to ENG-R1112)`

### Task 14: Edit search, the one-word rule and Vietnamese within one edit

**Files:**
- Modify: `Sources/VietnameseEngine/Commit/TypoCorrection.swift`, `Sources/VietnameseEngine/Commit/TokenLanguage.swift` (a corrected token is `.english`: the API stage added the arm so that the switch compiles; this task tests it)
- Test: `Tests/VietnameseEngineTests/Commit/TypoCorrectionCommitTests.swift`

- [ ] **Step 1: Write the failing tests**:
  - `exactlyOneWordOfAtLeastFourLettersFits_ENGR1114`: `androdi`, `helpp` (a four-letter fit is allowed), `gramar` (one word reached twice counts once) corrected; `thier`, `wierd`, `pleasee`, `grammer`, `eah` stay.
  - `theCorrectionLexiconIsTheLexiconAndTheLetterOnlyTechAlwaysEntries`: a tech-always entry with a digit is never a fit; a code-only word is never a fit (`gradle` protects itself but `grade` is not reached through it).
  - `vietnameseWithinOneEditBlocksTheCorrection_ENGR1125`: `ddi pahir` gives `đi pahir `, `pehis`, `hoand`, `chihns`, `htach` stay; `gramar` is still corrected (`gamar` is not a usual-order keying).
  - `theEditIsOneTextEditWithThePassThrough_ENGR1115`: the output of the committing space is `.edit(TextEdit(deleteCount: 7, deleteUTF16Count: 7, insert: "android"), thenPassThrough: true)` for `androdi`; for `gramar` the deletion covers `grẩm` (4 graphemes).
  - `theCaseOfTheTypedWordIsKept`: `Androdi` gives `Android`.
  - `aCorrectedTokenCountsAsEnglishForTheRun_ENGR1116`: `androdi as ` gives `android as ` (`as` restored by the English run); `state.history` newest token has `language == .english`.
  - `aCommitNeverBothRevisesAndCorrects_ENGR1116`: `cais nayf tricky as androdi ` revises nothing and corrects `androdi`.
  - `theDecisionIsTheSameAtEveryCommittingKey_Q11`: `androdi\n` and `androdi\t` give the correction with `CorrectionPolicy.commitKeys == .everyCommitKey` (the test reads the constant and expects the other outcome under `.spaceAndPunctuationOnly`).
- [ ] **Step 2: Run, see them fail. Step 3: Implement** the search: lowercase the raw keys into a stack buffer; `forEachEdit(positionRules: false)` first for ENG-R1125 (stop at the first `isVietnameseKeyingOrShape` hit, after `mightHold`), then `forEachEdit(positionRules: true)` for the lexicon fits (stop at the second distinct fit); a fit is `lexiconContains` (the English lexicon and the letter-only `techAlways` entries of at least `minimumFitLetters`, Task 12). Distinctness: keep the first fit's bytes and compare the second.
- [ ] **Step 4: Run every engine suite** (`swift test --package-path Packages/VietnameseEngine --scratch-path .build-e2`). Expected: green. The 1.0 corpora and worked examples are untouched because they run with `typoCorrection: false` (Task 1's sweep, pinned by `StaticSourceTests.everyConfigurationOutsideTheCoreNamesTheSwitch`), not because fixture data lacks fits: the fits come from `english` and `techAlways`, which every fixture has, and empty correction data would only remove the guard list, the shapes and the ENG-R1125 block. **Commit.** `feat(engine): the edit search, the one-word rule and ENG-R1125`

### Task 15: History, re-opening and the undo

**Files:**
- Modify: `Sources/VietnameseEngine/Engine/ActiveToken.swift` (`MacroTokenKeys` becomes `LiteralTokenKeys` with `kind: LiteralKind` where `enum LiteralKind { case macro, corrected(CommitRule) }`; `init(correctedSpan: [UInt8], correction: String, rule: CommitRule)`; `correctedRule: CommitRule?`; `isMacro` is `kind == .macro`), `Sources/VietnameseEngine/Engine/History.swift` (`CommittedToken.reopened` returns the literal corrected token), `Sources/VietnameseEngine/Engine/Reducer.swift` (`EngineState.previousEventCorrected`; the toggle dispatch), `Sources/VietnameseEngine/Engine/Reducer+Commit.swift` (records the corrected token; `commitResult` for a re-opened corrected token: `.corrected(rule)` unchanged when the user did not restore it, L1 otherwise), `Sources/VietnameseEngine/Engine/Reducer+Revision.swift` (`undoCorrection(_:)` next to `undoRevision`)
- Test: `Tests/VietnameseEngineTests/Commit/TypoCorrectionUndoTests.swift`

- [ ] **Step 1: Write the failing tests**:
  - `theToggleRightAfterACorrectionBringsTheKeysBackAndTeaches_ENGR1117` (S68): `androdi ⎋` gives `androdi `; the toggle output is `.edit(TextEdit(deleteCount: 8, deleteUTF16Count: 8, insert: "androdi "), thenPassThrough: false)` with `learning == .neverCorrect(raw: "androdi")`; the history token now shows the raw keys as the user's choice.
  - `aSecondTogglePassesThrough_ENGR702` (S69).
  - `undoAfterACloserKeepsTheCloser`: `androdi.⎋` gives `androdi.` (Review Focus 1).
  - `afterReturnTheToggleCannotUndo`: `androdi\n⎋`: the toggle passes through (ENG-R829).
  - `backspaceReopensTheCorrectionAsALiteralToken` (S70): `androdi ⌫⌫` gives `androi`, `state.isLiteral`.
  - `theToggleAfterReopeningBringsTheKeysBackWithTheSignal` (S71): `androdi ⌫⎋` gives `androdi` and `.neverCorrect(raw: "androdi")`.
  - `aReopenedCorrectedTokenIsNeverCorrectedAgain` (S73): `androdi ⌫ ` gives `android ` with `.corrected(.unchanged)` reported again; after `⌫⎋ ` the decision is `.kept(.userChoice)`.
  - `keysTypedIntoAReopenedCorrectionAreAppendedAsTyped`: `androdi ⌫s ` gives `androids ` and the token stays literal.
  - `withTheSwitchOffNothingChanges_ENGR1119` (S66): the toggle after `androdi ` behaves as ENG-R703 (pass-through), no `corrected`, no `neverCorrect`.
  - `theUserListsAndTheNeverCorrectListStopTheCorrection` (S45, S46, S72 with `userNeverCorrect: WordSet(["androdi"])`).
- [ ] **Step 2: Run, see them fail. Step 3: Implement** as named in Files. The undo edit mirrors `undoRevision`: the newest entry is the boundary `b`, the token before it the corrected token `t`; the edit is `DisplayEdit.edit(from: t.committedText + b, to: rawKeys + b)`, the history token takes `committedText = rawKeys`, `token.choosing(.restored)`, `decision = .restored(.userChoice)`, its language as `TokenLanguage.of` gives for that decision, the language window is replaced at distance 0, and the output carries `.neverCorrect(raw: lowercased raw keys)` and no `decision`. The toggle on a re-opened corrected literal restores through the `LiteralTokenKeys` path and the reducer attaches the same signal.
- [ ] **Step 4: Run every engine suite; the macro suites (`MacroTests`, `macros.tsv`) must be untouched by the rename. Commit.** `feat(engine): undo and re-opening of a corrected token (ENG-R1117)`

### Task 16: Fuzz invariants (ENG-T54)

**Files:**
- Modify: `Sources/VietnameseEngineTesting/Fuzz/InvariantChecker.swift`, `Sources/VietnameseEngineTesting/Fuzz/FuzzCampaign.swift` (`FuzzCombination.all` keeps the 80 combinations of 1.0 with `typoCorrection: false` as Task 1 left them and adds the on-half: the same 80 with `typoCorrection: true`, a random never-correct list (`FuzzCombination.neverCorrect: [String]`) and `correctionResources`; `FuzzCampaign.run(..., resources: Resources? = nil)` lets a caller substitute the bundled data for the fixture resources, used by Task 22 Step 1, since `VietnameseEngineTests` cannot depend on `VietnameseEngineData` while `Package.swift` is frozen), `Tests/VietnameseEngineTests/Quality/FuzzTests.swift` (the combinations double: switch on and off)
- Test: `Tests/VietnameseEngineTests/Quality/FuzzTests.swift`

- [ ] **Step 1: Write the new invariants as `FuzzViolation` kinds and the assertions of ENG-T54** (the API stage made `InvariantChecker` count a `corrected` decision as a commit and mix it into the digest; a `correctedCommits` statistic is this task's to add): with the switch on: ENG-T32 extended (a toggle right after a corrected commit, or right after Backspace re-opened a corrected token, gives exactly the raw keys typed), ENG-T35 extended (in VNI every inserted string that is neither the raw keys nor a composition of typed letters is a word of the correction lexicon), no correction in `.code`, none of a token on any list, none of a typed word within one edit of a keying or a shape (the checker recomputes with `EditModel`), no `corrected` output whose edit deletes more than the active token's display (scoped to `corrected` outputs: the undo toggle rightly deletes the correction and the boundary), never two edits in one event, never `revision != nil` together with `corrected`, every `neverCorrect` names the lowercased raw keys of its token; with the switch off: no output carries `corrected` or `neverCorrect` and every toggle after a commit answers as ENG-R703 and ENG-R829 say.
- [ ] **Step 2: Run `FuzzTests.randomStreams` for every combination (the per-PR 1,000,000 events).** Expected: zero violations; `determinism` green. This covers the fixture data; the run with the bundled data that ENG-T54 also requires is Task 22 Step 1.
- [ ] **Step 3: Commit.** `test(engine): fuzz invariants of the typo correction (ENG-T54)`

### Task 17: Benchmark workload (ENG-T55, the code; the gated run is Task 22 Step 2)

**Files:**
- Modify: `Benchmarks/EngineBenchmark/Workloads.swift` (`Workload.correctionCandidates(resources:count: 10_000, adversarial: 1_000, seed:)`: typos of lexicon words of 5 to 24 letters, one random edit each, typed after a space, plus `adversarial` tokens of 24 letters built from the most frequent trigrams of the lexicon with no fit, which pass the prefilter and make both passes enumerate about 800 edits each: the worst case `correction.max` must hold), `Benchmarks/EngineBenchmark/EngineBenchmark.swift` (`--typo-correction on|off`, default `off` for the ENG-T40 workloads so that `Benchmarks/baseline.json`, measured on 1.0, stays comparable; the `correction` workload always runs with it on; result keys `correction.p99`, `correction.max`, `correction.events`; budget keys `correctionP99: 50000`, `correctionMax: 200000`), `Benchmarks/EngineBenchmark/Measurement.swift`, `Scripts/benchmark.sh` (runs the prose and fuzz workloads with the switch off and on and fails when a percentile differs by more than the threshold it already applies), `Tests/VietnameseEngineTests/Composition/EngineBenchmarkTests.swift` (`candidateLatency`: prints p50, p99 and max over the candidates in debug, fixture data; not a gate)
- Test: `EngineBenchmarkTests`

- [ ] **Step 1: Write `candidateLatency` and the workload**, run in debug to see numbers (fixture data: indicative only, since E2a has no neighbours, shapes, keyings or guard list yet, so no substitutions and no early ENG-R1125 hits).
- [ ] **Step 2: Commit.** `perf(engine): benchmark workload for the typo correction candidates (ENG-T55)`. The release run against the bundled data, the gate and the trie decision are Task 22 Step 2: a p99 measured without the data would rest on unrepresentative work.

### Task 18: E2a traceability and changelog rows

- [ ] Replace the "planned" rows ENG-R1110 to ENG-R1119, ENG-R1121, ENG-R1125 and ENG-T54 (the fixture half) of `Packages/VietnameseEngine/TRACEABILITY.md` with the real `Suite.function` names of Tasks 11 to 16; ENG-R1122 and ENG-T55 name the workload of Task 17 and get their figures in Task 22; add the engine CHANGELOG entries under Unreleased (Added: `EngineConfiguration.typoCorrection`, `CommitDecision.corrected`, `LearningSignal.neverCorrect`, `CorrectionData`, `ApproximateWordSet`, `Resources.userNeverCorrect`; source-breaking additions, the next tag stays the minor bump the file already announces). Run `python3 -I Packages/VietnameseEngine/Scripts/check-traceability.py`. Commit `docs(engine): traceability and changelog of the typo correction logic`.

### Task 19: Worked examples with the bundled data (ENG-T50), after E1

**Files:**
- Modify: `Tests/VietnameseEngineDataTests/RealData/TypoCorrectionExampleTests.swift` (enable `rowsWithTheSwitchOn`), `Tests/VietnameseEngineTests/Corpus/typo-corrections.tsv` (the API stage filled `decision` and `signal`: a correction names the rule the engine of 1.0.1 decides with the switch off, the other rows that engine's decision; this task confirms them with the switch on), `Tests/VietnameseEngineTests/Corpus/README.txt` (one line for the new file, which the API stage did not own)

- [ ] **Step 0: Take E1's data.** In the E2 worktree, `git merge --no-ff integration/1.1.0` (E1 merged there by Task 31's first merge; CLR-R12: never a rebase), `swift run lexicon-builder check`, and the engine suite green before anything else.
- [ ] **Step 1: Enable `rowsWithTheSwitchOn(row)`**: for every row, apply `setup`, type `keys`, assert `driver.field.string == expected`, the last commit's decision equals `decision`, the outputs' `learning` equals `signal`, and for the undo rows (S68 to S73) the toggle's edit as Task 15 specifies. `after:S68` rows run S68 first and add the signal's word to `userNeverCorrect` for the second part.
- [ ] **Step 2: Run.** Expected: 84 green rows. A red row is either a bug (fix the engine) or a spec row the bundled data contradicts (report it with the engine's text; never edit `expected` to match).
- [ ] **Step 3: Commit.** `test(engine): the 84 rows of 13.12 pass with the bundled data (ENG-T50)`

### Task 20: Zero-change corpora (ENG-T51) and the Vietnamese typos (ENG-T57)

**Files:**
- Create: `Sources/VietnameseEngineTesting/Corpora/CorrectionTargets.swift` (`CorrectionCheck.run(words:resources:configuration:) -> [ChangedWord]` counting `corrected` outputs; `TypoGenerator(seed:)` with the five kinds; `VietnameseTypoCheck` for ENG-T57)
- Create: `Tests/VietnameseEngineDataTests/RealData/TypoCorrectionCorpusGateTests.swift`

- [ ] **Step 1: Write the tests** (each prints every corrected token, `RealData.listing`):
  - `proseCorpusIsNeverCorrected(method, order, style)` (the `ProseCorpusGateTests.cases`): zero `corrected`.
  - `unmarkedProseIsNeverCorrected`: every token of the prose corpus with its marks removed, typed as plain letters after a space and at a line start: zero.
  - `generatedAndW11CorporaAreNeverCorrected`: the generated corpus (both methods, both styles) and the W11 corpus with its three sets: zero.
  - `everyWordListIsNeverCorrected`: the English lexicon, tech-always, code-only and the guard list's input words, each in Telex and VNI, lowercase after `vieejt ` and in sentence case at the start of the input: zero.
  - `vietnameseTyposAreAlmostNeverCorrectedToEnglish_ENGT57`: every distinct word of the prose corpus typed in Telex with the tone key last and, as a second run, as plain letters, one random edit of each kind (seed `18112026`), after `vieejt `; among the typos of 5 or more keys whose source is Tier A or Tier B, at most 0.1 % corrected; the list printed; typos of English words of the corpus not counted.
- [ ] **Step 2: Run.** Expected: green; the ENG-T57 figures go into the TRACEABILITY row with the seed.
- [ ] **Step 3: Commit.** `test(engine): zero-change corpora and Vietnamese typo gate (ENG-T51, ENG-T57)`

### Task 21: Injected typos (ENG-T52) and rare words (ENG-T53)

**Files:**
- Create: `Tests/VietnameseEngineDataTests/RealData/TypoCorrectionTargetTests.swift`

- [ ] **Step 1: Write the tests**:
  - `injectedTyposAreCorrectedToTheirSource_ENGT52(kind)` (arguments: transposition, deletion, insertion, doubling, neighbouring key): 6,000 lexicon words of at least five letters, seed `18112026`, one edit each, typed after a space; corrected to the source at least 80, 50, 70, 90 and 80 %; corrected to another word at most 1.5 %; the counts printed.
  - `rareWordsAreRarelyCorrected_ENGT53`: every word of `/usr/share/dict/words` with five or more ASCII letters outside the English lexicon and the guard filter (the spec's denominator, ENG-T53 and ENG-R1124; the tech lists stay in it, where they are never corrected because they are lists, ENG-R1110 (c)), typed lowercase after a space: at most 3.5 % corrected, the list printed; skipped when the file is absent.
- [ ] **Step 2: Run.** Expected: green. Record the figures.
- [ ] **Step 3: Commit.** `test(engine): injected typos and rare words gates (ENG-T52, ENG-T53)`

### Task 22: E2b gates with the bundled data (fuzz, benchmark) and traceability

**Files:**
- Create: `Tests/VietnameseEngineDataTests/RealData/TypoCorrectionFuzzTests.swift` (this test target depends on `VietnameseEngineData` and `VietnameseEngineTesting`, so the bundled data reaches `FuzzCampaign` without touching the frozen `Package.swift`)
- Modify: `Packages/VietnameseEngine/TRACEABILITY.md`, `Benchmarks/results/**` is Integration's (Task 34); this task records the figures in its report

- [ ] **Step 1: Fuzz with the bundled data (ENG-T54).** `TypoCorrectionFuzzTests.randomStreamsWithTheBundledData`: the on-half of `FuzzCombination.all` (the general and code contexts, both methods, auto restore on) through `FuzzCampaign.run(..., resources: Resources.bundled(userKeepRaw:userKeepVietnamese:userNeverCorrect: <the combination's random list>))` at the per-PR size, every ENG-T54 invariant of Task 16 checked against the real keyings, shapes and guard list. Expected: zero violations.
- [ ] **Step 2: Release benchmark (ENG-T55).** `Scripts/benchmark.sh` on the baseline machine with the bundled data: `correction.p99` at most 50 µs and `correction.max` at most 200 µs (the adversarial candidates included), the ENG-T40 percentiles within the threshold between `--typo-correction off` and `on`. If p99 fails, the named next step is a packed trie of the correction lexicon for insertions (prefix-pruned), built in `CorrectionIndex`, decided here and recorded in the TRACEABILITY row of ENG-R1122. The figures go to the integration report; Task 34 commits the result file and the baseline keys.
- [ ] **Step 3: Traceability.** Fill the remaining rows of section 11A of `TRACEABILITY.md` (ENG-R1120, ENG-R1123, ENG-R1124, ENG-T50 to ENG-T57) with the real suite names, the measured figures and seeds (E1's report supplies the data rows), and amend the ENG-R122 row (the typo correction now ships). Run `check-traceability.py` and `TraceabilityTests`. Commit `test(engine): fuzz and benchmark with the bundled data; traceability of the gates`.

---

## App track A1: store and host (`feat/v110-app-host`)

### Task 23: The never-correct list in the store (PRD-R81 storage half)

**Files:**
- Modify: `Packages/AppCore/Sources/SettingsStore/DocumentCodecs.swift` (`englishRestoreLists.neverCorrect`, lowercased, entries that fail `NeverCorrectEntry.normalized` dropped), `ExportImport.swift` (`changedKeys` names `neverCorrect`), `SettingsStore+Transfer.swift` (`.typing` reset and the full reset clear it), `Migrations.swift` (doc comment: version 1 stays; an older file reads as an empty list)
- Create: `Packages/AppCore/Sources/SettingsStore/NeverCorrectList.swift` (`extension UserSettings { public mutating func neverCorrect(_ raw: String) -> Bool  // normalises, inserts, false when refused }`)
- Test: `Packages/AppCore/Tests/SettingsStoreTests/NeverCorrectListTests.swift` (new), `SettingsTransferTests.swift`, `MigrationAndJSONTests.swift`

- [ ] **Step 1: Write the failing tests**: `codecRoundTripsTheListUnderEnglishRestoreLists`; `invalidEntriesAreDroppedOnLoad`; `aFileWithoutTheListLoadsEmptyAndWithD30On` (Review Focus 3); `unknownSiblingKeysSurviveARewrite_PLTR1002`; `typingResetAndFullResetClearTheList_PRDR26`; `exportThenImportCarriesTheListWithoutAChoice_PRDR72` (no new checkbox; `changedKeys` lists `neverCorrect` only when it differs); `a1_0ExportImportsWithTheDefaults` (an export fixture without the two keys: D30 resolves on, nothing listed as changed for them); `neverCorrectNormalisesAndRefuses`.
- [ ] **Step 2: Run, fail. Step 3: Implement. Step 4: Run `swift test --filter SettingsStoreTests`, green. Step 5: Commit.** `feat(settings): store, reset, export and import the never-correct list`

### Task 24: The engine switch and the variant (ENG-R1119, PRD-R80 host half)

**Files:**
- Modify: `Packages/AppCore/Sources/InputHost/Engine/EngineSettingsMapping.swift` (`catalogSize = 32`, bit 4 `restoreHotkey`; `configuration(for:variant:)` replaces Task 3's placeholder with `typoCorrection: settings.typoCorrection && settings.englishRestore && variant.englishRestore && variant.restoreHotkey && settings.restoreHotkey != nil`), `Engine/EngineBridge.swift` (`resources(wordLists:neverCorrect:macros:bundledLoader:)` sets `userNeverCorrect`), `Focus/HostDecisionMapping.swift` (`restoreHotkey: decision.features.restoreHotkey`, the value `HostDecision.restoreHotkeyEnabled` already carries), `Integration/TapSettingsPublisher.swift` (`EngineInputs.typoCorrection` from D30, `EngineInputs.restoreKeyEnabled` from `settings.restoreHotkey != nil`, `EngineInputs.neverCorrect`; the doc comment of `EngineInputs` now says that D8's on/off state is an engine input (ENG-R1119) while its binding is not, so rebinding the key still keeps the revision and the word being typed, PRD-R27)
- Modify (replay follows the host mapping, section "The switch"): `Packages/AppCore/Sources/ShellCore/DevRecorderShell.swift` (`DevRecorderSettings.snapshot` records `typoCorrection`, D30), `Diagnostics/DevRecorderRecords.swift`, `Diagnostics/DevRecorderFiles.swift` and `InputHost/DevRecorder/FocusCore+DevRecorder.swift` (the focus line records the variant's `restoreHotkey`), `TraceScanCore/TraceLine.swift` (the new focus field) and `TraceScanCore/Replay.swift` (`typoCorrection(settings:focus:)` also ANDs the recorded rule `restoreHotkey`, so it is the conjunction `configuration(for:variant:)` passes, input for input), `Diagnostics/DevEngineIdentity.swift` (probes that exercise the correction, such as `androdi `, `gramar `, `androdi.` and `ddi pahir `, so a build whose correction differs gets another identity; the recorder and the scanner already digest with the switch on)
- Test: `Packages/AppCore/Tests/InputHostTests/Pipeline/EngineBridgeTests.swift`, `Tests/InputHostTests/Integration/TapSettingsPublisherTests.swift` (new if absent), `Tests/InputHostTests/Pipeline/LookaheadRevisionContinuationTests.swift` (unchanged expectations, re-run), `Tests/TraceScanTests/ReplayTypoCorrectionTests.swift` (API stage; extended), `Tests/TraceScanTests/RecorderRoundTripTests.swift` (the new fields round-trip)

- [ ] **Step 1: Write the failing tests**: `EngineBridgeConfigurationTests.typoCorrectionIsD30AndD4AndTheRuleSwitchesAndTheRestoreKey_ENGR1119` (arguments: the 2^5 combinations of D30, D4, `variant.englishRestore`, `variant.restoreHotkey`, D8 set; expected the conjunction); `EngineCatalogTests.catalogHoldsOneEnginePerVariant` (32), `variantIndexRoundTrips` (bit 4), `thirtyTwoEnginesShareTheCorrectionIndex` (every engine's `resources.correctionIndex` is the same object; Review Focus 5), `theNeverCorrectListReachesEveryVariant`; `HostDecisionMappingTests.aRuleWithTheRestoreKeyOffGivesAVariantWithoutIt` (a rule fixture with `features.restoreHotkey: false`, the Spotlight shape); `TapSettingsPublisherTests` (Review Focus 6): `turningD30OffRebuildsWithTypoCorrectionOff`, `turningD4OffRebuildsWithTypoCorrectionOff`, `turningTheRestoreKeyOffRebuildsWithTypoCorrectionOff` (publish with D8 Escape, then with D8 `nil`: `rebuiltEngines` is true, the revision moved, and every engine whose variant has `englishRestore` and `restoreHotkey` on now has `configuration.typoCorrection == false`; D8 back on rebuilds with it true), `rebindingTheRestoreKeyKeepsTheRevision` (Escape to another key: no rebuild, same revision, the snapshot's `restoreHotkey` updated), `aChangedNeverCorrectListRebuildsTheCatalogWithANewRevision`, `aNeverCorrectEntryLearnedInOneAppReachesEveryApp` (`focusChanged` republishes nothing for it: the list is global); `ReplayTypoCorrectionTests.replayAgreesWithTheHostForEveryCombination` (the 2^5 combinations of D30, D4, the rule's `englishRestore`, the rule's `restoreHotkey` and D8, recorded as the recorder writes them: replay's switch equals `EngineSettingsMapping.configuration(for:variant:).typoCorrection`) and `aRuleWithoutTheRestoreKeyReplaysWithTheSwitchOff`; `EngineVariantTests.restoreHotkeyIsMoreThanALookaheadDifference` (`differsOnlyInLookaheadRevision` is false when `restoreHotkey` differs too, as the API stage made it).
- [ ] **Step 2: Run, fail. Step 3: Implement. Step 4: Run `swift test --filter InputHostTests`, green (the pipeline hot-path tests included). Step 5: Commit.** `feat(host): pass the typo correction switch per variant and the never-correct list to the engines`

### Task 25: Escape teaching and the undo in the pipeline (ENG-R1117, ENG-R1118 host halves)

**Files:**
- Modify: `Packages/AppCore/Sources/InputHost/Pipeline/KeyPipeline+Keys.swift` (`restoreLastWord` forwards `output.learning` to main like `compose` does), `Integration/InputHostController+Notices.swift` (`noteLearning`: a `.neverCorrect(raw)` goes to `settingsStore.updateSettings { _ = $0.neverCorrect(raw) }` at once, with or without an app, and never to the tracker), `Pipeline/HostCounters.swift` (`corrections`, `correctionUndos`), `Integration/LearningTracker.swift` (doc comment)
- Modify: `Packages/AppCore/Sources/TestSupport/Pipeline/ScriptedEngine.swift` (a token whose raw keys end with `yy` commits as the raw keys without the last `y`, decision `.corrected(.unchanged)`, one edit then the boundary; the toggle right after replaces the correction and the boundary with the raw keys and the boundary and carries `.neverCorrect(raw:)`; a second toggle passes through)
- Test: `Packages/AppCore/Tests/InputHostTests/Pipeline/KeyPipelineCorrectionTests.swift` (new), `Tests/InputHostTests/Integration/PerAppLearningTests.swift`, `Tests/InputHostTests/Pipeline/PipelinePropertyTests.swift` (the scripted rule joins the random streams)

- [ ] **Step 1: Write the failing tests**: `aCorrectedCommitIsOneEditJobBeforeTheBoundaryKey_ENGR1115` (kind `.compose`, the boundary replayed after); `theUndoRightAfterIsARestoreWiderThanTheActiveDisplayAndCarriesTheSignal_ENGR1117` (kind `.restore`, `deleteCount == corrected.count + 1`, `keyState.lastCommit == nil`, the key consumed); `theUndoAfterACloserDeletesTheCloserToo` (Review Focus 1); `aNeverCorrectSignalReachesTheStoreAtOnceFromAnyApp_ENGR1118` (HostRig: one signal with `bundle: nil` lands in `user.neverCorrect`; `LearningTracker` pending count unchanged); `countersCountCorrectionsAndUndosNeverWords`; `PipelinePropertyTests` conservation and ordering still hold with the scripted rule in the streams.
- [ ] **Step 2: Run, fail. Step 3: Implement. Step 4: Run `swift test --filter InputHostTests`, green; `PipelineHotPathTests` allocation counts unchanged. Step 5: Commit.** `feat(host): learn the never-correct list from the restore key at once`

### Task 26: Diagnostics (PLT-R1202, PRD-R45)

**Files:**
- Modify: `Packages/AppCore/Sources/Diagnostics/Report.swift` (`Settings.typoCorrection: Bool = true`; `neverCorrectEntries: Int?`; `Counters.corrections: UInt64?` and `correctionUndos: UInt64?`, the counts of Task 25 that the design note's section 8 and ADR 0323 promise; today the host counters reach only the integration hooks' `AppStateSnapshot`, not the report, so `ReportAssembly` reads them from `HostCounters` the way the hooks do), `IntegrationHooks.swift` (`AppStateSnapshot.corrections`, `correctionUndos` next to `tapRecoveries`), `ReportLabels.swift`, `ReportLabelsCatalog.swift` (vi `Tự sửa từ gõ nhầm`, en `Fix mistyped words`; the count labels), `IssueBlockFields.swift` (`settings.typoCorrection`, `settings.neverCorrectEntries`, `counters.corrections`, `counters.correctionUndos`), `PlainTextReport.swift`, `ReportJSON.swift`, `Packages/AppCore/Sources/ShellCore/ReportAssembly.swift`, `Packages/AppCore/Sources/TestSupport/Fakes/Diagnostics/DiagnosticsFixtures.swift` (the new keys where the fixture enumerates them)
- Test: `Packages/AppCore/Tests/DiagnosticsTests/**` (the issue block round trip picks up the new keys; add `ReportSettingsTests.d30TheNeverCorrectCountAndTheCountersAppearWithoutWords`: a report built with `neverCorrect = ["androdi"]`, 3 corrections and 1 undo contains `settings.neverCorrectEntries 1`, `counters.corrections 3`, `counters.correctionUndos 1` and never `androdi` or any typed word)

- [ ] **Step 1: Write the test, run, fail. Step 2: Implement. Step 3: Run `swift test --filter DiagnosticsTests`, green (the canary test too). Step 4: Commit.** `feat(diagnostics): report D30, the never-correct list count and the correction counters`

### Task 27: Host decision record and traceability

- [ ] Write `docs/decisions/0323-never-correct-list.md` (storage next to the keep lists under `englishRestoreLists.neverCorrect`, schema version unchanged, one signal is enough, per user across apps, the restore-key variant bit and 32 engines, D30 and D8's on/off state as engine inputs, the counters in the report and the hooks, the 1.0.x compatibility). Update the rows ENG-R1117, ENG-R1118, ENG-R1119, PRD-R4A (host half), PRD-R80 (host half) and PRD-R81 (storage half) of `docs/architecture/traceability.md` with the real suite names of Tasks 23 to 26 (`python3 -I scripts/tests/test_docs_and_workflows.py` checks they exist). Run `python3 -I docs/architecture/tools/sync_contracts.py` for A1's included files (`EngineBridge.swift`, `HostCounters.swift`, `ExportImport.swift`, `Migrations.swift`, `Report.swift`, `UserSettings.swift`) so that `--check` is green on this branch. Commit `docs(host): decision record, traceability and contracts of the never-correct list`.

---

## App track A2: UI and copy (`feat/v110-app-ui`)

### Task 28: Catalog, layout and list model (PRD-R80, PRD-R81)

**Files:**
- Modify: `Packages/AppCore/Sources/ShellCore/Settings/SettingsCatalog.swift` (`SettingItem.neverCorrect`, `.typoCorrection`; `pane` `.typing`; `isAdvanced` false; `dNumber` `"PRD-R81"` and `"D30"`; `jsonKey` `"typoCorrection"`; `title` and `explanation`; `public var dependsOn: SettingItem?` (`.typoCorrection` on `.englishRestore`); `public func isEnabled(in settings: EffectiveSettings) -> Bool`; `public var disabledSuffix: CatalogText?`), `SettingsLayout.swift` (the English section: `[.englishRestore, .keepAsTyped, .keepVietnamese, .neverCorrect, .learnCollisionChoices, .typoCorrection]`; `rows` keeps the keep lists paired and puts `.neverCorrect` on its own row), `WordListsAndLayouts.swift` (`UserWordList.neverCorrect`: `entries(in:)` from `settings.neverCorrect`, `edit(_:)` to `SettingsEdit.neverCorrect(Set<String>)`, `adding` through `NeverCorrectEntry.normalized`, `rows(in:)` without learned entries), `SettingsEdit.swift` (`case neverCorrect(Set<String>)` applied to `UserSettings.neverCorrect`), `SettingsStrings.swift` (`SettingsText` keys below; `SettingsControl.neverCorrectField`, `.neverCorrectAdd`, `.typoCorrection` with label and hint keys)
- Test: `Packages/AppCore/Tests/ShellCoreTests/Settings/SettingsCatalogTests.swift`, `SettingsLayoutTests.swift`, `SettingsModelsTests.swift`

**Interfaces:** `SettingsText` cases and keys: `neverCorrectTitle = "settings.typing.neverCorrect.title"`,
`neverCorrectExplanation`, `neverCorrectExplanationOtherKey`, `neverCorrectExplanationNoKey`, `neverCorrectInvalid`,
`typoCorrectionTitle = "settings.typing.typoCorrection.title"`, `typoCorrectionExplanation`,
`typoCorrectionExplanationOtherKey`, `typoCorrectionExplanationNoKey`, `typoCorrectionDisabledSuffix`. The key
variants follow `learnedChoicesEmpty`, `learnedChoicesEmptyOtherKey` and `learnedChoicesEmptyNoKey` (PRD-R78:
Escape, the key in words from `HotkeyKeyNames.word(for:localizer:)`, or that the key is off).

- [ ] **Step 1: Write the failing tests**: `SettingsCatalogTests.d30SitsRightUnderD28InTheEnglishSectionAndIsNotAdvanced_PRDR80`, `theNeverCorrectListIsTheThirdListOfTheEnglishSection_PRDR81`, `d30IsDisabledWhileD4IsOffWithTheSuffix_PRDR80` (`isEnabled(in:)` false and `disabledSuffix == CatalogText(.typoCorrectionDisabledSuffix)` when `englishRestore` is false; no other item has a dependency), `SettingsLayoutTests.theNeverCorrectListHasItsOwnRow`, `SettingsModelsTests.neverCorrectEntriesAreLettersOnly_PRDR81` (`adding("Androdi")` is `.added(["androdi"])`; `adding("android1")`, `adding("well-known")`, `adding("việt")` are `.invalid`; a duplicate is `.duplicate`).
- [ ] **Step 2: Run, fail. Step 3: Implement. Step 4: Run `swift test --filter ShellCoreTests`; `SettingsCatalogStringTests` is red until Task 29 (the keys have no catalog entry yet). Step 5: Commit.** `feat(shell): D30 and the never-correct list in the settings catalog`

### Task 29: String Catalog (copy verbatim from PRD-R80 and PRD-R81)

**Files:**
- Modify: `App/Resources/Localization/Settings.xcstrings`, `scripts/tests/test_correction_policy.py` (the catalog half: the vi and en values of `settings.typing.typoCorrection.explanation` and its `OtherKey` and `NoKey` variants contain the Q10 words that `CorrectionPolicy.sentenceStart` implies)
- Test: `Packages/AppCore/Tests/ShellCoreTests/Settings/SettingsCatalogStringTests.swift` (existing: every key in vi and en, matching arguments, no literal brand, no dashes, no dead copy), `Tests/ShellCoreTests/Localization/SpecDraftCopyTests.swift` (add the PRD-R80 and PRD-R81 drafts to its table), `scripts/tests/run.sh`

- [ ] **Step 0: Copy review.** PRD-R81 says the copy is reviewed by the product owner with the 1.1.0 strings: hand the strings of Step 2 (vi and en, with the Q10-dependent words marked) to the product owner in this task's report and record the answer, or the fact that it is pending, in the A2 report; the strings ship as drafted until the review changes them (the "Open questions" section lists it).
- [ ] **Step 1: Add the drafts to `SpecDraftCopyTests` and run it: red.**
- [ ] **Step 2: Add the entries** (`%@` is the app name; `%2$@` the key in words in the `OtherKey` variants):
  - `settings.typing.typoCorrection.title`: vi `Tự sửa từ gõ nhầm`, en `Fix mistyped words`.
  - `settings.typing.typoCorrection.explanation`: vi `Gõ nhầm một từ tiếng Anh (androdi, gramar) thì %@ sửa thành từ đúng (android, grammar) khi bạn gõ dấu cách. Không sửa từ tiếng Việt, từ viết hoa toàn bộ hay chữ gõ trong Terminal. Nhấn Escape ngay sau đó để lấy lại từ bạn đã gõ.`; en `When you mistype an English word (androdi, gramar), %@ replaces it with the one word it can be (android, grammar) as you type the space. Vietnamese words, words in all capitals and anything typed in Terminal are never changed. Press Escape right after to get the word you typed back.` (Q10 recommendation; the alternative wording `từ viết hoa` / `capitalised words` is in the comment of the entry.)
  - `settings.typing.typoCorrection.explanationOtherKey` and `.explanationNoKey`: the same with the key named or with the last sentence saying the key is off, as the `learnedChoicesEmpty*` entries do.
  - `settings.typing.typoCorrection.disabledSuffix`: vi `Bật Tự khôi phục từ tiếng Anh để dùng.`, en `Turn on Automatic English restore to use this.`
  - `settings.typing.neverCorrect.title`: vi `Không tự sửa`, en `Never correct`.
  - `settings.typing.neverCorrect.explanation`: vi `Những từ %@ luôn giữ như bạn gõ, không sửa. Từ bạn lấy lại bằng phím Escape được thêm vào đây.`, en `Words %@ always leaves as you typed them. A word you take back with Escape is added here.`; the two key variants as above.
  - `settings.typing.neverCorrect.invalid`: vi `Chỉ nhận chữ cái không dấu, không có số hay ký hiệu.`, en `Letters only, without marks, digits or symbols.`
  - The accessibility label and hint of the three new controls; the add field reuses `Thêm từ mới`.
  - The Typing pane reset confirmation and the full reset confirmation name the list (PRD-R26, PRD-R81): extend the existing bodies (the keys under `settings.reset.` that name the keep lists).
- [ ] **Step 3: Run `swift test --filter "SettingsCatalogStringTests|SpecDraftCopyTests|CatalogAuditTests"` and `scripts/tests/run.sh`.** Expected: green (the policy script now checks the catalog too).
- [ ] **Step 4: Commit.** `feat(app): copy of D30 and the never-correct list (PRD-R80, PRD-R81)`

### Task 30: Typing pane views and the window model

**Files:**
- Modify: `App/Sources/Settings/TypingPaneView.swift` (the third `WordListView` for `.neverCorrect` under the pair, with its own label, box and add area, about seven visible rows like the keep lists (PRD-R81); the refusal message shown under the field as the keep lists show theirs), `App/Sources/Settings/SettingItemRow.swift` (a row whose item `isEnabled(in:)` is false renders its control disabled and appends `disabledSuffix` to the explanation), `App/Sources/Settings/SettingsWindowModel.swift` (add and remove for `.neverCorrect` through `UserWordList`), `App/Sources/Settings/SettingsComponents.swift` if the explanation text is composed there
- Modify: `scripts/snapshots/SettingsSnapshots/SnapshotFixtures.swift` (`neverCorrect = ["androdi"]`, one fixture with D4 off)
- Test: `SettingsCatalogStringTests` (it scans `App/Sources/Settings` for every `SettingsControl` as a focusable control with label and hint), the App build

- [ ] **Step 1: Run `SettingsCatalogStringTests`: red for the three controls not yet used in the app.**
- [ ] **Step 2: Implement the views and the model.** Keyboard reachable, visible focus ring, VoiceOver label naming the word on every remove button (PRD-R66), the setting applies at once (PRD-R27).
- [ ] **Step 3: `xcodegen generate && xcodebuild ... build` and `swift test --filter ShellCoreTests`.** Expected: green. Run `scripts/snapshots/settings.sh` where it can run (not on the product owner's Mac while the VM proof runs) and attach the two renderings to the report.
- [ ] **Step 4: Commit.** `feat(app): D30 row and the never-correct list in the Typing pane`

---

## Integration (`integration/1.1.0`)

### Task 31: Merges

- [ ] Merge `feat/v110-engine-data`, `feat/v110-app-host`, `feat/v110-app-ui`, `feat/v110-engine-logic` (E2a then E2b) with `git merge --no-ff`, in that order; resolve only trivial conflicts (`TRACEABILITY.md`, changelogs); after each merge run that package's tests.

### Task 32: Contracts and spec hygiene

- [ ] `python3 -I docs/architecture/tools/sync_contracts.py`; add to contracts.md 10.5 the lines the host relies on: `corrected(rule)` is one edit of the restore kind; a `neverCorrect` signal may arrive on the restore key and must be stored at once; the switch is the conjunction of ENG-R1119 and every one of its inputs rebuilds the catalog. `python3 -I scripts/check-docs.py links` and `python3 -I scripts/check-docs.py brand` green (the tool takes one of the two subcommands; without one it exits with a usage error). Commit `docs(contracts): typo correction`.

### Task 33: Traceability and changelogs

- [ ] Both traceability files name real suites only: fill the UI halves of the PRD-R80 and PRD-R81 rows of `docs/architecture/traceability.md` with A2's suites (Tasks 28 to 30; no track owns them before this task) and the PRD-R4A row with the engine suites; `check-traceability.py` and `scripts/tests/run.sh` green. `CHANGELOG.md` and `CHANGELOG.vi.md` under Unreleased, Added: the correction (with the two examples, the undo key and the setting), the never-correct list; Known issues: a word before a mid-line click, `googel.com` at the `.`. Engine `CHANGELOG.md` as Task 18 left it. Commit `docs(changelog): typo correction for 1.1.0`.

### Task 34: Benchmark baseline and provenance

- [ ] Run `Packages/VietnameseEngine/Scripts/benchmark.sh` on the baseline machine, commit the result under `Benchmarks/results/` and update `Benchmarks/baseline.json` with the `correction` keys (the M4 note of ENG-R1230 applies). Write `docs/provenance/reports/<date>-1.1.0.md` from the template: note N6 answered (the table's origin, the scripts in `spec/reference-model/`, the SCOWL additions), the new files listed for the outside comparison of N1, `THIRD_PARTY_NOTICES.md` cross-checked. Commit `docs(provenance): 1.1.0 review record`.

### Task 35: Full gates

- [ ] Engine: `swift test` (every suite, fuzz at the per-PR size), `scripts/coverage.sh --package Packages/VietnameseEngine --min 95 --exclude '^Sources/(lexicon-builder|engine-benchmark|site-demo-frames|VietnameseEngineTesting)/'`, `swift run lexicon-builder check`, `python3 -I Packages/VietnameseEngine/Scripts/extract-spec-examples.py --check`, `swift run site-demo-frames --check`.
- [ ] AppCore and App: `swift test`, `scripts/coverage.sh --package Packages/AppCore --min 80`, `xcodegen generate && xcodebuild ... build`, `scripts/lint.sh`, `python3 -I docs/architecture/tools/sync_contracts.py --check`, `scripts/tests/run.sh`.
- [ ] Record every figure in the integration report.

### Task 36: Hand-off to the release track

- [ ] The integration branch stays unmerged until stable 1.0.1 is published: ADR 0009 (1.1.0 is built during the 72 h beta of 1.0.1) is the source of the sequencing, QA-R29 of the cadence. While the beta runs, every 1.0.1 fix that lands on `main` is merged into `integration/1.1.0` with `--no-ff`; when stable 1.0.1 is tagged, merge `main` at that tag into `integration/1.1.0` and rerun Task 35 in full before any 1.1.0 beta. The release of 1.1.0 then follows `docs/runbooks/release.md` (a `1.1.0-beta.1` first); the tart integration run (QA-R12) and the Tier 1 manual pass are the product owner's window and are not part of this plan.

---

## Spec coverage

| Requirement | Tasks |
|---|---|
| ENG-R1110, ENG-R1111, ENG-R1112 | 13, 19 |
| ENG-R1113, ENG-R1114 | 11, 14, 19, 21 |
| ENG-R1125 | 11, 14, 19, 20 |
| ENG-R1115, ENG-R1116 | 13, 14, 16, 19 |
| ENG-R1117 | 15, 19, 25 |
| ENG-R1118 | 3, 15, 23, 25 |
| ENG-R1119 | 1 (the sweep and its pin), 3, 13, 15, 16, 24 (Review Focus 6) |
| ENG-R1120 | 6, 7, 8, 9, 10 |
| ENG-R1121 | 1 (`coreIsClean`), 16, 26 |
| ENG-R1122 | 11, 12, 17, 22 |
| ENG-R1123 | 20 (zero corrections on the Vietnamese corpora; no pattern ships) |
| ENG-R1124 | 20, 21 |
| ENG-T50 to ENG-T57 | 19; 20; 21; 21; 16 and 22; 17 and 22; 10; 20 |
| Q10, Q11 (one named place) | 1, 4, 14, 19, 29 |
| PRD-R4A, D30 default | 3, 28, 29, 30 |
| PRD-R80 | 24, 26, 28, 29, 30 |
| PRD-R81 | 23, 25, 26, 28, 29 (copy review), 30 |
| 12.2 amendments, contracts, traceability, provenance | 1, 5, 9, 18, 22, 27, 32, 33, 34 |

## Open questions for the product owner

Each item names the plan's default (what is built now) and what the other answer changes.

1. **Q10, a capitalised word at a sentence start (ENG-R1111).** Default: corrected (`Androdi` gives `Android`;
   `Biden` at a sentence start would become `Bidden` once, until the restore key teaches the never-correct list).
   Flipping it to never corrected is the edit of the "Q10 and Q11" section: `CorrectionPolicy.sentenceStart`, the
   spec rows and the fixture, and the D30 copy changes from `từ viết hoa toàn bộ` / `words in all capitals` to `từ
   viết hoa` / `capitalised words`.
2. **Q11, correction at Return and Tab (ENG-R1116).** Default: every committing key, so a chat message leaves
   corrected and the restore key cannot undo it (the history is cleared at Return). Flipping it to space and
   punctuation only: `CorrectionPolicy.commitKeys`, row S26 and the fixture; the user then sees the word before
   sending, and a message sent straight after the typo keeps the typo.
3. **The mid-line reset blind spot (Review Focus 2).** After a click or a focus change the engine's history is empty,
   so a word typed right after a `#`, `@` or `/` it never saw is corrected (`#androdi` typed after clicking into the
   middle of a line gives `#android`), the blind spot rule L9 already has (ENG-R850). Default: ship it pinned by
   `TypoCorrectionContextTests.afterAResetTheWordIsACandidate` and listed under Known issues in the changelog.
   The other answer holds the feature until the host can tell the engine the character before the caret after a
   reset, which is a 1.x item (an Accessibility read per reset, PLT-R304 permitting).
4. **Copy review (PRD-R80, PRD-R81).** Default: the strings of Task 29, verbatim from the spec with the Q10 words.
   The product owner reviews them with the 1.1.0 strings when A2 lands (Task 29 Step 0); a change is a catalog edit
   plus the `SpecDraftCopyTests` table and, if the Q10 words change, the spec.
5. **Release sequencing.** Default: `integration/1.1.0` stays unmerged until stable 1.0.1 is published (ADR 0009,
   QA-R29), `main` is merged in at the stable tag and Task 35 rerun, then `1.1.0-beta.1` first; the new benchmark keys
   (`correction.p99`, `correction.max`) are baselined on the M4 as the 13/11/2026 decision allows for ENG-R1230.
   The other answers: a 1.1.0 beta before stable 1.0.1 (two betas in flight, against ADR 0009 item 1's intent), or
   a baseline on the Intel machine of ENG-R1230 (later, when it is available).
