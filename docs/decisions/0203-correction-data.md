# 0203. Typo correction data: guard list, keyboard neighbours, shapes and keyings (resource format 3)

- Status: accepted (engine data track of 1.1.0), 2026-11-19. The product owner may override any choice below with a new
  record.
- Context: the typo correction of 1.1.0 (`spec/01-engine.md` section 11A, PRD-R4A; on by default, D30, ADR 0009) reads
  five resources (ENG-R1120): the correction lexicon (no new file), the guard list, the keyboard neighbours table, the
  unmarked shapes and the Vietnamese keyings. This record covers where the new data comes from, how it is built and
  shipped, what the build and the gates measure, and the amendments of spec 12.2 made by the API stage of 1.1.0.
- Requirements: ENG-R810, ENG-R811, ENG-R812, ENG-R1110 (d), ENG-R1113, ENG-R1120, ENG-R1124, ENG-R1125, ENG-R1231,
  ENG-T52, ENG-T53, ENG-T56, ENG-T57. Plan: `docs/superpowers/plans/2026-11-19-typo-correction.md`, Tasks 6 to 10.

## 1. Guard list sources

ENG-R1120 (2) names the SCOWL "words" lists of sizes 40 to 70 and the "proper-names" lists of sizes 10 to 70 of the
American, British, British-z and English components of the pinned archive (`data/inputs/english/SOURCES.tsv`,
`scowl-2020.12.07.tar.gz`, SHA-256 `5587667c...`, unchanged). The archive holds exactly these 26 members, which
`lexicon-builder import scowl` extracts next to the 12 lexicon lists (`Scowl.guardListFiles`; a member missing from
the archive fails the import):

| File | Bytes | File | Bytes |
|---|---|---|---|
| `english-words.40` | 66,062 | `british-words.40` | 2,864 |
| `english-words.50` | 248,158 | `british-words.50` | 9,654 |
| `english-words.55` | 62,684 | `british-words.55` | 2,846 |
| `english-words.60` | 146,812 | `british-words.60` | 7,039 |
| `english-words.70` | 344,790 | `british-words.70` | 15,321 |
| `american-words.40` | 2,857 | `british_z-words.40` | 2,900 |
| `american-words.50` | 9,521 | `british_z-words.50` | 9,584 |
| `american-words.55` | 2,845 | `british_z-words.55` | 2,846 |
| `american-words.60` | 6,942 | `british_z-words.60` | 7,039 |
| `american-words.70` | 14,858 | `british_z-words.70` | 15,284 |
| `english-proper-names.35` | 18 | `english-proper-names.60` | 1,013 |
| `english-proper-names.40` | 20 | `english-proper-names.70` | 14,010 |
| `english-proper-names.50` | 67,368 | `american-proper-names.50` | 3,426 |

Total 1,066,761 bytes, ISO-8859-1, verbatim from the archive. **Why proper names are six files:** the archive has no
proper-names list at size 10, 20 or 55, none for `british` or `british_z` at or below 70 (their lists start at 80), and
`american` has one at 50 only; the spec's "proper names 10 to 70" is therefore `english-proper-names.{35,40,50,60,70}`
and `american-proper-names.50`.

**Licence check.** The SCOWL `Copyright` file (`data/licenses/SCOWL-2020.12.07-Copyright.txt`, already included whole
in the bundled `NOTICES.txt`) is the permission notice of the whole collection, every size and category, and names the
sources of the proper names: the top 1000 male, female and last names of the 1990 Census report (a government document
its author does not consider copyrightable), Alan Beale's list and a few names the author added. The SCOWL `README`
records that release 2015.05.18 added "some new words found to have a high frequency in the COCA corpus": words chosen
by frequency, not text of that corpus, so nothing of COCA is redistributed. The SCOWL section of `NOTICES.txt`
(`data/licenses/bundled-notices.txt`) now names `guard-list.bloom` and its sizes; `data/NOTICES.md` and
`THIRD_PARTY_NOTICES.md` carry the new rows (ENG-R811).

## 2. The guard filter

