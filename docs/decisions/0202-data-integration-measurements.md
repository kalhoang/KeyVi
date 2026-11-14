# 0202. Data integration with the real engine: measurements, gates and data choices

- Status: accepted (engine-integration track), 2026-11-13. Pa may override any choice below with a new record.
- Context: the data track (0200, 0201) built the word lists while the engine was a stub, so the attested list,
  the ambiguity candidates and every measurable target of spec/01-engine.md 8.8 waited for the engine (0100 to
  0104). This record covers the rebuild with the real engine, the gates wired on the bundled data, the data
  changes those gates asked for, and the measurements the spec marks VERIFY.
- Requirements: ENG-R810, ENG-R820, ENG-R821, ENG-R823, ENG-R870 to ENG-R873, ENG-R1231, ENG-T10, ENG-T11,
  ENG-T20, ENG-T40; spec 8.2 (VERIFY the SCOWL level) and 8.8 (VERIFY the 3 % of ENG-R872).
- Rule followed throughout: tune the data, never the engine rules. Where data cannot meet a target, the
  measured number and the reason are recorded below as an open issue.

## 1. Rebuild

`lexicon-builder build`, `ambiguity-candidates --merge`, `pin`, `build`, as data/README.md describes.
`attested.txt` now holds 1,954 syllables: 1,678 valid syllables of the 1,784 distinct legal-text tokens, 263
reviewed additions not found in the texts and 13 other-style variants of open `oa`/`oe`/`uy` syllables.

## 2. ENG-R820 extended (builder change)

1. **Unattested displays are candidates.** Spec 8.3 lists only words whose display is an attested Tier A
   syllable. An English word whose display is a valid but unattested Tier A syllable is restored by rule L8
   before the table is read (the open issue of 0103), and ENG-R870 can exclude it only as an `en` row. The
   generator now lists every word whose Telex display (either tone style) is a Tier A syllable, with a column
   `attested` (`yes` when every display is in `attested.txt`).
2. **VNI for words with a digit.** A word without digits never changes in VNI (ENG-R874), so only words with a
   digit are typed in VNI too: `a4`, `co2`, `o2` (method column `vni`; `a3` and `a5` left the tech-always list,
   see section 6).
3. **One token or nothing.** A word that a boundary splits into tokens (a digit in Telex) has no single
   display; `h2o` and `m4a` used to be listed with the displays `o` and `a`.
4. **Merge policy** (`merge_as` column; `--merge` adds the row only when the raw keys have none):

   | Candidate | Row added | Why |
   |---|---|---|
   | English raw keys (8.1: lexicon or tech-always), display not attested | `en / proposed` | L8 restores it whatever the row says; a `vi` row would contradict the behaviour |
   | tech-always word | `en / proposed` | the behaviour L11 gives tech-always words without a row |
   | anything else | `vi / unreviewed` | ENG-R821: behaves as `vi`, never damages Vietnamese |

   `proposed` keeps the meaning of the table header: a starting decision that applies as written until Pa
   confirms or flips it. Flipping an unattested row to `vi` also needs an attested addition, or L8 still
   restores the word.
5. **Generated rows are self-checking** (branch review): the generated `en` rows live in the last block of the
   table (`# [generated en rows]`), apart from the rows Pa reviews, and each note ends with its reason,
   `[generated:unattested]` or `[generated:tech-always]`. `lexicon-builder build` (and `check`) fails when the
   reason no longer holds: the display became attested (for example after attesting `són`, `chỏi` or `mán`),
   or the word left the lexicon or the tech-always list. A row cannot outlive the rule it restates.

Result: 618 candidates (615 Telex, 3 VNI): 349 attested `vi / unreviewed`, 2 unattested code-only
`vi / unreviewed` (`chown`, `ef`), 3 attested tech-always `en / proposed`, 264 unattested `en / proposed`
(`or` among them, a hand row). Of the 300 most frequent, 189 are attested.

## 3. Data changes the gates asked for

Each change is in a hand-edited input with a reason and is listed for Pa's review.

