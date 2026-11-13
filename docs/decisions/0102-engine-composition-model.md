# 0102. Engine composition model and readings of sections 4 to 7

- Status: accepted, 2026-11-13
- Context: E2 implements spec/01-engine.md sections 4, 5 (on every key), 6, 7.1 to 7.4 and 9.1 in
  `Engine.reduce`. The display must be a pure function of (raw keys, configuration) (ENG-R601), the
  per-event budget is p50 5 µs, p99 25 µs, p99.9 100 µs in release builds (ENG-R1230), the core imports
  nothing (ENG-R1201) and has no mutable global state (ENG-R1202). E3 adds commit rules, boundaries,
  history and macros on top, so the state must carry what they need.
- Requirements: ENG-R401 to ENG-R450, ENG-R501 to ENG-R534, ENG-R601 to ENG-R641, ENG-R701 to ENG-R712,
  ENG-R901 to ENG-R905, ENG-T31 to ENG-T37.

## Decision

1. **Composition is a fold over the raw keys.** `Composition` holds the raw keys exactly as typed
   (ENG-R602) and the state derived from them: letters, tone, the keys that set the tone, escaped kinds,
   escape-used, the literal-mode start and the camel-case tracker. `append(key)` is one step of the 4.3
   order of interpretation; `init(replaying:)` folds the steps over a key sequence. Appending a key to a
   token applies one more step of the same fold; Backspace removes keys from the raw sequence and
   replays (ENG-R710). The single shortcut, dropping the last key of a literal tail after the key that
   started literal mode, leaves exactly the state replay would rebuild. `CompositionPropertyTests`
   compares the cached state with a full replay after every event of 576,000 random events over four
   configurations (ENG-R601, ENG-T33).
2. **Compact value types.** Token keys are always ASCII (letters, VNI main-row digits, enabled bracket
   keys; everything else is a boundary by 9.2), so raw keys are `[UInt8]`. A `ComposedLetter` is the E1
   `Letter` code, the case of its key, flags (escape letter, standalone `w`, bracket), the index of the
   key that produced it and a `KeySet` of the modifier keys that targeted it. `KeySet` is a 64-bit mask:
   it is valid because ENG-R641 sends a composing token to literal mode at its 65th key, so every key that
   can create, modify or tone a letter has an index below 64. Raw keys, letters and history stay growable
   (ENG-R640); the mask is a bounded record, not a buffer of user data.
3. **Rendering on every key.** Tone placement (5.1, 5.2) and horn completion (5.5) are computed at render
   time from the current letters through generic views (`LetterView`, `DisplayLetterView`) over E1's
   parser, placement and automaton, so no position is stored (ENG-R501) and no normalised copy is built.
   Transforms are applied in place, checked with the viability automaton and reverted when the result
   is not viable (ENG-R416), so a key allocates nothing but the display string.
4. **The token caches its display.** `ActiveToken` keeps the display `String`. Literal and restored
   tokens grow by appending, `composingText` shares the storage, and `Session.handle` reduces the state
   in place (`Engine.process`) so buffers stay uniquely referenced. A 100,000-key token types, restores
   and deletes in linear time.
5. **Edits.** `DisplayEdit` computes the longest common prefix scalar by scalar; for engine text one
   scalar is one grapheme cluster is one UTF-16 unit (ENG-R631). `deleteUTF16Count` is still computed from
   the deleted scalars and every test asserts it equals `deleteCount`.
6. **E3 plug points.** `EngineState` holds the active token, a `History` of committed tokens and boundary
   characters, and the "previous event was a restore toggle" flag. A committed token keeps its
   composition (raw keys, escape-used, camel case) and flags (`userChoice`, `restoredByRule`). Boundaries
   currently commit the token unchanged (`Engine.commitResult`, marked `E3 PLUG-IN`); Backspace with no
   active token passes through (marked `E3 PLUG-IN`). `Composition.committedText(style:)` implements the
   ENG-R532 form for E3 to call.

## Readings where the text allows more than one

