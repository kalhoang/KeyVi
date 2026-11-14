# 0103. Engine commit decisions, boundaries, history and macros

- Status: accepted, 2026-11-13
- Context: E3 implements spec/01-engine.md section 8 (restore policy at commit), 9.2 (boundaries), 10
  (history, Backspace across boundaries, resets) and 11 (macros) on top of the composition model of
  decision 0102. The commit must name the rule that decided (ENG-R801), behave the same for every boundary
  key (P0-3), stay within the per-event budget of ENG-R1230 including commits and macro lookups, import
  nothing (ENG-R1201) and hold no mutable global state (ENG-R1202).
- Requirements: ENG-R316, ENG-R532, ENG-R704, ENG-R801 to ENG-R803, ENG-R822, ENG-R823, ENG-R830 to
  ENG-R832, ENG-R840 to ENG-R843, ENG-R850, ENG-R860, ENG-R861, ENG-R870, ENG-R901 to ENG-R912, ENG-R1001
  to ENG-R1004, ENG-R1010 to ENG-R1012, ENG-R1101 to ENG-R1107, ENG-T12, REG-01 to REG-30.

## Decision

1. **One pure decision function.** `CommitPolicy.decide` (Commit/CommitRules.swift) evaluates L0, L1, L2,
   L3, L3b, L4, L5 ... L11 in that order with early returns. Its inputs are built once per commit:
   `C` = `Composition.committedText(style:)` (the 5.5 normalisation, ENG-R532), `R` = the raw keys, `R`
   lowercased, and `CommittedTextFacts`, a single pass over the scalars of `C` that yields vowel presence
   (L3), Vietnamese-only letters (ENG-R823), ASCII-ness, the tier of `C` (L5, L6) and `C` lowercased (L4,
   L8). Word lists are hash sets, so a commit costs O(token length).
2. **Rule to `CommitRule` mapping** (also in the doc comment of `CommitPolicy`):

   | Rule | Kept | Restored |
   |---|---|---|
   | L0 | `unchanged` | - |
   | L1 | `userChoice` (user-kept) | `userChoice` (user-restored) |
   | L2 | `userList` (keep-Vietnamese) | `userList` (keep-as-typed) |
   | L3 | `abbreviation` | - |
   | L3b | - | `camelCase` |
   | L4 | `escape` | `escape` |
   | L5 | - | `invalid` |
   | L6 | `extendedSpelling` | `extendedSpelling` |
   | L7 | `notEnglish` | - |
   | L8 | - | `notAttested` |
   | L9 | - | `codeContext` |
   | L10 | - | `englishRun` |
   | L11, row | `ambiguityTable` (`vi`) | `ambiguityTable` (`en`) |
   | L11, no row | `defaultVietnamese` | `techList` |
   | macro (ENG-R1103) | `CommitDecision.macro` | |

3. **Boundaries.** Every boundary key runs the same commit (`Engine.commit(at:isHard:)`): the macro check,
   then the rules, then an edit from the display to the committed text with `thenPassThrough` (ENG-R803),
   or `passThrough` when nothing changes. The key only decides whether the history is cleared afterwards
   (Return, Tab, ENG-R912) and whether it ends a macro span (whitespace).
4. **Language window in O(1).** `RecentLanguages` holds the languages of the last three committed tokens
   (a neutral entry and a missing one behave the same); the run is English when the window holds an `en` entry
   and no `vi` entry, and a token kept by rule L11 is neutral (ENG-R823 as amended on 14/11/2026). Each
   `CommittedToken` stores the window as it was before it (`languagesBefore`), so Backspace re-opening a token
   and a macro folding tokens restore the window without walking the history.
5. **History.** An array with a head offset (amortised O(1) trimming), at most `historyLimit` tokens and
   `historyLimit x 64` entries. Backspace with no active token pops the last boundary character
   (`passThrough`) and, when a committed token becomes the newest entry, re-opens it with its composition,
   flags and the text its commit left on screen (ENG-R1002, ENG-R1003). A token that a commit rule
   restored re-opens with `restoredByRule` set, so it shows its raw keys and the toggle composes it
   (ENG-R704, E04). `startsMidSpan` records that trimming dropped entries inside a macro span.
6. **Macros.** `MacroTable` validates in entry order and keeps a dictionary from a fixed-size `MacroKey`
   (up to 32 lowercased ASCII bytes packed in four words: no allocation to hash) to the entry index
   (ENG-R1105). `MacroSpan` walks back from the active token over the history to the last whitespace,
   bounded by the 32-character cap, and builds the key only when the span can match. An expansion replaces
   the span's display with a grapheme-aware minimal edit, removes the span's entries from the history and
   records one literal token whose raw keys are the span as typed (ENG-R1104).

