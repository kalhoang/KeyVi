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
- Gates of spec 8.8 on the bundled data (`VietnameseEngineDataTests/RealData`): ENG-R870 over the generated
  corpus, ENG-T10 (ENG-R871, ENG-R872) over the 40,701 lexicon and tech words, ENG-T20 (ENG-R873) over
  `data/corpus/prose-vi.txt`, with the measurements of docs/decisions/0202.
- In-process unit tests of `lexicon-builder` (`VietnameseEngineDataTests` depends on it).
- `lexicon-builder ambiguity-candidates` lists words whose display is a valid but unattested Tier A syllable
  and words with a digit typed in VNI, with `method`, `attested` and `merge_as` columns; `--merge` adds
  `en / proposed` rows where rule L8 or the tech-always list restores the word, in a separate
  `# [generated en rows]` block, with a `[generated:unattested]` or `[generated:tech-always]` token in the
  note; `build` and `check` fail when that reason no longer holds.
- `ProseCorpusCheck.run(style:)`: the ENG-T20 typists run in both tone styles; the gate accepts a 5.2
  placement difference only when the typed token is the source spelled in the typist's own style.
- `GeneratedCorpusGateTests.exclusionTotal` prints the ENG-R870 exclusions over all shards.
- `Scripts/coverage.py` also reports the line coverage of the data target and `lexicon-builder`.

### Changed

- The package is licensed under the Mozilla Public License 2.0 instead of MIT, decided on 15/11/2026 before any
  release (ENG-R109, `docs/decisions/0006-app-licence-and-pro-edition.md`): `LICENSE` is the verbatim MPL-2.0
  text, `NOTICE` holds the copyright line, and every source file carries `SPDX-License-Identifier: MPL-2.0`.
- `Engine.init` builds the generated tables, so their one-time construction (about 12 ms in release) no
  longer lands on the first keystroke (ENG-R1230).
- Committing or toggling a long literal token costs a copy, not per-character work: a 100,000-key token
  commits in 0.3 ms instead of 5.7 ms (REG-02, ENG-R1232).
- Bundled data rebuilt with the real engine and retuned for the 8.8 gates (docs/decisions/0202): 1,954
  attested syllables, 619 ambiguity rows, six commands moved to and the Roman numeral `xix` added to the
  tech-always list, `a3` and `a5` removed from it (VNI `ạ`, `ả`), one-letter lexicon entries other than `a`
  and `i` dropped (40,205 words), 53 ENG-T11 exceptions pending review.
- `engine-benchmark` uses the bundled resources and replays the prose corpus with the three typists (ENG-T40);
  `Benchmarks/baseline.json` re-recorded for the new workloads.
- The resource loader proves the uniqueness of byte-sorted lists without building a second set (ENG-R1231).

### Fixed

- English run (ENG-R823, REG-32, product owner 14/11/2026): an English loanword in a Vietnamese sentence no
  longer makes the run English. The run is English only when the previous three committed tokens hold an
  English token and no Vietnamese one, and a token kept by rule L11 is neutral, so `cũng tricky as` commits
  `á` and `trên server been` commits `bên`. The rule only removes L10 restores, never adds one; the cost is
  that a collision within three tokens after a switch from Vietnamese to English stays Vietnamese. The
  prose-corpus difference `Cơ -> Cow` is gone. Spec rows B065-B072 (13.9.2), checked by
  `spec/reference-model/boundary.py`.
- `Orthography` is `Sendable`, as ENG-R1203 requires of every public type.
- `lexicon-builder` checked NFC with String `==`, which accepted decomposed text; it compares scalars now.
- Review of the integration branch: `ĩ` (ầm ĩ) is attested and `ix` is no longer a tech-always word, so
  Telex users can type it; VNI users can type `ạ` and `ả` again; `chown` and `ef` are code-only again
  (`chơn`, `è` are Vietnamese).
- `lexicon-builder ambiguity-candidates` listed `h2o` and `m4a` (a digit ends the token in Telex) with the
  displays `o` and `a`.
- Backspace no longer changes a letter it does not delete (REG-31, ENG-R710 as amended on 14/11/2026): one
  Telex `w` or VNI `7` on `uo` stays with the `ư` when the `ơ` is deleted (`thuowr` + Backspace gives `thư`,
  `nguowif`, space, 3 Backspaces give `ngư`), a re-opened `thuở` gives `thu`, and a `u` whose horns a
  circumflex replaced stays plain. `BackspaceProbe` and the ENG-T38 property tests (generated corpus,
  English lexicon, prose corpus, fuzz invariant) check that every Backspace only deletes, except the
  documented exceptions of ENG-R714.
