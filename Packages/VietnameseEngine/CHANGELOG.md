# Changelog

All notable changes to the engine package are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows Semantic Versioning,
separately from the app (spec/04-quality-release.md QA-R27).

## [0.1.0-dev] - Unreleased

### Added

- Letter model and the generated table of the 146 emittable letters, built from Unicode character data
  (ENG-R301).
- Syllable model of spec section 3: onsets, the 156 Tier A rhymes, the 41 `qu` rhymes, the `gi` rules with
  `gi + êc`, Tier B extensions including the `dz` onset; the parser of 3.13, validity tiers, the viability
  automaton generated from the tables (3.14), horn normalisation (5.5), tone placement in both styles
  (5.1, 5.2). Public `Orthography.analyze` and `Orthography.validity(of:)`.
- Composition (sections 4 to 7, 9.1): Telex and VNI key maps, the order of interpretation with viability
  gating, literal mode, free order, sticky escapes, the standalone `w` and bracket options, tone placement
  and relocation on every key, horn handling for `u o`, Backspace inside a token, the restore toggle,
  case and camel case, the 64-key literal cap. The display is a fold over the raw keys (ENG-R601); edits
  are minimal (ENG-R611).
- `Engine.reduce` and `Session` for key, Backspace, restore toggle and reset events.
- Commit decisions (section 8.1): rules L0 to L11 in order with a reason code for each commit; auto restore
  off, user lists, learning signals, app context `code`, the English run, and the `uơ` spelling of an open
  `ươ`. Every boundary key of 9.2 commits the same way and is delivered after the edit.
- History (section 10): Backspace re-opens the previous word across `", "`, `". "` and double spaces;
  configurable limit; resets clear the token and the history.
- Macros (section 11): table validation, matching on the raw span by a fixed-size hash key, expansion
  before L0 with adaptive casing, and the toggle that brings the trigger back.
- DocC comments on every public declaration, checked by a test.
- `VietnameseEngineTesting`: independent oracle, generated O1 to O4 corpus with the ENG-T03 variants,
  loaders for the worked examples extracted from the spec, the 13.9 fixture resources, the simulated text
  field, the fuzz invariant checker (ENG-T30 to ENG-T37), full-alphabet seeded event streams, random macro
  tables, and harnesses for the English corpus (ENG-T10) and prose typists (ENG-T20).
- Fuzz campaign: 1,000,000 events over 80 option combinations plus tokens up to 100,000 keys in the
  default test run; `ENGINE_FUZZ_EVENTS` scales it (QA-R8).
- QA-R4 corpus files `rhymes-rare`, `no-shortcuts`, `macros`, `proper-nouns`, `english`, `collisions`,
  `editing`, `crash-regressions`, `restore-exact` and `layouts`, behind one loader; `known-exceptions.txt`
  and a prose sample.
- `Packages/VietnameseEngineFuzz`: libFuzzer harness with a readable seed corpus (QA-R8, QA-R9).
- `engine-benchmark`, `Benchmarks/baseline.json` and `Benchmarks/compare.py`: the ENG-T40 benchmark and its
  calibrated gate (ENG-R1230 to ENG-R1233, QA-R14).
- Scripts: `benchmark.sh`, `coverage.sh` / `coverage.py` (QA-R2), `check-traceability.py`,
  `generate-layout-corpus.py`, `vietnamese-keys.py`.
- `TRACEABILITY.md`: every ENG-R, ENG-T and REG identifier mapped to code and tests.

### Changed

- `Engine.init` builds the generated tables, so their one-time construction (about 12 ms in release) no
  longer lands on the first keystroke (ENG-R1230).
- Committing or toggling a long literal token costs a copy, not per-character work: a 100,000-key token
  commits in 0.3 ms instead of 5.7 ms (REG-02, ENG-R1232).

### Fixed

- `Orthography` is `Sendable`, as ENG-R1203 requires of every public type.
