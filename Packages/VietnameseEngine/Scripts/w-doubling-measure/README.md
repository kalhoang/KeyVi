<!-- SPDX-License-Identifier: MPL-2.0 -->
# w doubling measurement (rule L4, ENG-R804, REG-40, REG-41)

A differential harness: it types the same key sequences through the engine of two commits and compares what each one
shows and commits. It produced the figures of the amendment of 22/11/2026 to `spec/01-engine.md` ENG-R804 (rule L4,
the `w` doubling, case (d) and its known costs), of REG-41 and of item 8 of
`docs/decisions/0010-pa-decisions-2026-11-19.md`: base `0fdb9d98` (REG-40, the engine of 20/11/2026) against head
`d0941160` (REG-41). Provenance note N6 of `docs/provenance/reports/2026-11-18-1.0.1.md` found a measured figure whose
script was not in the repository; this directory keeps the script behind these figures.

No target of the repository compiles `WDoublingMeasureTests.swift` where it lies: `Package.swift` builds only
`Sources/`, `Tests/` and `Benchmarks/EngineBenchmark`, so `swift build` and `swift test` of the package never see it.
`prepare-tree.sh` copies it into a scratch export of the package.

## What it measures

Every input line is typed from an empty field with the bundled data (8.2) and Telex with its default options, once with
`typoCorrection` off (`c0`) and once on (`c1`). The harness writes one line per input: a flag, a tab and the final field.
The flag is 1 when the active token of some state of the line held, as its first literal key, the escaping `w` of a
standalone `w` doubling typed in lowercase right after a capital `W` (ENG-R903 as amended on 22/11/2026), the only case
REG-41 changes; both commits compute it the same way. For the random sequences the line
also holds the field after every event, so a difference that a later key hides still counts. `compare.py` reads the
outputs of both commits and prints the figures below.

| Set | Lines | Keys of each line, then a space |
|---|---|---|
| `a_dict` | 235,976 | every word of `/usr/share/dict/words` as written |
| `b_habit` | 3,947 | its words that start with `w` or `W`, typed with the habit of REG-40: `w` -> `ww`, `W` -> `Ww` |
| `b_written` | 3,947 | the same words as written |
| `c_capital` | 337 | the words of `b_written` that start with `W` |
| `d_ww_written` | 57 | its words that contain `ww`, as written |
| `d_ww_doubled` | 57 | the same words with every `w` doubled (`w` -> `ww`, `W` -> `WW`) |
| `d_lexicon_written` | 1,705 | the words of the bundled lexicon (`english.txt`) that contain a `w` but do not start with one |
| `d_lexicon_doubled` | 1,705 | the same words with every `w` doubled |
| `e_capital_inner` | 1,705 | the same words with a capital first letter and every `w` typed as `Ww` (`SWwab`, `AcknoWwledge`) |
| `f_fuzz` | 100,000 | random sequences of 2 to 14 keys: `w`, `W`, vowels, tone keys, a few consonants, Backspace (`⌫`), space and the restore key (`⎋`), seed 22112026 (no trailing space) |

The word list is the one of macOS, 235,976 words, SHA-256
`be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9`; another list gives other counts. The bundled lexicon
is the same file at both commits.

| File | Role |
|---|---|
| `generate-inputs.py` | writes the input sets into a directory (`--dictionary`, `--lexicon`, `--seed`, `--fuzz`) |
| `prepare-tree.sh` | exports `Packages/VietnameseEngine` of a commit with `git archive` into a scratch directory, copies the harness into its test target `VietnameseEngineDataTests` and builds the package with its tests under `nice`, in a private scratch path inside that copy |
| `WDoublingMeasureTests.swift` | the harness, a Swift Testing test that reads `WDM_INPUT`, `WDM_OUTPUT`, `WDM_CORRECTION` and `WDM_TRACE`; it does nothing without them |
| `run-tree.sh` | runs the harness of one prepared tree over every input set, `typoCorrection` off and on, and writes `LABEL-SET-c0.tsv` and `LABEL-SET-c1.tsv` with the test log next to each |
| `compare.py` | compares the outputs of the two trees and prints the figures |

## How to run

From the repository root, with a Swift 6 toolchain and a scratch directory outside the checkout:

