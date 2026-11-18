# Typo and spelling correction: design

Date: 18/11/2026. Product owner: Pa. Status: specification written, no code yet.
Scope: {{AppName}} 1.1.0, PRD-R4A of `spec/03-product.md`. The normative text is `spec/01-engine.md` section 11A
(ENG-R1110 to ENG-R1124, ENG-T50 to ENG-T56, worked examples 13.12) and `spec/03-product.md` D30, PRD-R80 and
PRD-R81. This note records the approach, the measurements behind it, the alternatives that were considered and the
decisions taken while writing the specification, so that the implementation track and the product owner can see why
the rules are what they are.

## 1. Intent

The product owner's direction (16/11/2026, PRD-R4A): at the commit of a word, replace a clearly mistyped word with
the one word it was meant to be, offline, from bundled data, with no suggestion list; Vietnamese first; only one-key
mistakes; only when exactly one word fits; never in code, links, addresses, paths or capitals; the restore key gives
the typed word back and teaches a list. The product owner decided on 18/11/2026 that the feature is on by default;
the release track records that decision in `docs/decisions/0009-pa-decisions-2026-11-18.md`.

The two examples that must work: `androdi` gives `android` (two letters swapped) and `gramar` gives `grammar`
(a missing letter). The second is the harder one: today `gramar` composes as `grẩm`, a Tier B syllable through the
place-name cluster `gr`, and rule L6 keeps it because `gramar` is not English.

## 2. Where it sits

The correction is one more step at the commit, after the macro check and after the decision of 8.1 has named its
rule, and before the edit is formed. It reads the token alone and the resources; it never waits for the next word, so
it does not share the host machinery of the revisions (PLT-R357): a correction is an edit of the same shape as a
restore (ENG-R803), and the undo with the restore key is an edit of the same shape as the undo of a revision
(ENG-R829, PLT-R353). Nothing in the 8.1 table changes.

## 3. The rules in one page