| Change | Files | Found by | Reason |
|---|---|---|---|
| 20 attested additions: rơ, sên, tráp, chái, ché, gô, lể, mố, rế, sác, sớ, sú, táng, tể, tót, dể, ò, ả, cò, ĩ | `inputs/attested-additions.txt` | unattested candidates, branch review (`ĩ`) | everyday syllables whose natural typing is an English or tech word (`row`, `seen`, `leer`, `tots`, `of`, VNI `co2`, `IX`); without them L8 restores the Vietnamese word, the REG-29 kind of damage. Displays that are not everyday words (`dóe`, `pót`, `sáy`) stay unattested |
| `or` row: `vi / unreviewed` to `en / proposed` | `inputs/ambiguity.tsv` | ENG-R870 | `ỏ` is not an everyday word and not attested, so L8 restores `or`; the row now states that |
| aux, auxf, diff, otool, passwd, tox: tech-code-only to tech-always | `inputs/tech-*.txt` | ENG-R871 | no Vietnamese reading (`ãu`, `àu`, `tõ`; `dif`, `otol`, `paswd` are escape forms). As code-only words they are not English (8.1), so L7 and L4 kept those forms in every general-context text. `awk`, `chown` and `ef` stay code-only (section 6) |
| xix added to tech-always | `inputs/tech-always.txt` | ENG-R873 | Roman numeral of legal texts and dates (`thế kỷ XIX`) composed `XĨ`, not a syllable anyone types |
| one-letter SCOWL entries other than `a` and `i` dropped (`m`) | builder (`EnglishLexicon.oneLetterWords`) | ENG-R873 | Vietnamese text uses lone consonants as list markers (`m)`) and chat abbreviations (`m` for mày); ENG-R823 made `m` an English token that turned the run English (`bản` typed `barn` was restored by L10). 40,205 words |
| 53 ENG-T11 entries | `Tests/VietnameseEngineTests/Corpus/known-exceptions.txt` | ENG-R871 | 50 words where rule L4 keeps an escape form that is itself an English word (`pass` -> `pas`, `off` -> `of`, `costs` -> `cots`), `awk` (L6, code-only), `chown` and `ef` (L7, code-only). Pending Pa's review |

The final table has 619 rows: 334 `vi / unreviewed`, 274 `en / proposed` (7 ENG-R821 proposals, `or`, 266
generated: 263 `[generated:unattested]`, 3 `[generated:tech-always]`), 11 `vi / proposed`.

## 4. Gates on the bundled data (VietnameseEngineDataTests/RealData)

`Resources.bundled` is loaded once; `data/corpus/prose-vi.txt` and `known-exceptions.txt` are read from the
repository checkout, where `swift test` runs locally and in CI, so nothing is copied and `lexicon-builder
check` keeps guarding the single corpus file.

Readings where the text allows more than one:

| Topic | Reading | Why |
|---|---|---|
| ENG-R871 share | counts every changed word, listed or not | "at least 99.5 % of words unchanged": an exception explains a change, it does not undo it. The fixture harness's `unchangedShareInEnglishRun(exceptions:)` excludes listed words; the gate does not use it |
| ENG-R872 "100 % of changed words are vi rows" | a change is explained by a `vi` row or by an ENG-T11 entry of the same corpus that changes identically in both contexts | rules L4 and L6 decide before the run language (L10) and the table (L11), so those 51 words change in Vietnamese context exactly as in the English run; ENG-T11 defines the documented exceptions of ENG-T10, which asserts both requirements. No row can change their behaviour, so a row added for them would only hide them |
| ENG-R873 "identical to the source" | the typists run in both tone styles; a token counts as identical when the typed form is exactly the source syllable spelled by `SyllableOracle` in the typist's own style (`hoá` typed `hóa` by a traditional typist, never the reverse); the count is printed and the strict share too | the legal texts mix both placements (`hoá` 339 times, `hóa` 366; `thoả` 89, `thỏa` 423; `uỷ` 36, `ủy` 364), while a typist has one style setting; no typist can reproduce both. The source is kept as extracted. The comparison is directional, so a typist that writes the other style's placement (a 5.2 regression) is still a difference |
| ENG-R1231 in a debug test | asserts the median CPU time of the loading thread and a loose median wall time (under twice the budget); the fastest wall time is printed only; the release benchmark gates the cold wall-clock load | parallel suites stretched the debug wall time to 41 ms (21 ms alone) with waiting, not loading, and on the shared machine even the fastest of five loads reached 51.4 ms with 25.8 ms of CPU time; the loose guard still fails the unit test on a real slowdown |

