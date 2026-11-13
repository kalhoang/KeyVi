# 0100. Engine syllable inventory: counts and table readings

- Status: accepted, 2026-11-13
- Context: spec/01-engine.md 3.15 quotes reference counts from the spec author's model
  (spec/reference-model/ortho.py) and ENG-R350 asks that every difference be explained. The model
  predates three additions the implementation must include: rhyme `êc` after `gi` (ENG-R305), open `y`
  after `th` (ENG-R314) and the `dz` onset (3.3, ENG-R316).
- Requirements: ENG-R301 to ENG-R350, ENG-T02 to ENG-T04.

## Counts printed by the implementation

`swift test --filter SyllableCountTests` and `--filter GeneratedCorpusTests` print these lines.

| Quantity | Spec (3.15, 13.2) | Implementation | Difference |
|---|---|---|---|
| Tier A rhymes (3.7) | 156 | 156 | none |
| Rhymes after `qu` (3.8) | 41 | 41 | none |
| Tier A onset-rhyme pairs | 3,368 | **3,367** | -1: duplicate `giu` (below) |
| Tier A toned syllables | 15,412 | **15,406** | -6: the six tones of the duplicate |
| Tier B pairs incl. Tier A, without `dz` | 6,209 | **6,208** | -1: duplicate `giu` |
| Tier B pairs incl. Tier A, with `dz` | not given | **6,387** | +179 for `dz` (below) |
| O1 to O4 cases (ENG-T04) | 237,916 | **237,824** | -92: the duplicate's cases (3 + 4 x 5 orders, x 2 methods x 2 styles) |
| ENG-T03 variant cases | 30,928 (first draft) | **31,676** | different variant set (below) |

The tests assert the implementation's numbers and also assert that adding back the documented
duplicate gives the spec's numbers exactly (3,368 / 15,412 / 6,209 / 237,916).

## Finding 1: the reference model counts the spelling `giu` twice

The model generates pairs as (onset, rhyme) tuples. For onset `g` it allows every rhyme that starts with
`i`, including `iu`, and for onset `gi` it allows `u`. Both tuples are spelled `giu`. The parse of 3.13,
which is normative, reads `giu` only as `gi` + `u` (the letter after `gi` is a vowel letter, ENG-R305),
and 3.3 restricts `g` + `i` to "an `i` rhyme with no further vowel letter" (`gì`, `gìn`, `gỉ`). The model
itself agrees: its oracle re-parses the spelling, so the `g` + `iu` cases expect exactly the strings of
the `gi` + `u` cases (`giú`, not `gíu`), and its corpus tests the same 92 key sequences twice.

So the model, not the tables, is wrong here. The implementation keeps a pair only if its spelling parses
back into the same onset and rhyme (`SyllableTables.pairTiers`); this drops `g` + `iu` and nothing else.
A full comparison (all 6,387 pairs and their tiers) of the Swift inventory against the model plus the
three documented additions and minus this duplicate found no other difference.

The model's first-draft numbers reproduce the review arithmetic of 3.15: 3,366 + `gi êc` + `th y` =
3,368 pairs; 15,404 + 2 (`êc` takes sắc and nặng) + 6 = 15,412 toned syllables; 6,208 + `gi êc` =
6,209 Tier B pairs (`th y` was already Tier B).

## Finding 2: the `dz` onset adds 179 Tier B pairs

3.3 says `dz` "follows the same constraints as `d`", and `d` has no constraint beyond 3.10. Every Tier B
pair of `d` (179: its 149 Tier A pairs plus 30 Tier B ones, namely the 15 `k`-coda variants, open `y`,
`uơ` and the 13 extra rhymes) therefore exists for `dz`, all of them Tier B. 6,208 + 179 = 6,387. The test
`tierBPairs` asserts that the `dz` rhymes equal the `d` rhymes.

## Readings of 3.12 where the text allows more than one

Each of these reproduces the spec's reference counts; a wider reading would change Tier B and needs a
spec change (ENG-R302 spirit: rhymes are not added ad hoc).

| Topic | Reading used | Why |
|---|---|---|
| `k` coda after `qu` | none | 3.8 lists the Tier B additions after `qu` exactly: `o` and `ơn`. |
| `k` coda after `gi` | none | 3.9 defines the rhymes after `gi` by its own rule; the `k` variant is defined on the rhymes of 3.7 (and the Tier B extra rhymes) after ordinary onsets. |
| Medial rhymes after `gi` (Tier B) | only those starting with the medial `o` (`oa… oă… oe…`, e.g. `gioăng`) | the 3.9 example is `gioăng`; `u` + vowel after `gi` is already the nucleus `u` (`giũa`, `giuộc`), so `giuân`, `giuy` stay invalid. |
| Medial glide after `kl`, `kr` | forbidden | the cluster starts with `k`, after which 3.4 forbids the glide. |
| `k` front rule for `kl`, `kr`; `g` rules for `gl`, `gr` | not applied | the clusters are followed by any vowel in the names they exist for (`Krông`, `Glei`). |
| Open `y`, `uơ` in Tier B | after any onset that the other rules allow | 3.10 still applies: `c`, `g`, `ng` never precede `y`, and `c k gh ngh` never take a glide. |

## Other notes

- `Glei` (named in 3.3 as an example of the `gl` cluster) has the rhyme `ei`, which no tier contains.
  It is invalid, never viable after `e`, and therefore typed and committed exactly as typed (L0), which
  is the behaviour users want for that name.
- ENG-T03 variants: the implementation generates Titlecase and all caps for every Tier A toned syllable
  (2 x 15,406) and the explicit `uwow` spelling for every toned syllable whose rhyme contains `ươ` (864),
  all Telex O1 in the default (traditional) style. The spec's 30,928 is 2 x 15,404 plus 120, which matches
  `uwow` for the level tone only (120 pairs have a non-stop `ươ` rhyme). Covering every tone is stricter.
- 13.10 has nine rows (E01 to E08 plus E02b); the extractor keeps all nine.

## Consequences

- E2 (composition) runs the 237,824 O1 to O4 cases and the 31,676 variants against the oracle; the
  spec's 100 % target (ENG-T04) applies to that set.
- If the spec author agrees, 3.15 and ENG-T04 can be corrected to 3,367 / 15,406 / 6,208 (6,387 with
  `dz`) and 237,824. Until then the tests document both numbers.
