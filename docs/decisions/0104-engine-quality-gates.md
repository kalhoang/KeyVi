# 0104. Engine quality gates: fuzzing, corpus, benchmark, coverage, traceability

- Status: accepted, 2026-11-13
- Context: E4 closes the engine with the quality work of spec/01-engine.md 12.4 and 13.5 to 13.7 and
  spec/04-quality-release.md QA-R2, QA-R4, QA-R7 to QA-R9 and QA-R14: property and fuzz tests, the QA-R4
  corpus files, a coverage-guided fuzzing harness, the performance benchmark and its gate, coverage, the
  REG-23 static check, documentation and traceability. The engine itself (decisions 0100 to 0103) was
  complete; this work found one conformance gap (ENG-R1203) and two performance problems, fixed here.
- Requirements: ENG-T30 to ENG-T37, ENG-T40, ENG-R1230 to ENG-R1233, ENG-R875, REG-02, REG-23, QA-R2,
  QA-R4, QA-R7, QA-R8, QA-R9, QA-R14.

## Decision

1. **One invariant checker for fuzzing, corpus and libFuzzer.** `VietnameseEngineTesting/Fuzz/
   InvariantChecker.swift` drives a `Session` and a simulated field and checks after every event: the field
   ends with the engine's view and no edit deletes more than the engine produced (ENG-T31), restore
   exactness (ENG-T32), replay equality and `Engine.reduce` against `Session.handle` (ENG-T33), encoding
   and `deleteCount == deleteUTF16Count` (ENG-T34), VNI isolation (ENG-T35), escape probes (ENG-T36),
   viability (ENG-T37), the history bound (ENG-T30, QA-R7 P3) and a hang detector (P2). The fuzz suite,
   every QA-R4 corpus case and the libFuzzer target use it, so a property holds everywhere or nowhere.
2. **Linear checks for 100,000-key tokens.** Checks that cost time proportional to the token run every
   event for tokens up to 256 keys and every 4,096 events beyond; the field tail is compared over 48
   characters every event and in full every 4,096 events and at the end; the produced-character count is
   exact for the events that can delete a whole long token (toggle, boundary, Backspace on a token of
   more than 64 keys) and capped otherwise. A mutation check (an extra deleted character, a broken stroke
   escape) made the suite fail at once.
3. **Streams.** `FuzzEventSource` draws single events over the full alphabet of 13.6 and, with small
   probability, moves that random keys rarely produce: words that reach each commit rule, macro triggers
   of the table, Backspace runs into the history, consecutive toggles and bursts of up to 4,096 token keys.
   Seeds replay identically on every toolchain (`SeededGenerator.nextInt(below:)`, not the standard
   library's `random(in:)`). `FuzzCombination.all` is every option combination (Telex standalone `w` x
   brackets, VNI; tone style; auto restore; app context; with and without a 1,000-trigger random table):
   80 combinations, history limits and empty resources spread over them. `swift test` sends 1,000,000
   stream events plus 28 long tokens up to 100,000 keys (about 420,000 events) in about 20 s on an M4;
   `ENGINE_FUZZ_EVENTS=100000000` is the nightly setting, `ENGINE_FUZZ_SEED` varies the seeds,
   `ENGINE_FUZZ_HANG_MS` sets the hang detector.
4. **Engine.init builds the generated tables.** The first event of a process used to build the viability
   automaton and the syllable tables: 448 ms in a debug build, 12 ms in release, on the first keystroke.
   `Engine.init` now composes and commits one word, so the cost lands where the host creates the engine
   (at launch and on configuration changes, ENG-R1211), never in the event tap (ENG-R1230, PLT-R304).
5. **Long-token commits in time proportional to a copy.** Committing a 100,000-key literal token took
   5.7 ms (scalar-by-scalar string building, hashing the whole token for every word-list lookup, parsing
   it as a syllable). Raw keys, lowercase forms and literal tails are now built by one copy, `WordSet`
   rejects a word longer than its longest entry before hashing, a literal token's commit form reuses its
   display, and the commit facts stop parsing past 8 letters (`ngh` + a four-letter rhyme; a test checks
   every Tier B pair). The same commit now takes 0.3 ms, a 4,096-key one 12 µs. Decisions are unchanged
   (every corpus and fuzz test passes).
