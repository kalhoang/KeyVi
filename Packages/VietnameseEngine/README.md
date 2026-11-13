# VietnameseEngine

A Vietnamese composition engine (Telex and VNI) written from scratch from `spec/01-engine.md`. It turns
characters typed on any keyboard layout into precomposed (NFC) Vietnamese text, decides at each word
boundary whether a word should be restored to the keys as typed, and expands macros. It has no state
outside the values it returns, performs no I/O and imports only the Swift standard library.

Licence: MPL-2.0 (see `LICENSE`). Bundled word lists in `VietnameseEngineData` keep their own notices.
Version: 0.1.0-dev (see `CHANGELOG.md`; the engine is versioned separately from the app, QA-R27).

## Targets

| Target | Contents |
|---|---|
| `VietnameseEngine` | Core: letters, orthography (syllable tiers, viability, tone placement), composition, commit rules, macros. Standard library only. |
| `VietnameseEngineData` | Bundled resources and `Resources.bundled()` (data track). |
| `VietnameseEngineTesting` | Test support: independent oracle, generated corpus, spec fixture loaders, simulated text field, the fuzz invariant checker, seeded event streams, random macro tables, corpus targets (English corpus, prose typists). |
| `lexicon-builder` | Builds the bundled resources from pinned inputs (data track). |
| `engine-benchmark` | ENG-T40 benchmark (not a product; `Benchmarks/EngineBenchmark/`). |

`Packages/VietnameseEngineFuzz` is a separate package with the libFuzzer harness (its `README.md` has the
Linux commands).

## API sketch

```swift
import VietnameseEngine

// Create engines at launch or on a configuration change, not in the event tap: the first engine of a
// process builds the generated tables (about 12 ms in a release build).
let engine = Engine(configuration: EngineConfiguration(), resources: .empty)
var session = Session(engine: engine)
for key in "vieetj " {
    let output = session.handle(.key(KeyInput(key)))
    // output.action: .passThrough, or .edit(TextEdit(delete, insert), thenPassThrough:)
    // output.composingText: the active token for marked-text hosts
    // output.decision: at a boundary, the rule of 8.1 that decided (or .macro)
}

Orthography.validity(of: "Krông")   // .extended (Tier B)
Orthography.analyze("giếc")         // onset "gi", vowel group "ê", coda "c", tone .acute, .standard
```

The full public API, with DocC comments, is in `Sources/VietnameseEngine/PublicAPI.swift` (spec section
12.2) and `Sources/VietnameseEngine/Orthography/Orthography.swift`.

## Commands

| Command | What it does |
|---|---|
| `swift build && swift test` | Builds and runs every test, including 1,000,000 fuzz events and every corpus file (about 25 to 45 s on an M4). |
| `ENGINE_FUZZ_EVENTS=100000000 swift test --filter FuzzTests` | Nightly fuzz volume (QA-R8); `ENGINE_FUZZ_SEED=n` varies the seeds. |
| `Scripts/benchmark.sh` | Release benchmark (ENG-T40) and the calibrated gate against `Benchmarks/baseline.json` (ENG-R1233). |
| `Scripts/coverage.sh [--files]` | Tests with coverage; fails below 95 % line coverage of the core (QA-R2). |
| `python3 -I Scripts/check-traceability.py` | Every spec identifier has a row in `TRACEABILITY.md`. |
| `Scripts/bench-composition.sh` | Quick release latency figures from the test microbenchmark (not the gate). |

## Generated sources and data

| Output | Generator | Check |
|---|---|---|
| `Sources/VietnameseEngine/Generated/LetterTable.swift` (146 letters, ENG-R301) | `python3 -I Scripts/generate-letter-table.py` | `--check` |
| `Tests/VietnameseEngineTests/Corpus/{worked-examples,commit-decisions,restore-toggle,commit-fixtures}.tsv` (spec 13.8 to 13.10) | `python3 -I Scripts/extract-spec-examples.py` | `--check` |
| `Tests/VietnameseEngineTests/Corpus/layouts.tsv` (QA-R4 layouts) | `python3 -I Scripts/generate-layout-corpus.py` | `--check` |

Never edit these files by hand; change the spec or the generator and regenerate. The other QA-R4 corpus
files are hand curated (one case per line; format in their headers and in
`VietnameseEngineTesting/Fixtures/QACorpus.swift`); `Scripts/vietnamese-keys.py` derives canonical
keystrokes for new rows. QA-R6: an expected value changes only in a pull request labelled `corpus-change`.

## Tests

Swift Testing, organised by area under `Tests/VietnameseEngineTests`:

| Folder | What it checks |
|---|---|
| `Letters` | the letter model and the generated letter table, re-derived from Unicode data |
| `Orthography` | parser (3.13), validity tiers (3.10 to 3.12), viability (3.14), tone placement (5.1 to 5.4), horn normalisation (5.5), `Orthography.analyze`, the inventory counts printed for ENG-R350 |
| `Oracle` | the oracle (ENG-T01) and the generated O1 to O4 corpus and variants (ENG-T02, ENG-T03) |
| `Composition` | worked examples W001-W253, the 6.2 edit traces, restore toggles E01-E08, the generated corpus against the oracle, rule tests, replay properties, a microbenchmark |
| `Commit` | commit decisions B001-B064 at every boundary key, rules L0-L11, the English run, history, resets, macros, REG-01 to REG-30, the generated corpus committed (ENG-R870), the ENG-T12 spot list, commit properties, and the QA-R4 corpus loader |
| `Quality` | the fuzz campaign (13.6), long tokens to 100,000 keys, keyboard layouts, the 8.8 targets with fixture data, the API contract (ENG-R1203, ENG-R450), the REG-23 source scan, documentation and traceability checks |
| `Corpus` | data files: the QA-R4 categories (`README.txt` lists them), the spec fixtures, `prose-sample.txt`, `known-exceptions.txt` |

Current figures (Apple M4): core line coverage 99.6 %; per event p50 0.125 µs, p99 0.79 µs, p99.9 2.1 µs,
worst case 42 µs over 10,000,000 fuzz events (budget 5 / 25 / 100 µs and 1 ms).

## Decisions

`docs/decisions/0100-engine-syllable-counts.md` (counts and their differences from the spec's reference
model), `0101-engine-letter-model-and-orthography-structures.md` (internal representations),
`0102-engine-composition-model.md` (composition, sections 4 to 7), `0103-engine-commit-history-macros.md`
(sections 8 to 11) and `0104-engine-quality-gates.md` (fuzzing, corpus, benchmark, coverage, readings of
13.6 and 12.4). Requirement-by-requirement mapping: `TRACEABILITY.md`.