A token is a candidate when the 8.1 decision would leave the typed word on screen (L0, or a restore other than the
user's own choices), or when L6 keeps it only through a place-name cluster in lowercase (the `gramar` case); when the
typed word is not a word of any list (English lexicon, tech-always, code-only, guard list, the user's keep lists, the
never-correct list); when it is not Vietnamese (neither Tier A nor Tier B, and not the unmarked shape of a syllable);
when it is 5 to 24 ASCII letters, lowercase anywhere or sentence case at a sentence start; and when the context allows
it (not `code`, committed by whitespace or a closer of prose, nothing glued before the word).

The edit model is the one of PRD-R4A, one transposition, one deletion, one insertion or one neighbouring-key
substitution on the letters as typed, with four position rules that the measurements of section 4 motivated:

1. the first letter is deleted only when it is doubled (`aabout`, never `kbang` to `bang`);
2. the last letter is deleted only when it is doubled (`helpp`, never `messi` to `mess`);
3. a letter is inserted after the last one only when it repeats it (never `pajama` to `pajamas`);
4. a last `r` after `e` is never replaced by `d` (never `leecher` to `leeched`).

The correction is made only when exactly one word of the correction lexicon (the English lexicon plus the letter-only
tech-always entries, at least four letters) is reached. There is no tie-break.

## 4. Measurements (18/11/2026)

The rules were modelled in a small script over the bundled `english.txt` (40,205 words), the two tech lists, the
QWERTY neighbours table of ENG-R1113 and an approximation of the unmarked Vietnamese shapes taken from the prose
corpus. The figures are the baseline for the targets of ENG-R1124 and are to be re-measured by ENG-T52 and ENG-T53
once the engine implements the rules.

Injected typos (6,000 lexicon words of five or more letters per kind, one edit each, seed 18112026):

| Kind of typo | Corrected to the source | Corrected to another word | Left alone |
|---|---|---|---|
| Transposition | 87.0 % | 0 % | 13.0 % |
| Omitted letter | 59.6 % | 1.37 % | 39.1 % |
| Added letter | 76.9 % | 1.20 % | 21.9 % |
| Doubled letter | 96.0 % | 0 % | 4.0 % |
| Neighbouring key | 88.9 % | 0 % | 11.1 % |

Rare words (the 209,662 words of `/usr/share/dict/words` with five or more ASCII letters that are not in the
lexicon or the tech lists, a stand-in for names, archaic spellings and derived forms that users type correctly):
4.16 % would be corrected with the plain edit model and the first three position rules, 3.42 % with the fourth rule
(2,624 of the 8,727 exposures were substitutions of the last letter, 1,998 of them `er` to `ed`). The guard list of
ENG-R1120 (SCOWL sizes 40 to 70 and the SCOWL proper names) is expected to absorb most of the remainder; the gate of
ENG-T53 is 3.5 % without counting on it.

Unmarked Vietnamese: without the shape rule, 20 distinct tokens of the prose corpus typed without marks would be
corrected in 6,581 places (`truong` to `strong`, `thuong`, `phong`, `duong`, `huong`). With it, zero. This is why
"not Vietnamese" is checked both on the display (Tier A or B) and on the typed letters (the unmarked shapes).

## 5. Alternatives considered

- **A stricter model: insertions and deletions of doubled letters only.** It looked safer (fewer corrections of
  names and rare words, 2.95 % exposure instead of 4.16 %). Measured, it is worse: on omitted letters it corrects
  4.5 % and gets 9.1 % wrong, because when the true edit is outside the model the one-word rule picks up some other
  single neighbour. The four position rules give most of the safety at a fraction of the cost. Rejected.
- **A frequency or size-level tie-break.** SCOWL levels are not frequencies, the lexicon ships membership only
  (8.2), and PRD-R4A says exactly one word fits. A tie-break would make the result a guess. Rejected; the
  ambiguous rows of 13.12 (`thier`, `wierd`, `pleasee`) stay as typed.
- **Correcting from a larger lexicon.** More targets mean more one-edit neighbours and fewer unique fits; the gain
  in recall is small and the wrong corrections grow. The larger lists are used the other way round, as the guard list
  that protects rare words from being "corrected".
- **No guard list.** Possible, and the targets are set so that the gates pass without it; but names and derived
  forms are the main source of wrong corrections and a membership structure of a few hundred kilobytes removes most
  of them. Kept, with a size cap (512 KB) and tolerance for false positives, which only suppress corrections.
- **Correcting words in sentence case anywhere.** Inside a sentence a capital is a name (`Kbang`, `Biden`,
  `Glong`); correcting it would hit people and places first. Sentence case is corrected only at a sentence start,
  where it is ordinary capitalisation. Whether even that should wait is open question Q10.
- **Applying the cluster case to capitalised words.** `Gramar` at a sentence start would then give `Grammar`, but
  `Glong` would give `Gong` and `Prông`, `Krông` and the other place names typed with a capital would be exposed. The
  cluster case applies to lowercase words only; `Gramar` keeps its 1.0 behaviour.
- **Mid-word correction or a suggestion list.** Excluded by PRD-R4A and by ENG-R830 (decisions only at commit).
- **A host-side feature instead of an engine rule.** The host does not know the token boundaries, the raw keys or the
  8.1 decision, and a second edit after the commit would double the injection risk. The correction is the engine's.
- **Per-app learning of the never-correct list.** The keep lists learn per app (ENG-R862) because a word can be
  English in one app and Vietnamese in another. A word the user took back from a correction is a word everywhere, so
  the list is per user like the collision memory, and one signal is enough.

## 6. Decisions taken in this note

1. The correction lexicon is the English lexicon of 8.2 plus the letter-only tech-always entries; the code-only list
   is never a target but protects its words (`chown`, `mkdir` are never corrected).
2. The guard list is SCOWL "words" 40 to 70 plus SCOWL "proper-names" 10 to 70 from the already pinned archive,
   under the notice the app already shows; it may be a filter with false positives; at most 512 KB.
3. The keyboard layout is a stated assumption, QWERTY, as a bundled symmetric table; the engine never sees key
   codes. Other layouts lose some substitutions and nothing else.
4. The casing rule: lowercase anywhere, sentence case at a sentence start only, nothing else.
5. The closers of prose are the only keys that let a correction through; digits, apostrophes and every code or path
   character leave the word alone, as does anything glued before it. Known cost: `googel.com` is corrected at the
   `.`, before the engine can see the domain.
6. A corrected token is `en` for the window, never a collision word, never revised, never corrected together with a
   revision; the correction is decided at every committing key, Return included (open question Q11).
7. The undo is the restore key right after the commit (or right after Backspace re-opened the word), with one
   `neverCorrect` signal; the host adds the word to the list at once. A re-opened corrected word is literal and is
   never corrected again.
8. `typoCorrection` is a configuration flag, default true, passed as D30 AND D4 AND the rule's `englishRestore`; no
   new rule flag; off, the engine equals 1.0 event by event, which the fuzz run checks.
9. Vietnamese typo patterns are a later phase under a written rule (ENG-R1123): unambiguous patterns only, zero
   corrections on every Vietnamese corpus, reviewed by the product owner.
10. The performance budget is per candidate (50 µs p99, 200 µs worst case) with the ENG-T40 percentiles unchanged,
    which rules out a naive scan and leaves hash lookups or a trie walk to the implementation.

## 7. Risks and known costs

- A lowercase name or rare word one edit from a common word is corrected once (`glong` to `gong`, `biden` to
  `bidden`) until the user presses the restore key, which adds it to the list for good. The guard list and the
  position rules keep this to the measured 3.4 % of rare words; the rest is the price of correcting without asking.
- Cognitive misspellings are mostly out of reach by design (`grammer`, `seperate`, `definately`: the letters are not
  neighbours), and a third of omitted letters stay uncorrected because another word also fits.
- A correction at Return in a chat app cannot be undone with the key (the history is cleared). Q11.
- The gates depend on data that does not exist yet (the guard list, the shapes); ENG-T56 checks the data and
  ENG-T51 to ENG-T53 re-measure the targets when the engine runs.

## 8. Host work (summary for the platform track)

Pass `typoCorrection` (D30 AND D4 AND `features.englishRestore`); store, show, export and import the never-correct
list with the keep lists (`englishRestoreLists.neverCorrect`), validate entries (lowercase letters only), add the word
of a `neverCorrect` signal at once; inject the undo like a restore on the restore key; D30 row and the list in the
Typing pane with the copy of PRD-R80 and PRD-R81; a count of corrections and undos in diagnostics, never the words.
No new compat rule flag, no new edit job kind.

## Open for the product owner

1. **Capitalised words at a sentence start** (ENG-R1111, Q10). Correct them (`Androdi` to `Android`), accepting
   that a name that starts a sentence and is one edit from a common word is corrected once until the key teaches the
   list; or never correct a capitalised word in 1.1.0. Recommendation: correct them; the first word of a sentence is
   a word as often as any other, and the proper-names part of the guard list covers most names.
2. **Correction at Return and Tab** (ENG-R1116, Q11). Decide at every committing key, as restore and D29 do, so a
   chat message leaves corrected and the key cannot undo it; or only at a space or punctuation, so the user sees the
   word before sending. Recommendation: every key, the rule of P0-3; a wrong word is fixed in the next message as any
   typo is today.