## 5. Measurements (Apple M4 Mac mini, shared with other builds)

| Target | Measured | Spec |
|---|---|---|
| ENG-R870 generated corpus | 269,500 cases, 100 % equal to the oracle; 486 case variants of 194 raw strings excluded, all `en` rows (`GeneratedCorpusGateTests.exclusionTotal`), listed per shard | 100 %, only `en` rows excluded |
| ENG-R871 English run | 40,698 words, 53 changed, 99.870 % unchanged, every change an ENG-T11 entry | at least 99.5 % |
| ENG-R872 Vietnamese context | 395 changed (0.971 %): 342 `vi` rows, 53 ENG-T11 entries | at most 3 % (VERIFY: confirmed with margin) |
| ENG-R873 prose | 250,006 tokens per typist, 3 typists x 2 methods x 2 tone styles: VNI 100 %, Telex 99.9992 % (2 tokens: twice `IX` -> `Ĩ`, open issue 3; 99.9988 % with a third token, `Cơ` -> `Cow`, before the amended ENG-R823 of 14/11/2026, open issue 2); tokens that are the source in the typist's own placement: 527 per traditional typist (strictly identical 99.788 %), 2,315 per modern typist (strictly identical 99.073 %) | at least 99.95 %, every difference an `en` row |
| ENG-R1231 release (`engine-benchmark`) | cold 17.8 to 32.4 ms, median 9.0 to 14.0 ms, resident growth 1.06 to 1.6 MB | 50 ms, 8 MB |
| ENG-R1231 debug test | thread CPU 14 to 31 ms, median wall time 34 to 75 ms with all suites in parallel, live heap growth 1.16 MB | |
| ENG-T40 benchmark | 3,352,412 events per run (prose 50,000 words per typist in both methods, generated-corpus typists, 1,000,000 fuzz events), bundled resources and a 10,000-entry macro table: median-run p50 0.167 us, p99 0.875 to 1.0 us, p99.9 1.9 to 4.8 us; per-event minimum p50 0.166 us, p99 0.75 us, p99.9 1.54 us; worst case over 10,000,000 fuzz events 45 to 62 us | 5 / 25 / 100 us, 1 ms |

**SCOWL level (spec 8.2 VERIFY).** Collisions measured with `ambiguity-candidates` on the pinned archive
(levels 40 and 50 extracted to a scratch directory for the measurement only), cumulative:

| Levels | Words | Tier A collisions | attested display | unattested display |
|---|---|---|---|---|
| 10 | 4,014 | 128 (3.19 %) | 83 | 45 |
| 10-20 | 11,109 | 280 (2.52 %) | 169 | 111 |
| 10-35 | 40,205 | 605 (1.50 %) | 349 | 256 |
| 10-40 | 45,114 | 642 (1.42 %) | 358 | 284 |
| 10-50 | 63,415 | 736 (1.16 %) | 380 | 356 |

Level 35 stays. Level 50 adds 23,210 rare words and 131 collisions: 100 more English words that L8 restores
when a Vietnamese typist's unattested syllable happens to be typed that way, and 31 more rows to review, for
words rare enough that they seldom meet Vietnamese typing. Level 40 adds 37 collisions for 4,909 words.

**Benchmark baseline.** The workloads changed (bundled resources instead of the 13.9 fixtures, prose corpus
typists added), so `Benchmarks/baseline.json` was re-recorded. Like for like nothing regressed: generated
typists Telex per-event minimum 166 / 792 / 1,417 ns against 167 / 792 / 1,458 ns before, fuzz equal or
faster. The combined p50 rose from 84 to 166 ns only because prose events (p50 166 ns) now outnumber the
cheaper fuzz events (83 ns). A second run passed the gate against the new baseline.

## 6. Branch review, 2026-11-13

An independent review asked for these data changes, all made (tests first where code changed):

