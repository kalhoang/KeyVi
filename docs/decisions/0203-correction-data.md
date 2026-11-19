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

Once the logic track's correction index was built in `Resources.init`, the merged branch measured 52 to 58 ms of
thread CPU (debug, the test alone, load average 16 to 100), over the 50 ms. Measured by phase on 19/11/2026 (debug,
thread CPU medians, load average 8): the index 12.1 ms (5.6 ms for the lexicon's trigrams, 6.5 ms for the shapes and
keyings), the keyings 6.4 ms, the English list 9 ms (parse and set), the ambiguity table 3.6 ms, the attested
syllables 2.3 ms; `Resources.bundled` 37 ms. In a debug build the per-byte loops cost most: a checked buffer
subscript, a static constant read through its lazy accessor and a function call for every byte. The logic track
changed, without changing what is loaded or checked: the shapes and keyings are packed in one pass over the file's
bytes into an array sized by the manifest's entry count (section 6); the index takes the trigrams of the packed words
straight from their letter codes; the loops of the loader and the index read through raw pointers with literal
constants; the UTF-8 lists are split on the LF byte instead of grapheme clusters (a CR before the LF now stays in the
line and fails the entry check, `MalformedResourceTests.attestedEntryProblems`). After: `Resources.bundled` 22.9 ms by
phase (the index 5.4 ms, the keyings 2.3 ms, the English list 7.8 ms); the test alone measures 22.2 to 23.5 ms of
thread CPU at load average 19. Release (`engine-benchmark --quick`, load average 11 to 15): cold 10.8 to 32.0 ms,
median 9.5 to 10.1 ms (the 1.0 baseline recorded 17.8 ms cold and 9.0 ms median on an idle Apple M4).

## 6. Resident budget: the packed sets

ENG-R1120 allows the new data at most 1 MB resident, 512 KB of it for the guard list.
`CorrectionDataTests.correctionDataStaysWithinItsResidentBudget` gates on the heap storage the loaded
`CorrectionData` owns, read from the loaded values (the guard bits, the shapes and keyings at their actual capacity,
the neighbours table), plus what the engine's correction index owns beyond the sets it reads in place (its prefilter
tables and the byte-keyed table of the long lexicon words). It prints, as the cross-check, the plan's malloc
measurement: the live bytes retained by the resources loaded from the bundled directory minus those retained when
the four correction files are minimal, five interleaved loads, no assignment to `Resources.correction`. The gate does
not read malloc figures because they are process-wide (other suites allocate on other threads during the run).

**As the data track left it (open):** 1,321,992 bytes (1.26 MB) owned, 1,328,000 bytes in the malloc cross-check.
The guard list's bits took 131,072 bytes (within 512 KB); the rest was the two `WordSet`s: a `Set<String>` keeps its
load under 75 %, so the 27,277 keyings took 65,536 buckets of 16 bytes (1 MB on their own) and the 3,953 shapes 8,192
buckets (128 KB). The 1 MB assertion was marked as a known issue.

**Decision (logic track, 19/11/2026): the plan's named fallback, before a parser.** A new public type,
`PackedWordSet` (`Sources/VietnameseEngine/Commit/PackedWordSet.swift`), holds every word of 1 to 12 letters `a` to
`z` as one `UInt64`: 5 bits per letter (`a` is 1, `z` is 26, 0 ends the word), the first letter in the highest of
the 60 low bits. A letter is never 0, so a word and its prefixes stay distinct, and the values sort as the words'
bytes do, so the sorted bundled files are already the sorted array. A lookup is a binary search (15 comparisons at
most for the keyings) and allocates nothing; any other word (longer, or with another character) is kept apart in an
ordinary set, empty for the bundled data, so the type takes any words and never answers wrongly. The longest keying
has 9 letters and the longest shape 7, so every bundled word packs.

- `CorrectionData.unmarkedShapes` and `vietnameseKeyings` are `PackedWordSet`s (spec 12.2, sixth amendment, section
  8). The memberwise initialiser that takes `WordSet`s is kept and packs them, so existing callers compile unchanged.
- The loader (`ResourceDirectory.packedWordList`) parses the two files on raw bytes, packs each line and checks the
  strict ascending order as it goes, which also proves the entries unique, into an array reserved at the file's line
  count; a file in another order takes the general path (the word list, then one sort). Every check of the word
  lists is kept: characters, empty lines, the final newline, duplicates with their line, the manifest's entry count,
  and the refusal of an empty list (section 8).