The guard words are the entries of the 26 files of five letters or more (ENG-R1111: a shorter typed word is never
looked up), lowercased, ASCII letters only (entries with an apostrophe, a hyphen or a letter outside `a-z` are dropped),
minus the correction lexicon (the English lexicon of 8.2 and the letter-only tech-always entries): **77,488 words**,
the figure the review of the plan computed from the pinned archive.

They ship as an `ApproximateWordSet` (a Bloom filter, spec 12.2 as amended, section 8 below): FNV-1a 64 over the UTF-8
bytes gives `h1`, `h2` is `h1` rotated left by 32 bits and forced odd, the i-th bit is `(h1 + i * h2) & (bitCount - 1)`.
Swift's `Hasher` is never used (seeded per process). The builder takes **8 hashes** and the smallest power of two
`bitCount` whose analytic false-positive rate `(1 - e^(-k n / m))^k` is at most 0.4 %: **2^20 bits (128 KB)**, analytic
rate **0.157 %**; 2^19 bits would give 5.3 %. ENG-T56 measures **180 of 100,000** seeded random strings of 5 to 12
letters answered yes (**0.18 %**, seed 18112026; the gate is 0.5 %), and every one of the 77,488 words answered yes.

`guard-list.bloom` (131,104 bytes): a 32-byte header (`KVGL`, `UInt32` version 1, `UInt32` hashCount, `UInt64`
bitCount, `UInt64` wordCount, 4 zero bytes, little-endian), then the bits as little-endian `UInt64`. The builder fails
when the file would exceed 512 KB; the loader rejects a short file, a bad magic, another version, a hash count outside
1 to 64, a bit count that is not a power of two from 64 to 2^22, non-zero reserved bytes, a bit block of the wrong length
and a word count other than the manifest's `entries`.

## 3. Keyboard neighbours (provenance note N6)

`data/inputs/keyboard-neighbours.txt` is written by the project from the public layout: the three letter rows of the
standard ANSI QWERTY keyboard, `qwertyuiop`, `asdfghjkl` and `zxcvbnm`, a key's neighbours being the two staggered keys
of the row above, its row mates and the two staggered keys of the row below; the file's header states this origin. No
other input method's data and no external table was used. The build (`KeyboardNeighbours.check`) fails unless the table
covers the 26 letters, is symmetric and equals the derivation from the three rows (compared as sets per letter); the
derivation lists the neighbours in the order of ENG-R1113, and the table equals the spec's. The loader checks the 26
letters and the symmetry again. This answers note N6 of `docs/provenance/reports/2026-11-18-1.0.1.md` for the table; the
measurement scripts the note asks about are section 7.

## 4. Unmarked shapes and Vietnamese keyings

Both are generated by `lexicon-builder` from the engine's tier tables (`SyllableTables`, package access), never written
by hand, as the viability structure is (ENG-R346):

- **Unmarked shapes** (ENG-R1110 (d)): every Tier A and Tier B pair with `ă â` to `a`, `ê` to `e`, `ô ơ` to `o`, `ư` to
  `u`, `đ` to `d`, tone ignored: **3,953** (`unmarked-shapes.txt`, 20,217 bytes).
- **Vietnamese keyings** (ENG-R1125): for each Tier A pair and tone it allows, the onset keys (`đ` as `dd`), the vowels
  letter by letter with each marked letter as its two keys (`ươ` both as `uwow` and as `uow`), the standalone `w` for a
  leading `ư` after a consonant other than `q` (`thw`, `twngf`, `thwowng`), the coda, and the tone key last or, with a
  coda, right before it: **27,277** (`vietnamese-keyings.txt`, 176,005 bytes; the longest has 9 letters).

**The count differs from the spec's 27,367 (18/11/2026), by -90.** The model the design note used (its script is not
in the repository) wrote the standalone `w` after no onset as well (`wngs` for `ứng`; +100 keyings) and predates two
pairs the spec added later, `giếc` (ENG-R305) and `Thy` (ENG-R314) (-10). The generator follows the spec's text, "a
consonant other than `q`". Recomputed with the model's tables: 27,367 with `w` after no onset, 27,267 without, 27,277
with the two pairs. Spec 11A's figure is a measurement of 18/11/2026 and is left as written; the integration may update
it.

