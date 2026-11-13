# 0201. Bundled resource format, loader and build policy

- Status: accepted (engine-data track), 2026-11-13.
- Requirements: spec/01-engine.md 8.2, 8.3, 12.1, 12.4 (ENG-R810, ENG-R811, ENG-R812, ENG-R820, ENG-R821,
  ENG-R1203, ENG-R1231), 13.4 (ENG-T20).

## Decisions

1. **Resource format 1** (`Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources/`).
   Word lists are UTF-8, LF, one entry per line, final newline, no comments or blank lines, sorted by UTF-8
   bytes, unique. `ambiguity.tsv` keeps the five input columns with a header. `manifest.json` records
   format, the SHA-256 of `data/inputs/MANIFEST.sha256`, and for every file its size, entry count and
   SHA-256, plus build statistics. JSON is written by hand with a fixed key order and SHA-256 is computed
   by a portable implementation, so output bytes do not depend on Foundation or the host (ENG-R810).
2. **Strict loading.** `Resources.load(from:)` (and `Resources.bundled`, which calls it on
   `Bundle.module`) verifies size, entry count and SHA-256 against `manifest.json` (SHA-256 with CryptoKit
   where available) and validates every entry: English `a-z`; tech lists and ambiguity raw keys `a-z0-9`
   with at least one letter; attested syllables lowercase NFC Vietnamese letters; ambiguity decisions
   `vi|en` and statuses `proposed|reviewed|unreviewed`. Errors are typed (`Resources.LoadError`) and name
   the file and line. The original `missingResource` and `malformedResource` cases are kept;
   `malformedEntry` and `integrityMismatch` were added.
3. **Representation.** The public `WordSet` (engine contract, `Set<String>`) is used as is: measured
   1.06 MB of live heap for all lists, load 4.5 ms in release and about 18-25 ms in debug on the
   development Mac, well inside ENG-R1231 (8 MB, 50 ms). A compact representation is not needed.
4. **Ambiguity semantics in the loader** (`[String: Language]`, rule L11): `proposed` and `reviewed` rows
   apply their decision (the B-table of spec 13.9 uses the ENG-R821 proposals as the table); `unreviewed`
   rows map to `.vietnamese` whatever their decision column says (ENG-R821).
5. **Attested set** = legal-text tokens with `Orthography.validity != .invalid` (Tier A or B) + every
   reviewed hand addition (added even if the validator disagrees, because Pa decided it) + the other tone
   placement of open `oa`/`oe`/`uy` syllables (spec 5.2), so that both tone styles find their committed
   display. The unfiltered token list with counts is kept in `data/derived/attested-candidates.tsv` so that
   the data is reviewable before the engine's validator exists.
6. **Tokeniser** (attested list and prose corpus): NFC, split on non-letters (`Character.isLetter`), keep
   runs made only of Vietnamese letters (12 vowels with any tone, Tier A consonants and `z`; `f j w` are
   not Vietnamese letters). The attested tokeniser lowercases; the prose tokeniser keeps the case.
7. **Prose corpus** (ENG-T20): paragraphs taken round-robin from the 13 documents (SOURCES.tsv order) until
   250,000 tokens (the spec asks for at least 200,000), one paragraph per line, tokens separated by one
   space, `#` header with the token count. Round-robin keeps every document represented.
8. **Ambiguity candidates** (ENG-R820): every SCOWL word and both tech lists, typed key by key through
   `Session` with `EngineConfiguration(inputMethod: .telex(TelexOptions()), toneStyle:)` for both styles and
   `Resources.empty`; a candidate is a word whose display differs from the raw keys, is in `attested.txt`
   and has `Orthography.validity == .standard`. Frequency proxy, all legally clean: the SCOWL size level
   (10 = most common), then the count of the display in the legal corpus, then the raw keys. `--merge` adds
   missing candidates to `data/inputs/ambiguity.tsv` as `vi`/`unreviewed`.
9. **Pinned inputs.** `data/inputs/MANIFEST.sha256` (shasum format) pins every file under `data/inputs/` and
   `data/licenses/`; `build` and `prose-corpus` refuse to run when a file is changed, missing or unpinned.
   After a reviewed edit, `lexicon-builder pin` re-pins. `check` (CI) rebuilds into memory and compares the
   resources, `data/derived/` and the prose corpus byte for byte.
10. **Tests drive lexicon-builder as a subprocess.** The test target cannot import an executable target
    without a manifest change (outside this track); the tests locate the built `lexicon-builder` next to the
    test bundle. A manifest change that adds `lexicon-builder` as a dependency of
    `VietnameseEngineDataTests` would allow direct unit tests; it is requested from the owner of
    `Package.swift`.

## Consequences

- After the engine track's merge: run `lexicon-builder build`, `lexicon-builder ambiguity-candidates --merge`,
  `lexicon-builder pin`, `lexicon-builder build` again, and commit; the `ambiguityCandidatesRunAgainstTheRealEngine`
  test then exercises real candidates.
- Changing the resource format requires bumping `format` in both lexicon-builder and the loader.

## Amendment, 2026-11-13 (engine integration, docs/decisions/0202)

- **Decision 8 extended**: candidates also include English words whose display is a valid but unattested
  Tier A syllable (rule L8 restores them, so ENG-R870 needs them as `en` rows) and words with a digit typed in
  VNI; a word that a boundary splits into tokens is not a candidate. The candidate file gains the columns
  `method`, `attested` and `merge_as`, and `--merge` adds `en / proposed` for English words with an unattested
  display and for tech-always words, `vi / unreviewed` otherwise.
- **Decision 10 superseded**: `Package.swift` now makes `lexicon-builder` a dependency of
  `VietnameseEngineDataTests`; its logic is unit-tested in-process (`@testable import lexicon_builder`) and the
  CLI tests keep driving the executable, found through `Bundle(for:)`.
- **Decision 3 numbers** with the real data: release cold load 17.8 to 31.9 ms, median 9 to 10 ms, resident
  growth about 1.1 MB. The loader proves the uniqueness of a byte-sorted list by comparing neighbours instead
  of building a second set (debug load about 21 ms to 15 ms).
- **Validation fix**: the builder's NFC checks compare Unicode scalars (String `==` accepted decomposed text).
