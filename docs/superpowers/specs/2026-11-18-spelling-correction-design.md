# Typo and spelling correction: design

Date: 18/11/2026, revised the same day after review. Product owner: Pa. Status: specification written, no code yet.
Scope: {{AppName}} 1.1.0, PRD-R4A of `spec/03-product.md`. The normative text is `spec/01-engine.md` section 11A
(ENG-R1110 to ENG-R1125, ENG-T50 to ENG-T57, worked examples 13.12) and `spec/03-product.md` D30, PRD-R80 and
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
never-correct list, the collision list); when it is not Vietnamese (neither Tier A nor Tier B, and not the unmarked
shape of a syllable) and no single edit of it reaches Vietnamese (ENG-R1125, below); when it is 5 to 24 ASCII
letters, lowercase anywhere or sentence case at a sentence start; and when the context allows it (not `code`,
committed by whitespace or an ASCII closer of prose, nothing glued before the word, at a line start too, so
`#androdi` starting a post stays a tag). The cluster case needs a display that L6 keeps: a cluster token shown
exactly as typed (`glong`) is decided by L0 first and stays, being Tier B.

The edit model is the one of PRD-R4A, one transposition, one deletion, one insertion or one neighbouring-key
substitution on the letters as typed, with four position rules that the measurements of section 4 motivated:

1. the first letter is deleted only when it is doubled (`aabout`, never `kbang` to `bang`);
2. the last letter is deleted only when it is doubled (`helpp`, never `messi` to `mess`);
3. a letter is inserted after the last one only when it repeats it (never `pajama` to `pajamas`);
4. a last `r` after `e` is never replaced by `d` (never `leecher` to `leeched`).

The correction is made only when exactly one word of the correction lexicon (the English lexicon plus the letter-only
tech-always entries, at least four letters) is reached. There is no tie-break.

Vietnamese counts as a fit (ENG-R1125): when any one edit of the typed word, with no position rules, gives a
Vietnamese keying (the Telex keys of a Tier A syllable in the usual order: onset, vowels with their mark keys, coda,
the tone key last or before the coda) or an unmarked shape, the word may be a Vietnamese typo and is left alone. So
`ddi pahir` stays `đi pahir` (one swap from `phair`, `phải`) instead of becoming `đi pair`, and `pehis` (one key from
`phis`, `phí`) does not become `penis`.