**The literal `oo`** of the loan rhymes `ooc` and `oong` is written letter by letter (`boong`), which is also the keying
of `ô` (`bông`), never with the escape `ooo` that ENG-T02 types; ENG-R1125 writes the keys letter by letter.

**Independent computation (ENG-T56).** `CorrectionDataTests.shapesAndKeyingsEqualAnIndependentComputation` computes the
shapes from the oracle's spellings (`SpecFixtures.allStandardSyllables` and the Tier B pairs spelled by `SyllableOracle`,
marks removed by Unicode decomposition) and the keyings from `KeyingOracle` (new in `VietnameseEngineTesting`: ENG-T02's
O1 and O2 sequences of `KeySequenceGenerator`, ENG-T03's `explicitUwow` variant, and two helpers for the O2 `uwow` form
and the standalone `w`). Both equal the bundled files exactly (3,953 and 27,277). The reference model
(`spec/reference-model/correction.py`, from `ortho.py`) gives the same two sets.

## 5. Resource format 3

`manifest.json` says `"format": 3`; the loader reads format 3 only (formats 1 and 2 are refused). The four files follow
the collision lists and precede `NOTICES.txt`; the stats gain `guardListWords` (77,488), `guardListBits` (1,048,576),
`unmarkedShapes` (3,953) and `vietnameseKeyings` (27,277). The shapes and keyings are ASCII word lists like the English
lists; `keyboard-neighbours.txt` holds 26 sorted lines `letter<TAB>neighbours`. Problems are reported with the existing
`Resources.LoadError` cases (`malformedResource` with the file name and the problem, `malformedEntry` for a line), so
the public error type does not change. `english.txt` and every format 2 file are byte-identical to before.

Load time (ENG-R1231, debug, `BundledResourcesTests.staysWithinLoadTimeAndMemoryBudget`, shared machine): thread CPU
median 28.8 ms for all resources (25.8 ms recorded for format 2 in the test's comment), live heap growth 3.58 MB. A
first version decoded the bits byte by byte and took 56.5 ms of CPU in debug; the bits are now copied as one block.

## 6. Resident budget: over 1 MB (open)

ENG-R1120 allows the new data at most 1 MB resident, 512 KB of it for the guard list.
`CorrectionDataTests.correctionDataStaysWithinItsResidentBudget` measures what the loaded `CorrectionData` retains
(the drop of live malloc bytes when `Resources.correction` is replaced by `.empty`, five loads): **1,362,432 bytes
(1.30 MB)**. The guard list's bits take 131,072 bytes (within 512 KB). The rest is the two `WordSet`s: a
`Set<String>` keeps its load under 75 %, so the 27,277 keyings take 65,536 buckets of 16 bytes (1 MB on their own) and
the 3,953 shapes 8,192 buckets (128 KB).

The plan's named fallback is a sorted array of packed `UInt64` for the keyings (5 bits per letter; the longest keying
has 9 letters, the longest shape 7, so every word fits one `UInt64`), before a parser: about 218 KB for the keyings and
32 KB for the shapes, so the new data would take about 380 KB. It changes the type of `CorrectionData.unmarkedShapes`
and `vietnameseKeyings` (spec 12.2, `PublicAPI.swift`), which the data track does not own, and it concerns the
correction index of the logic track, which builds its own byte-keyed store from these two fields (a second copy). The
data track therefore records the measurement, marks the 1 MB assertion as a known issue in the test (which fails once
the issue is gone, so the marker cannot outlive the fix) and asks the logic track and the integration to choose the
representation: a packed public type for the two fields that the loader fills from the sorted files and the index
reads in place. The loader side of that change belongs to the data track once the type exists.

## 7. Measurement scripts (provenance note N6)