| Finding | Change |
|---|---|
| `ix` in tech-always made `ĩ` (ầm ĩ) un-typeable in Telex | `ix` removed from `tech-always.txt` and its row deleted; `ĩ` attested with a reason; `IX -> Ĩ` is a known issue of ENG-R873 (open issue 3) |
| `a3`, `a5` blocked VNI `ả`, `ạ` | removed from `tech-always.txt`, rows deleted (open issue 4) |
| generated `en` rows were unreviewed live decisions with no check | own block, reason token, build check (section 2, item 5; open issue 5) |
| tone-placement equivalence was direction-blind and only the traditional style ran | directional comparison against `SyllableOracle`, typists in both styles (section 4) |
| `chown`, `ef` moved out of code-only | moved back, ENG-T11 entries (open issue 6) |
| stale exclusion count | `exclusionTotal` prints the total; section 5 copies it |
| debug ENG-R1231 assertion too weak | median wall time under twice the budget added; the fastest-of-five wall assertion, which flaked on the shared machine (51.4 ms), is printed only |
| baseline re-recorded in a feature branch (QA-R15) | kept: the old baseline cannot gate the new workload set. Re-recording on the CI runner class through a perf-baseline change is requested from the scripts/CI track |

## Open issues for Pa (data cannot fix them)

1. **Rule L4 keeps escape forms that are English words** (50 words, ENG-R871 failures inside the 0.5 %):
   `off` -> `of`, `pass` -> `pas`, `mess` -> `mes`, `mass` -> `mas`, `hiss` -> `his`, `costs` -> `cots`.
   Dropping `of`, `as`, `his` or `pas` from the lexicon would break those words, so this is an engine or spec
   question (L4 order), not data.
2. **Rule L10 after an English word of the source** (ENG-R873, 1 token per Telex typist): `trên Internet.
   Cơ chế` made the run English (ENG-R823), so `Cơ`, typed `Cow`, was restored. *Resolved on 14/11/2026* by
   the amended ENG-R823 (Pa's report `cũng tricky á` -> `as`, [0005](0005-pa-decisions-2026-11-13.md)): the
   run is English only when the previous three committed tokens hold an `en` token and no `vi` token, and an
   L11 keep is neutral, so `trên` keeps `Cơ` Vietnamese; `ProseCorpusGateTests` no longer lists it. Two-letter
   SCOWL words that Vietnamese chat uses as abbreviations (`cs`, `ms`) still turn the run English, but only
   when no Vietnamese token is among the previous three.
3. **`IX` in Telex types `Ĩ`** (ENG-R873, 2 tokens per Telex typist: `Chương IX`). `ĩ` is the everyday
   syllable of `ầm ĩ`, so it is attested and `ix` is not a tech-always word: the default never damages
   Vietnamese (ENG-R821), and no other key order types `ĩ`. Recorded as a known issue in
   `ProseCorpusGateTests`. `XIX` stays tech-always (`xĩ` is not a word). Pa decides whether Roman numerals
   should win (for example by a keep-as-typed entry).
4. **Paper sizes in VNI**: `a3` and `a5` are not tech-always words, so VNI `a3` types `ả` and `a5` types `ạ`
   (the particle, one of the most frequent tokens in chat); before the review L11 restored them everywhere.
   `a4` stays (`ã` is not a word). `co2` is still `en / proposed` (tech-always), so a VNI user who types `cò`
   as `co2` gets `co2`; `cò` is attested so that flipping the row to `vi` works. A VNI user who wants `A5`
   types it through the keep-as-typed list; in Telex digits are boundaries and nothing changes. Pa decides
   all three with the frequencies in mind.
5. **ENG-R870 rests on 266 generated `en` rows.** The generated corpus passes at 100 % only because the
   unattested displays that rule L8 restores (0103 open issue) are excluded as `en` rows that no one decided.
   The rows restate L8; the build check (section 2, item 5) keeps them from outliving it, but the engine and
   spec question of 0103 (L8 against ENG-R870) is not answered by data.
6. **`chown` and `ef`** stay code-only: their displays `chơn` (Chơn Thành, chơn chất, tay chơn) and `è` (è
   cổ) are Vietnamese, so they are ENG-T11 entries (L7) instead of tech-always words. Attesting `chơn` is Pa's
   call; it would not change their behaviour (L7 keeps them in the general context, L9 restores them in code).
7. **ENG-R821 review**: the 300 most frequent candidates of `data/derived/ambiguity-candidates.tsv`, the 20
   attested additions, the 7 tech-always additions and the 53 ENG-T11 entries.