The correction is made only where the restore key can undo it: the host passes D30 AND D4 AND the rule's
`englishRestore` AND the restore key (D8 and the rule's `restoreHotkey`), so Spotlight and the overlay panels, where
Escape closes the panel, get no correction (the reason PLT-R357 gives for the revisions).

## 4. Measurements (18/11/2026)

The rules were modelled in a small script over the bundled `english.txt` (40,205 words), the two tech lists, the
QWERTY neighbours table of ENG-R1113, and, for the review revision, the unmarked shapes and the Vietnamese keyings
generated from the tier tables of `spec/reference-model`. The figures are the baseline for the targets of ENG-R1124 and are to be re-measured by ENG-T52 and ENG-T53
once the engine implements the rules.

Injected typos (6,000 lexicon words of five or more letters per kind, one edit each, seed 18112026), with the rule of
ENG-R1125 and, in brackets, without it (the first draft's sample, without it, gave 87.0, 59.6, 76.9, 96.0 and 88.9
%):

| Kind of typo | Corrected to the source | Corrected to another word |
|---|---|---|
| Transposition | 85.7 % (86.8) | 0 % (0) |
| Omitted letter | 57.5 % (59.0) | 1.32 % (1.48) |
| Added letter | 75.8 % (76.0) | 1.20 % (1.23) |
| Doubled letter | 95.2 % (95.6) | 0 % (0) |
| Neighbouring key | 86.7 % (88.2) | 0.05 % (0.05) |

Vietnamese typos (the review's experiment, 18/11/2026): every distinct word of the prose corpus typed in Telex with
the tone key last, with one random one-key error, run through the 1.0 engine and then the candidate rules: 133 of
3,371 typo variants with five or more keys had exactly one English fit without ENG-R1125 (`pahir` to `pair`, `hoand`
to `hand`, `pehis` to `penis`); with it, 10, nine of them typos of English words of the corpus (`internte` to
`internet`) and one of the Tier B loanword `blốc` (`bloofs` to `bloods`). The same words typed as plain letters with
one error: 53 of 579 without the rule, none with it.

Rare words (the 209,662 words of `/usr/share/dict/words` with five or more ASCII letters that are not in the
lexicon or the tech lists, a stand-in for names, archaic spellings and derived forms that users type correctly):
4.16 % would be corrected with the plain edit model and the first three position rules, 3.42 % with the fourth rule
(2,624 of the 8,727 exposures were substitutions of the last letter, 1,998 of them `er` to `ed`). The guard list of
ENG-R1120 (SCOWL sizes 40 to 70 and the SCOWL proper names) is expected to absorb most of the remainder; the gate of
ENG-T53 is 3.5 % without counting on it.

Unmarked Vietnamese: without the shape rule, 20 distinct tokens of the prose corpus typed without marks would be
corrected in 6,581 places (`truong` to `truing`, `thuong` to `thong`, `phong` to `phony`, `duong`, `huong`). With it,
zero. This is why
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
- **Vietnamese keyings in every order Telex accepts.** The first version of ENG-R1125 composed each edit with the
  engine and asked whether the display was a Tier A syllable. Telex accepts free orders, so `gamar` composes `gẩm`
  and `tomorw` composes `tởm`: the product owner's own `gramar` and the ordinary `tomorow` would no longer be
  corrected. Typists type a syllable in the usual order and make their mistakes on that order, so the keyings follow
  it. Rejected.
- **No correction after a Vietnamese word.** The review suggested it as a guard. It would also stop `ddi androdi` and
  every English typo in Vietnamese prose, where most English words of a Vietnamese user appear, and it would do
  nothing for a Vietnamese typo at the start of a message. The edit-distance rule removes the same errors without
  reading the context. Rejected.
- **Correcting a cluster token shown as typed.** `glong` would give `gong` (one deletion). Rule L0 comes first, and
  the token is Tier B and an unmarked shape; correcting it would expose every lowercase place name with a cluster
  onset. Rejected: the cluster case is only for a display that L6 keeps (`grẩm`).
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
5. The ASCII closers of prose are the only keys that let a correction through (the undo of ENG-R829 needs an ASCII
   boundary, so `”` and `…` are left out); digits, apostrophes and every code or path character leave the word alone,
   as does anything glued before it, at a line start too. Known cost: `googel.com` is corrected at the
   `.`, before the engine can see the domain.
6. A corrected token is `en` for the window, never a collision word, never revised, never corrected together with a
   revision; the correction is decided at every committing key, Return included (open question Q11).
7. The undo is the restore key right after the commit (or right after Backspace re-opened the word), with one
   `neverCorrect` signal; the host adds the word to the list at once. A re-opened corrected word is literal and is
   never corrected again.
8. `typoCorrection` is a configuration flag, default true, passed as D30 AND D4 AND the rule's `englishRestore` AND
   the restore key (D8 and the rule's `restoreHotkey`); no new rule flag; off, no output carries a correction or a
   `neverCorrect` signal and the 1.0 corpora pass unchanged, which the fuzz run and the corpora check.
9. Vietnamese typo patterns are a later phase under a written rule (ENG-R1123): unambiguous patterns only, zero
   corrections on every Vietnamese corpus, reviewed by the product owner.
10. The performance budget is per candidate (50 µs p99, 200 µs worst case) with the ENG-T40 percentiles unchanged,
    which rules out a naive scan and leaves hash lookups or a trie walk to the implementation.
11. A typed word one edit from Vietnamese (a usual-order Telex keying of a Tier A syllable, or an unmarked shape) is
    never corrected (ENG-R1125), with its own corpus target: at most 0.1 % of one-key typos of Vietnamese words
    corrected (ENG-T57).

## 7. Risks and known costs

- A lowercase name or rare word one edit from a common word is corrected once (`biden` to `bidden`) until the user
  presses the restore key, which adds it to the list for good. The guard list and the
  position rules keep this to the measured 3.4 % of rare words; the rest is the price of correcting without asking.
- Some English typos are left alone because they look Vietnamese: `gruop` is the unmarked shape of a Tier B syllable,
  and ENG-R1125 costs 0.2 to 1.5 points of recall per kind of typo. That is the price of "Vietnamese first".
- Cognitive misspellings are mostly out of reach by design (`grammer`, `seperate`, `definately`: the letters are not
  neighbours), and a third of omitted letters stay uncorrected because another word also fits.
- A correction at Return in a chat app cannot be undone with the key (the history is cleared). Q11.
- The gates depend on data that does not exist yet (the guard list, the shapes, the keyings); ENG-T56 checks the data and
  ENG-T51 to ENG-T53 re-measure the targets when the engine runs.

## 8. Host work (summary for the platform track)

Pass `typoCorrection` (D30 AND D4 AND `features.englishRestore` AND the restore key, D8 and
`features.restoreHotkey`); store, show, export and import the never-correct
list with the keep lists (`englishRestoreLists.neverCorrect`), validate entries (lowercase letters only), add the word
of a `neverCorrect` signal at once; inject the undo like a restore on the restore key; D30 row and the list in the
Typing pane with the copy of PRD-R80 and PRD-R81; a count of corrections and undos in diagnostics, never the words.
No new compat rule flag, no new edit job kind.

## Open for the product owner

1. **Capitalised words at a sentence start** (ENG-R1111, Q10). Correct them (`Androdi` to `Android`), accepting
   that a name that starts a sentence and is one edit from a common word is corrected once until the key teaches the
   list; or never correct a capitalised word in 1.1.0. Recommendation: correct them; the first word of a sentence is
   a word as often as any other, and the proper-names part of the guard list covers most names. The D30 copy follows the
answer ("từ viết hoa toàn bộ" / "words in all capitals" if they are corrected, "từ viết hoa" / "capitalised words" if
not).
2. **Correction at Return and Tab** (ENG-R1116, Q11). Decide at every committing key, as restore and D29 do, so a
   chat message leaves corrected and the key cannot undo it; or only at a space or punctuation, so the user sees the
   word before sending. Recommendation: every key, the rule of P0-3; a wrong word is fixed in the next message as any
   typo is today.