| Topic | Reading used | Why |
|---|---|---|
| ENG-R413 "a set whose letters already carry exactly that modifier is skipped", and the escape test "the vowel group already has a horn or breve" | Judged on the stored letters, not on the display letters after horn completion | ENG-T03's explicit `uwow` spelling (W017, W018, W122) must compose: in `tuwo` the display already shows `ươ`, yet the second `w` must complete the pair instead of escaping. With stored letters it applies (and is swallowed, nothing visible changes); the third `w` escapes (W130, ENG-R534). |
| ENG-R414 escape for VNI `7` and `8` | `7` escapes only when a horn is present and removes horns; `8` only for a breve and removes breves | "ENG-R413 restricted to `o` and `u`" (and to `a`); ENG-R440 defines escape as the key's own effect being present. VNI `a87` gives `ă7`, not `a7`. |
| ENG-R441 kind of tone removal | Telex `z` and VNI `0` belong to the tone kind | After a tone escape no tone can return, so removal would never apply anyway; one kind keeps 4.3 step 2 uniform. |
| Bracket doubling (4.8 `[[` -> `[`) | Brackets form their own sticky kind. A bracket key appends its letter if viable; otherwise, if the token holds a letter made by the same bracket key, those letters are removed and the key is appended as a literal character; otherwise the key is a literal | The kinds list of ENG-R441 predates the bracket option; the reference model does not implement the doubling at all. `[]` gives `ơ]` because the effect of `]` is not present. Bracket letters are lowercase and take no part in the camel-case pattern (the key has no case). |
| Standalone `ư` removed by a `w` escape (ENG-R413) | Letters created by a standalone `w` that are still `ư` are removed; horns and breves in the vowel group are stripped from the rest | An `ư` that a later circumflex turned into `u` (`wo` + `o` -> `uô`) is no longer "an ư". |
| ENG-R412 escape order | Targets are visited right to left; the first target that already has a circumflex escapes, even if a target to its right was rejected for viability | Literal reading of "If the target already has a circumflex, the key escapes … otherwise the next target is tried". |
| ENG-R710 "every tone key" | All keys that set or removed the tone, tone-removal keys included | Keeping a stale `z` after its tone key is removed would turn it into a letter and change the word. |
| ENG-R904 camel case | Only keys whose case shows in the output count: keys appended as letters (including escape letters and the standalone `ư`) and ASCII letters appended in literal mode. Transform keys do not count (ENG-R902). In composing mode a lowercase letter that completes the pattern enters literal mode instead of being appended | W205 `dDaf` -> `đà` must compose, while `useState` is camel case; `tHas` shows `tHas`, not `tHá`. The tracker also feeds rule L3b. |
| ENG-R532 for literal tokens | Not applied: a literal token keeps its display | The literal tail follows the frozen letters, so the vowel group is never open. |
| Restore toggle composed form (ENG-R701) | The display form (`thưở`), not the commit form | The toggle acts on the active token, whose display shows the open pair as `ươ` (ENG-R531). |
| Return | `"\n"`, `"\r"` and `"\r\n"` are hard boundaries | 9.2 names Return `"\n"`; hosts can deliver a carriage return for the same key. |
| History bound | At most `historyLimit` tokens and `historyLimit x 64` entries; the oldest entries go first | ENG-R1001 limits tokens; boundary runs (thousands of spaces) must not grow memory (ENG-T30). E3 may refine this with section 10. |

## Measurements (release build, Apple M4 under the load of other builds, `Scripts/bench-composition.sh`)

285,921 events (every Tier A syllable in Telex O1 and O3 and VNI O1, each followed by a space, plus
literal words, Backspace and toggles), measured one by one: p50 0.17 µs, p99 0.46 to 0.75 µs, p99.9 2 to
36 µs depending on machine load, maximum dominated by preemption. The slow events are different in every
run, so they are scheduling noise, not engine work. The budget is p50 5 µs, p99 25 µs, p99.9 100 µs.

## Consequences

- All 253 worked examples, the 6.2 traces, the 13.10 rows that need only the active token, and every
  O1 to O4 case and ENG-T03 variant of the generated corpus (237,824 + 31,676, including the simulated
  field) pass.
- E3 replaces `Engine.commitResult` and the no-token Backspace branch, sets `restoredByRule` when it
  re-opens a token a rule restored, and reads `escapeUsed`, `isCamelCase` and `committedText(style:)`.