`spec/reference-model/correction.py` models ENG-R1110 to ENG-R1114 and ENG-R1125 from the spec text;
`--self-check` finds its shapes, keyings and table equal to the bundled files and replays 77 of the 84 rows of 13.12
with none differing (the undo rows S68 to S73, the macro row S67 and S72 are not modelled).
`spec/reference-model/correction_measure.py --seed 18112026` measures the targets of ENG-R1124. Figures on 19/11/2026,
against the design note's table of 18/11/2026:

| Target | 19/11/2026 (rules alone) | with the decision of 8.1 first | 18/11/2026 |
|---|---|---|---|
| ENG-T52 transposition: to the source / to another word | 85.17 % / 0 % | 85.07 % / 0 % | 85.7 % / 0 % |
| ENG-T52 omitted letter | 57.45 % / 1.35 % | 57.33 % / 1.35 % | 57.5 % / 1.32 % |
| ENG-T52 added letter | 74.85 % / 1.28 % | 74.43 % / 1.28 % | 75.8 % / 1.20 % |
| ENG-T52 doubled letter | 95.27 % / 0 % | 90.72 % / 0 % | 95.2 % / 0 % |
| ENG-T52 neighbouring key | 86.77 % / 0.03 % | 86.23 % / 0.02 % | 86.7 % / 0.05 % |
| ENG-T53 rare words, outside the lexicon and tech lists (209,662), no guard list | 3.16 % | | 3.42 % |
| ENG-T53 on its own denominator, outside the lexicon and the guard list (167,958) | 2.74 % | | |
| ENG-T57 Telex typos of Vietnamese words, tone key last | 0 of 3,332 (123 without ENG-R1125) | | 1 of 3,371 (133 without) |
| ENG-T57 plain-letter typos that are neither words nor shapes, each distinct shape typed once | 0 of 570 (50 without ENG-R1125) | | 0 of 579 (53 without) |

Causes of the differences: the samples are drawn by another script with the same seed, so per-kind rates move by up to
one point (6,000 words per kind); the gates hold with margin (80, 50, 70, 90, 80 % and 1.5 %). Rare words: 3.42 % is
reproduced exactly by the plain edit model with its four rules over the lexicon (7,160 of 209,662), so the design note
measured before ENG-R1125 and the list rules; with them, 3.16 %; with the guard list 2.74 % on the spec's denominator
(gate 3.5 %). The doubled-letter rate drops with the decision of 8.1 first because a doubled vowel or tone letter
often composes a Vietnamese syllable that 8.1 keeps (the engine's ENG-T52 types through the engine, Task 21 of the
plan). ENG-T57: the one 18/11 correction (`bloofs` to `bloods`, a typo of the Tier B loanword `blốc`) is not among this
script's random typos.

## 8. Amendments of spec 12.2 by the API stage of 1.1.0

Recorded in 12.2 on 19/11/2026 and restated here: (1) the new public type `ApproximateWordSet`; (2)
`CorrectionData.guardList` is an `ApproximateWordSet`, not a `WordSet`, which cannot answer yes for a word it lacks; (3)
the fields of `CorrectionData` are constants with a public memberwise initialiser, because the engine derives its lookup
structures from them, so they change only through `Resources.correction`; (4) `EngineConfiguration.init` takes
`typoCorrection: Bool = true` (the property was listed without its parameter); (5) `vietnameseKeyings` is generated by
`lexicon-builder` and never empty (12.2 allowed it to be empty when a parser computes the keyings; the parser stays
the named fallback of ENG-R1120 and 12.2 is amended again if it is ever taken). Section 6 may add a sixth: the packed
type of the shapes and keyings.

## 9. Departures from the plan

- Task 6 rebuilt `manifest.json` (its inputs digest) at once instead of in Task 8, so that `lexicon-builder check` and
  every test stay green on each commit.
- `GuardList.encode` throws (above 512 KB) instead of returning `Data` unchecked; the build calls it.
- The shared test fixture `Tests/VietnameseEngineDataTests/Support/TestSupport.swift` (not in the data track's list)
  writes format 3 directories with the four files, since every malformed-resource test builds on it.
- The resident budget is over (section 6); the fallback is requested rather than built.