```sh
M=Packages/VietnameseEngine/Scripts/w-doubling-measure
W=/path/to/scratch
python3 -I "$M/generate-inputs.py" "$W/inputs"
"$M/prepare-tree.sh" 0fdb9d98 "$W/base"
"$M/prepare-tree.sh" d0941160 "$W/head"
"$M/run-tree.sh" "$W/base" "$W/inputs" "$W/out" base
"$M/run-tree.sh" "$W/head" "$W/inputs" "$W/out" head
python3 -I "$M/compare.py" --inputs "$W/inputs" --out "$W/out"
```

`run-tree.sh --sets c_capital,e_capital_inner` runs a few sets only; `compare.py` skips a set whose outputs are missing.
`prepare-tree.sh` on a tree that already holds the package skips the export, copies the harness again and builds again.
The build is a debug build: on an Apple M4 under load, `a_dict` takes about three minutes per run, `f_fuzz` about twenty
seconds and every other set less than two. The harness reads members of package access (`Composition.literalStart`,
`Composition.standaloneWDoublings`, `ASCII.isUppercaseLetter`), so it compiles against a commit that has the standalone
`w` doubling of REG-40 (`a16fab61` on `integration/1.1.0` and later), not against an earlier one.

## Figures of 2026-11-22

Base `0fdb9d98`, head `d0941160`, the inputs of `generate-inputs.py` with its defaults. The same with `typoCorrection`
off and on unless the line says otherwise.

| Figure | Off | On | Where the spec quotes it |
|---|---|---|---|
| Words of `/usr/share/dict/words` typed as written that commit a different text (`a_dict`) | 0 of 235,976 | 0 of 235,976 | ENG-R804, amendment of 22/11/2026: every word typed as written commits the same text |
| Its 57 words with `ww`, typed as written and with every `w` doubled (`d_ww_written`, `d_ww_doubled`) | 0 differ | 0 differ | the same sentence |
| The 1,705 lexicon words with a `w` inside, every `w` doubled (`d_lexicon_doubled`) | 0 differ | 0 differ | the same sentence |
| Words that start with `w` or `W` typed with the habit that commit the word (`b_habit`), base -> head | 3,913 -> 3,947 of 3,947 | 3,790 -> 3,824 of 3,947 | "3,947 commit the word with `typoCorrection` off (3,913 before) and 3,824 with it on (3,790 before)" |
| Habit commits that are not the word, in head | 0 | 123, every one what the word typed with one `w` commits (`wacken` -> `waken`, `Wwayne` -> `Wane`) | "the other 123 being corrected to another word exactly as each is when typed with one `w`" |
| Capitalised words that commit in lowercase with the habit, base -> head | 34 -> 0 of 337 | 34 -> 0 of 337 | REG-41, ADR 0010 item 8: "34 of the 337 capitalised words of `/usr/share/dict/words` that start with `W`" (`Wwade` -> `wade`) |
| Habit commits that change base -> head | 34, all capitalised, none starts with a lowercase `w` | the same | "the 34 words that changed are the capitalised words above, and no word that starts with a lowercase `w` changed" |
| The 1,705 lexicon words with a capital first letter and every `w` as `Ww` that commit differently (`e_capital_inner`) | 239, each with the `w` second and only in that letter's case (`DWwell`: `Dwell` -> `DWell`) | the same 239 | known cost of the amendment: "239 commit differently, all of them with the `w` second and only in that letter's case" |
| Random sequences (`f_fuzz`) whose field differs after some event | 2,396 of 100,000 (1,893 in the final field), every one flagged, 0 not flagged | the same | "every sequence whose text differs after some event (2,396) holds a capital `W` whose `ư` a lowercase `w` escaped" |

The base column also shows the state the amendment of 20/11/2026 (REG-40) describes after it: 681 of the 1,705 lexicon
words with every `w` doubled commit the word with `typoCorrection` off (1,575 on), and 3,913 of the 3,947 habit words.
The values before that amendment (659, 795) and its counts of the 1,096 lexicon words that start with `w` and of the 17
words with `ww` that hold a `w` doubling came from the REG-40 run against the engine before it, which lacks the
standalone `w` doubling this harness reads; this directory does not reproduce them.

How the figures were checked: the outputs of the first run on 2026-11-22 were kept, and `compare.py` prints every
figure above from them. That run exported the head at `2cf73751`, the REG-41 engine commit, whose `Sources/` and
resources equal those of `d0941160` (the later commits change tests and documents only). The committed scripts, run
again on both trees, wrote the same outputs byte for byte for every set, and so did a fresh `prepare-tree.sh d0941160`
for `b_habit`, `c_capital`, `e_capital_inner` and `f_fuzz`. `generate-inputs.py` writes the kept inputs byte for byte.