## Readings where the text allows more than one, and conflicts

| Topic | Reading used | Why |
|---|---|---|
| L3 and escapes (conflict ENG-R801 vs ENG-T12) | L3 does not apply to a token in which an escape was used; L4 decides it | `www` composes `ww` (W138); with L3 first it would commit `ww`, but ENG-T12 requires `www` unchanged (the spec's reference model has the same conflict and keeps `ww`). The only vowel-less tokens with `C != R` are stroke and escape tokens; for escape tokens L4 gives L3's result unless `R` is English (`ddd` -> `dd` either way, `www` -> `www`). Reported as a spec deviation. |
| ENG-R802 decision code | With auto restore off, a rule from L3b to L11 that would restore keeps the token and still names itself (`kept(.invalid)`) | "MUST NOT restore anything" with the order unchanged; the code tells diagnostics which rule matched. |
| "R is English" and "C is an English word" | Lowercased (ASCII only) word in the English lexicon or the tech-always list, for both | 8.1 defines "R is English" that way; L4 uses the same notion for `C`. |
| Ambiguity table and user lists keys | Lowercased raw keys | ENG-R860 keys the user lists by lowercased raw keys; ENG-R822 "exact raw keys" is about key order (`tets` vs `test`), not case. `Is`, `IS` hit the `is` row. |
| A word in both user lists (L2) | Keep-as-typed wins | First in the L2 cell; the host should not allow both. |
| ENG-R861 signal text | The lowercased raw keys | The signal exists so the host can add the word to a user list, which is keyed by lowercased raw keys. |
| ENG-R823 "unchanged ASCII word" | The committed text is ASCII (L0 tokens and escape forms such as `ass` -> `as`), the lowercased word is in the English lexicon (not the tech lists), and it is not a valid syllable of either tier | `as`, `did` from `ass`, `ddid` are English words on screen. The spec names only the lexicon here. |
| Run across Return and Tab | The language window survives Return and Tab and is cleared only by a reset | Spec 0: a run is "the tokens committed since the last reset"; Return and Tab clear the history (ENG-R912), not the run. |
| Language of a macro expansion | Vietnamese if it contains a Vietnamese-only letter, otherwise neutral | It is neither restored nor typed as an English word. |
| Re-opened restored token committed again | The rules run again on its (possibly edited) raw keys, exactly as for a token typed afresh | The decision is a function of the token. Unchanged, it gets the same decision (no edit). Keys typed into it are appended verbatim (it shows its raw keys), so `text` + space, Backspace, `s`, space commits `tét`, as typing `texts` afresh does with the 13.9 fixtures. |
| Re-opened kept token display | The text its commit wrote (`thuở`), not the composing display (`thưở`) | That is what is on screen; the next key or Backspace edits from it. |
| Macro check and the user's toggle | Skipped when the active token is user-restored | ENG-R1104's toggle brings the span back; if the next boundary expanded it again, the toggle would be useless. |
| Expansions are never expanded again | A span that contains a macro token cannot match; a re-opened expansion committed again keeps its text with `CommitDecision.macro` | Otherwise Backspace into an expansion followed by a space would re-expand over the user's edits. By the spec's own span definition such spans are longer than the trigger anyway. |
| Toggle on a re-opened expansion | Shows the span as typed and turns the token into an ordinary user-restored token whose raw keys are the span (plus keys typed into the expansion since) | ENG-R1104; from then on it behaves like any restored token (literal, L1 at commit). The composed form of such a span is usually the span itself, so a second toggle passes through (ENG-R703). |
| Shadowed triggers (ENG-R1103) | `T` is rejected when a shorter trigger `P` is a prefix of `T` and the character of `T` after `P` is ASCII punctuation or a symbol (brackets included) or, since decision 0005 / ADR 0321 (13/11/2026), a trailing main-row digit | `ad` fires at the `.` of `ad.` and also of `ad.x`. Digits are token keys in VNI ("plus trailing punctuation"); in Telex `k` does fire before `k1` can. Note: decision [0005](0005-pa-decisions-2026-11-13.md) (ENG-R1103, 13/11/2026) superseded "digits do not count": a trailing main-row digit now counts like punctuation in the engine and in the host's editor ([0321](0321-trailing-digit-macro-shadowing.md)). |
| Trigger character errors | Order: empty, invalid character (anything outside printable ASCII without space), longer than 32, expansion longer than 4,000 characters, duplicate ignoring case, shadowed | Entry order, first problem thrown; the associated value is the trigger, never the expansion (ENG-R1106). |
| Adaptive case | "All capitals" needs at least two letters in the span, all uppercase; one capital letter capitalises the first letter of the expansion (leading punctuation and spaces skipped, unchanged if a digit comes first) | A capitalised sentence start is likelier than a request for capitals; `1st` must not become `1St`. |
| Expansion normalisation | The engine does not normalise expansions (the standard library has no NFC API); edits that remove an expansion count clusters and UTF-16 units separately | ENG-R1101 says expansions are NFC: the host normalises them when it builds the table (cross-track request). For engine-produced text `deleteCount == deleteUTF16Count` still holds; for an expansion outside the BMP the toggle deletes 1 cluster = 2 UTF-16 units, as ENG-R630 and ENG-R632 intend. |
| Span start after trimming | A span that reaches the start of a trimmed history (not at whitespace) does not match | The characters before it are unknown; a false match would replace text the engine did not see. |
| Empty expansion | Allowed; its history token has no text and is dropped when re-opened | No error case exists for it and deleting a trigger is a plausible use. |
| QA-R4 "editing after newline must be recoverable" (conflict with ENG-R912) | ENG-R912 wins: Return and Tab clear the history, so the word before a newline is not re-opened | 01-engine.md is normative for engine behaviour and gives the reason (chat apps send on Return). `editing.tsv` records it (ED011, ED012, ED022). |

Out of scope as the spec says: retroactive correction of an earlier token once a later one reveals
English (ENG-R824, candidate for v1.1). The engine never edits a committed token except when Backspace
re-opens it or a macro span includes it.

## ENG-R870 and the 13.9 fixtures

ENG-R870 allows only `en` ambiguity rows as exclusions. With the 13.9 fixture list of unattested syllables,
rule L8 restores the generated-corpus raw strings `does`, `door`, `her`, `post`, `says` (and their
Titlecase/all-caps variants), because their displays `dóe`, `dổ`, `hẻ`, `pót`, `sáy` are unattested and the
raw keys are English. That list is "fixture data for this table only" (13.9), so the ENG-R870 test uses the
13.9 word lists with every Tier A syllable attested and passes 100 % with the `en` rows excluded (`is`,
`test`, `best`, `list`, `cost`, `room` and variants, printed by the test). A second test runs the full 13.9
fixtures and asserts that the only other differences are those L8 restores, printed too.

With real data the same tension exists: an English word whose Telex display is a valid but unattested Tier
A syllable is restored by L8, and ENG-R870 cannot exclude it. ENG-R820 lists only words whose display is
attested. The data track should either list those words as ambiguity candidates too or make sure the
attested list covers them (open issue for Pa / the data track).

## ENG-T12 and data

`text user case wifi USB data verbose` are invalid syllables (L5) and `mother keyboard startup facebook
java year` never compose (L0): no data needed, also tested with empty resources. `password traffic boss
coffee less tomorrow www` (L4) and `plans grows ask zoom two wow` (L6) need the English lexicon or the
tech-always list. `does` needs the lexicon and either an unattested `dóe` (L8) or an `en` ambiguity row.

## Measurements (release build, Apple M4, `Scripts/bench-composition.sh`)

293,799 events (every Tier A syllable in Telex O1 and O3 and VNI O1, each committed by a space with the
13.9 word lists and a 10,000-entry macro table, plus English words restored at punctuation, re-opened
words, macro expansions, toggles and English runs): p50 0.17 µs, p99 1.25 µs, p99.9 2.6 µs, maximum 59 µs
(preemption). The 48,036 commits and expansions alone: p50 0.71 µs, p99 1.6 µs, p99.9 10.8 µs. Budget:
p50 5 µs, p99 25 µs, p99.9 100 µs.

## Consequences

- B001-B064 pass with the committed text and the deciding rule, and again for every boundary key of 9.2
  (66 keys in Telex, 56 in VNI) with Return delivered after the edit.
- E01-E08 and E02b pass; E04 undoes an automatic restore and commits the user's choice with a learning
  signal.
- The engine driver checks the whole engine view (history plus active display) against the simulated
  field after every event, and that no edit deletes more than the engine produced (ENG-T31).
- The data track (`VietnameseEngineData`) only has to supply `Resources`; nothing in the core changes when
  real word lists arrive.