6. **Benchmark (ENG-T40).** `engine-benchmark` (release) replays every Tier A toned syllable typed by the
   three typists of ENG-T20 in Telex and VNI, separated as in prose with occasional corrections, and a
   1,000,000-event fuzz stream, with the 13.9 word lists and a 10,000-entry macro table (ENG-R1105). Each
   event is timed; the report keeps the median over 5 runs of p50, p99, p99.9 and max (QA-R14), and the
   percentiles of each event's fastest time over the 5 runs (`latencyStable`, see the readings). A separate
   10,000,000-event fuzz run gives the worst case; events slower than 20 µs are re-run five times from the
   same state (a shadow session one event behind) and the fastest run is kept, which removes preemption on
   a shared machine and keeps genuinely slow events. It also reports the first `Engine.init`,
   `Resources.bundled` load time and memory (ENG-R1231, once the data track delivers) and long-token
   figures. `Benchmarks/compare.py` calibrates with a fixed reference loop (factor = result / baseline
   reference time) and fails when a calibrated median-run percentile exceeds the budget by more than 20 %
   (ENG-R1233), when a calibrated `latencyStable` percentile is more than 20 % slower than the baseline's
   (QA-R14; slowdowns of at most 100 ns are clock quantisation, about 42 ns per tick on Apple silicon, and
   never fail), when the worst case exceeds 1 ms by more than 20 %, or when the resources exceed 50 ms or
   8 MB.
7. **QA-R4 corpus behind one loader.** Every case file is listed in `QACorpus.caseFiles` and the loader
   rejects a `.tsv` in the folder that is neither a case file nor a fixture. New notation: `«X»×N`
   repetition for long tokens; options `qa-english`, `keep-vi=`, `keep-raw=`. `proper-nouns.tsv` uses
   place names from the official register of administrative units (public domain: state administrative
   documents, Law on Intellectual Property Article 15; names are facts), keys derived by
   `Scripts/vietnamese-keys.py` and reviewed. `layouts.tsv` is generated for QWERTY, QWERTZ, AZERTY,
   Dvorak and Colemak by `Scripts/generate-layout-corpus.py` (`--check`); `LayoutCorpusTests` shows that
   reading the same physical keys as US key codes would type different text on every other layout.
8. **Coverage-guided fuzzing.** `Packages/VietnameseEngineFuzz` (path dependency) exposes
   `LLVMFuzzerTestOneInput` when built with `-DLIBFUZZER -sanitize=fuzzer` on Linux; elsewhere the same
   executable replays files and runs seeded mutations. An input is a configuration byte plus events in the
   `FuzzAlphabet` byte encoding, chosen so that seeds are readable text; 16 seeds are committed (QA-R9).
   The Xcode toolchain has no libFuzzer runtime for Swift, so on the development Mac the libFuzzer entry
   point is type-checked with `-DLIBFUZZER` (the build stops at the link step for want of `main`).
9. **REG-23 as a scanner.** `CoreSourceScanner` blanks comments and string literals and rejects imports,
   logging and I/O symbols, `open(` calls, clocks, randomness, environment and locale, static and global
   `var`s and unchecked concurrency in the core; a second test proves it finds each pattern.
10. **Coverage.** `Scripts/coverage.sh` runs `swift test --enable-code-coverage` and fails below 95 % line
    coverage of `Sources/VietnameseEngine` (QA-R2), reading SwiftPM's llvm-cov export.

## Readings where the text allows more than one, and conflicts

