# 0101. Engine letter model and orthography structures

- Status: accepted, 2026-11-13
- Context: the per-event budget is p50 5 µs, p99 25 µs, p99.9 100 µs in release builds (ENG-R1230), and
  composition recomputes the display from the raw keys on every event (ENG-R601), so parse, viability,
  tone placement and validity run several times per key. The core imports nothing (ENG-R1201) and has no
  mutable global state (ENG-R1202).
- Requirements: ENG-R301, ENG-R340, ENG-R345, ENG-R346, ENG-R501, ENG-R1201, ENG-R1202, ENG-R1230,
  ENG-R1232, ENG-T01.

## Decision

1. **Letters are dense `UInt8` codes.** `Letter` identifies one of 33 lowercase letters: the 26 ASCII
   letters plus `ă â đ ê ô ơ ư`, in Vietnamese alphabetical order with `f j w z` at their ASCII places.
   Case and tone are not part of a letter; composition keeps them beside it. Properties (base letter,
   modifier, vowel) are table lookups.
2. **Emitted characters come from one generated table.** `Scripts/generate-letter-table.py` (python3 -I,
   `unicodedata`) derives the 146 letters of ENG-R301 by canonical composition and character names and
   writes `Sources/VietnameseEngine/Generated/LetterTable.swift`, ordered by code point. Encoding
   (letter, tone, case) to a scalar is one array index; decoding uses a dictionary built from the same
   table. A test re-derives the table through Foundation (`precomposedStringWithCanonicalMapping`) and
   compares it entry by entry; `--check` lets CI detect a stale file.
3. **Orthography data is the spec's lists, rules are one predicate.** `RhymeInventory` transcribes 3.7,
   3.8, 3.9 and 3.12 in the spec's order; `SyllableRules.allows(onset, rhyme, extended:)` encodes 3.3 to
   3.12. Everything else is generated at first use (immutable `static let`): the 189 rhyme spellings, a
   flat onset x rhyme tier table, the pair lists, and the viability automaton.
4. **Rhyme lookup by packed key.** A rhyme has at most four letters, so its letters pack into one
   `UInt32` and the rhyme of the current letters is one hash lookup (ENG-R1232).
5. **Viability is a minimised automaton (ENG-R346).** Every Tier B pair, tone ignored and normalised for
   display (5.5), goes into a trie; a subset construction over the 33 letters makes the ENG-R345 wildcard
   deterministic (an unmodified vowel follows every modified variant, `d` also follows `đ`); identical
   states are then merged. The result has 66 states (4.3 KB of `UInt16`), and a query is one table step
   per letter with no allocation. Tests compare it with an independent reference set on every string of
   up to three letters and on every single-letter mutation of every Tier B spelling (840,939 queries).
6. **Pure functions over letters.** `SyllableParser.parse` (3.13), `HornNormalisation` (5.5),
   `TonePlacement.toneOffset` (5.1, 5.2) and `SyllableTables.validity` take letters (generic over
   random-access collections, so composition can pass arrays or slices) and return offsets and enums,
   never strings. Strings are built only for output and for `Orthography.analyze`.
7. **`package` access for cross-target use.** The internal types are `package`, not `public`, so
   `VietnameseEngineTesting` and the tests can use the tables without widening the public API of 12.2.
8. **The oracle is a separate implementation.** `SyllableOracle` (ENG-T01) works on `Character`s and
   implements section 5 itself; it reads only the pair list (which onsets and rhymes exist) and the raw
   generated letter table. A test checks that oracle and engine placement agree on all 15,406 Tier A
   toned syllables in both styles.

## Measurements (release build, Apple M4, in-module calls, 319,350 calls each)

| Operation on one syllable's letters | Mean |
|---|---|
| Parse (3.13) | 21 ns |
| Viability (automaton walk) | 2.5 ns |
| Tone placement | 7 ns |
| Validity (parse + packed-key lookup + tier) | 39 ns |
| Parse + normalise + viability + placement + validity | 46 ns |

Calls from another module go through unspecialised generics and are about ten times slower; that only
affects test helpers. E4 owns the real per-event benchmark (ENG-T40).

## Consequences

- E2 can afford to try a transform, rebuild the candidate letters and check viability on every key.
- Changing a rhyme list or rule regenerates every structure; the count tests (ENG-R350) and the
  automaton reference test catch unintended changes.