- The correction index reads both sets in place (`CorrectionDataTests.theIndexReadsTheShapesAndKeyingsInPlace`
  checks that the arrays are shared, not copied) and keeps a byte-keyed table only for words of letters that do not
  pack, none in the bundled data.

**Measured (debug, 19/11/2026):** the correction data and the index own **399,784 bytes (0.38 MB)**: guard bits
131,072, keyings 229,344 (27,277 values; the allocator rounds a block of this size up to whole pages), shapes 32,736,
neighbours table 2,056, index 4,576 (the trigram and edge tables and the long lexicon words). The malloc cross-check
reads **377,984 bytes** on each of five loads. The 1 MB assertion holds and is no longer a known issue.

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
the named fallback of ENG-R1120 and 12.2 is amended again if it is ever taken; the loader refuses an empty
`vietnamese-keyings.txt` or `unmarked-shapes.txt` with `malformedResource("<file>: no entry")`, even when its manifest
row agrees, so a resource directory a consumer ships cannot turn ENG-R1110 (d) and ENG-R1125 off unnoticed).

The logic track added a sixth on 19/11/2026, recorded in 12.2 after the five: (6) `CorrectionData.unmarkedShapes` and
`vietnameseKeyings` are `PackedWordSet`s, a new public type (section 6), instead of `WordSet`s; the initialiser that
takes `WordSet`s is kept and packs them. The binary search of a packed set counts among the lookups on preallocated
tables of ENG-R1122: its bound (15 comparisons) is set by the bundled data, not by the lexicon, and ENG-T55 measures
it.

## 9. Departures from the plan

- Task 6 rebuilt `manifest.json` (its inputs digest) at once instead of in Task 8, so that `lexicon-builder check` and
  every test stay green on each commit.
- `GuardList.encode` throws (above 512 KB) instead of returning `Data` unchecked; the build calls it.
- The shared test fixture `Tests/VietnameseEngineDataTests/Support/TestSupport.swift` (not in the data track's list)
  writes format 3 directories with the four files, since every malformed-resource test builds on it.
- The resident budget was over (section 6); the fallback was requested rather than built, and the logic track built
  it (the packed sets, section 6).

## 10. Developer words outside every list

The engine's gates with the bundled data (19/11/2026, `Packages/VietnameseEngine/TRACEABILITY.md` rows ENG-T50 to
ENG-T57) met every target of ENG-R1124 but one: the W11 corpus (13.11) holds four developer words that were in no
bundled list, neither the lexicon (SCOWL sizes 10 to 35), the tech lists nor the guard list (SCOWL sizes 40 to 70 and
names), and each is one edit from exactly one English word, so section 11A corrected it: `frontend` gave `fronted`
(CS0153, CS0232), `backend` gave `backed` (CS0232), `rebase` gave `debase` (CS0173), `debounce` gave `denounce`
(CS0219). The engine followed the spec; the data contradicted the W11 row (zero corrections). A probe of 145 common
developer words on the same day found two more, `upsert` (to `upset`) and `rebased` (to `debased`).

Two remedies were open, both data changes: add the words to the tech-always list (which also decides how 1.0 restores
them), or add a reviewed list of developer words to the guard list's inputs (a new pinned input with its provenance,
the guard list's notice and its size gate unchanged).

**Decision (19/11/2026, the final fix round of 1.1.0): the plan's default, the tech-always list.** A second probe of
303 developer terms with their inflections, typed in Telex and VNI, lowercase after `vieejt ` and in sentence case at
the start, found 18 words corrected: `backend`, `bundlers`, `debounce`, `debounced`, `debounces`, `debouncing`,
`diffed`, `esports`, `frontend`, `initializers`, `rebase`, `rebased`, `rebases`, `rebasing`, `structs`, `upsert`,
`upserting`, `upserts`. They form the last block of `data/inputs/tech-always.txt`. The composition of each is invalid in
both methods, so rule L5 already restored them in 1.0: listing them moves no 1.0 output, and none composes a
Vietnamese syllable that rule L11 would then restore (the list's Telex check). The correction lexicon gains them as
fits (a one-key typo of `frontend` may now be corrected to it); the guard list is unchanged (77,488 words), and `ambiguity-candidates`
finds no new candidate. `TypoCorrectionCorpusGateTests.w11CorpusIsNeverCorrected` lost its known issue (zero
corrections in every W11 file) and `developerWordsAreNeverCorrected` pins the 18 words.

The words are reviewed by the product owner with the list, as every tech-always entry is (plan open question 6): the
product owner accepted them on 20/11/2026 ([ADR 0010](0010-pa-decisions-2026-11-19.md) item 6), after checking that
none of them types a Vietnamese syllable.