| Topic | Reading used | Why |
|---|---|---|
| ENG-T32 "toggling twice returns the composed display" vs ENG-R702 (a consecutive toggle passes through) | The reducer is checked to pass the second toggle through; "toggling twice" is checked on the token (`ActiveToken.toggleRestore` twice gives the composed display, ENG-R701's second branch) | ENG-R702 is normative and was written after the review; no event other than a toggle leaves a token unchanged, so the composed form can only be reached through the token. |
| ENG-T36 "where K applies" | K applies when it is consumed as a transform or an escape, not appended as a letter and not the key that starts literal mode | A key appended as a letter has no effect to escape. |
| QA-R7 P2 "within 1 ms on the CI machine" | Debug test runs use a 250 ms hang detector (they share the machine with parallel tests and run unoptimised); the 1 ms budget is the release benchmark's re-measured worst case (ENG-R1230) | Wall-clock thresholds of 1 ms in a parallel debug run would fail on scheduling noise, not on engine work. |
| QA-R7 P7 "with Vietnamese mode off, output equals input" | A host property (the host stops sending keys in English mode, `reset(.modeToggled)`); the engine analogue ENG-R874 is tested: VNI streams without digits, toggles or macros pass every key through | The engine has no off mode. |
| ENG-T34 NFC | The test library (standard library only, which has no normalisation API) checks that engine-produced inserts are ASCII or the 146 precomposed letters and contain no combining mark; tests add Foundation's NFC check | The 146 letters are NFC-stable and no two of them or an ASCII letter compose. |
| ENG-T34 `deleteCount == deleteUTF16Count` for every edit | Holds for every edit of the fuzz streams, whose random expansions stay in the Basic Multilingual Plane; an expansion outside it legitimately counts 1 cluster = 2 units (0103, `MacroExpansionTests`) | ENG-R631 is stated for engine-produced spans. |
| ENG-R1230 worst case "in a 10-million-event fuzz run" vs 13.6 tokens of 100,000 keys | The 10,000,000-event run uses bursts of up to 4,096 keys; 100,000-key tokens are reported separately. Restoring such a token rewrites it (ENG-R611: delete after the first difference, insert the rest), so the cost is proportional to the token by the output contract | Measured anyway: 0.29 ms boundary, 0.21 to 0.6 ms toggle for 100,000 keys on an M4, within 1 ms. |
| QA-R14 "median of 5 runs ... compared to the baseline" | The budget gate uses the median of 5 runs. The baseline comparison uses the percentiles of each event's fastest time over the same 5 runs (`latencyStable`) | On the shared development Mac (load average about 10) the median-run p99.9 moved between 2.1 and 11.8 µs from one run to the next with no code change and failed a 20 % gate; the per-event minimum stayed within 1.58 to 1.67 µs. Every run replays the same events from the same states, so the minimum is the engine's own cost. A dedicated CI runner (QA-R14) can switch the comparison back by dropping `latencyStable` from the files. |
| ENG-R1233 budget calibration | Latencies are expressed on the baseline machine (Apple M4) by the reference-loop factor and compared with the M1 budget | No M1 measurement exists; the margin is 20 to 40 times. VERIFY on an M1 and record its reference-loop time. |
| ENG-R872 3 % ceiling | Not asserted with the fixtures: the 13.9 lexicon is made of collision words on purpose (13 of 69 words change in Vietnamese context, all ambiguity candidates). The candidate rule is asserted | 8.8 marks the 3 % VERIFY after building the data. |
| ENG-T20 typists | O2 (marks as the letters arrive, tone right after the vowel group: "canonical"), O1 (tone last) and O3 (modifiers and tone after the coda: "free order") | ENG-T02 calls O1 canonical, ENG-R873 lists "canonical, tone at end, free order"; these three orders cover the three styles. |

## Findings for Pa and the other tracks (no engine change)

- The spec uses ENG-R316 for two requirements (3.3, attested data only breaks English ties; 3.10, no
  open `ươ` in committed text). Both are implemented and traced under the one identifier.
- `giwx` stays as typed: after `g` + `i` the `i` is the vowel (ENG-R306), so a standalone `w` does not
  apply (ENG-R413 needs an empty vowel group). `giữ` is typed `giuwx`. A usability question, not a bug.
- Names with the onsets `f`, `j`, `w` (Cư Jút) cannot compose by the decision in 3.3; names with a coda
  `h` (Chư Păh, Đạ Tẻh) are invalid and restored unless the user keeps them (ENG-R334); Telex names whose
  spelling contains a transform letter where the name has a plain letter need an escape (`Ea Karr`).
- QA-R4's `english` list includes `this`, which the ENG-R821 proposal keeps as `thí` outside an English run;
  the corpus checks it inside a run and shows both.
- `Engine.init` takes about 12 ms the first time in a process (release, M4): the host must create the
  engine at launch, off the event tap thread.

## Measurements (Apple M4 Mac mini, release, `Scripts/benchmark.sh`, `Benchmarks/baseline.json`)

Recorded on the shared development Mac while other builds and a virtual machine ran (load average about
10), 1,601,300 events per run, 5 runs. Median run: p50 0.125 to 0.167 µs, p99 0.8 to 1.5 µs, p99.9 2.1 to
11.8 µs depending on the load. Per-event minimum: p50 0.084 µs, p99 0.71 to 0.75 µs, p99.9 1.58 to 1.67 µs.
Worst case over 10,000,000 fuzz events after re-measurement: 42 to 68 µs, no event over 1 ms. First
`Engine.init` 12 to 16 ms. Long tokens: 100,000-key commit 0.28 to 0.38 ms, 4,096-key commit 12 µs.
Budget: 5 / 25 / 100 µs, worst case 1 ms. The baseline should be re-recorded on the CI runner class in a
`perf-baseline` pull request (QA-R14, QA-R15). Core line coverage 99.6 % (QA-R2: 95 %).
