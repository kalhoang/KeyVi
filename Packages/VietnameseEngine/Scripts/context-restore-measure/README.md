<!-- SPDX-License-Identifier: MPL-2.0 -->
# Context restore measurement (ENG-R706, REG-42)

A differential harness: it types the same key sequences through the engine of two commits and compares what each one
shows, commits and reports. It produced the figures that `spec/01-engine.md` ENG-R706 (the undo of a restore that the
words before a token decided, added on 23/11/2026), REG-42 and item 9 of
`docs/decisions/0010-pa-decisions-2026-11-19.md` quote: base `28dbd6d0` (1.1.0-beta.1) against head `996c0780`
(REG-42). It follows the layout of `../w-doubling-measure/`.

No target of the repository compiles `ContextRestoreMeasureTests.swift` where it lies: `Package.swift` builds only
`Sources/`, `Tests/` and `Benchmarks/EngineBenchmark`, so `swift build` and `swift test` of the package never see it.
`prepare-tree.sh` copies it into a scratch export of the package.

## What it measures

Every input line is typed from an empty field with the bundled data (8.2) and Telex with its default options, once with
`typoCorrection` off (`c0`) and once on (`c1`); `run-tree.sh --lookahead-off` and `--autorestore-off` turn
`lookaheadRevision` or `autoRestore` off for a run of their own. The harness writes one line per input: the flag, a
tab, the final field, a tab and a hash of every event's field and output (the action, the decision, the learning signal
and the collision signals), so a difference that a later key hides, or a signal that changes while the text does not,
still counts.

The flag is the number of restore keys of the line that come right after a commit ENG-R706 covers: a commit whose
decision is `restored(englishRun)` (rule L10) or `restored(phrase)` (rule L9b), with no revision of the token before,
at an ASCII boundary that keeps the history, whose token rule L11 alone would keep (an ambiguity row `vi` or unreviewed,
or no row and no tech-always word). The harness computes it from each commit's output and the history, with what the
engine of `28dbd6d0` already has, never from the mark the head engine keeps for itself, so both trees compute it the
same way. Up to the first such restore key both trees see the same events, so a line must differ exactly when its flag
is not 0: `compare.py` fails when a line differs without the flag, when a flagged line does not differ, or when the two
trees disagree on whether a line is flagged.

The flag restates the condition of ENG-R706 on purpose, so these checks show that no line outside the rule changed;
they cannot show whether the rule covers the right words, since any scope passes them. The set `i_census` makes the
scope visible: it types every word of the English lexicon and both tech lists after the English run of the report
(`Thanks Giving `), so its flagged lines are the words the rule covers after an English run, and
`compare.py --census FILE` writes them (word, base field, head field, ambiguity row, English function word) and prints
how many there are and which are function words. The phrases the rule covers are the flagged lines of `h_phrases`.

| Set | Lines | Keys of each line |
|---|---|---|
| `f_fuzz` | 100,000 | the random sequences of `../w-doubling-measure` (`w`, `W`, vowels, tone keys, a few consonants, Backspace `⌫`, space and the restore key `⎋`, seed 22112026), written by that script's own function, byte for byte |
| `g_mixed` | 60,000 | 2 to 9 tokens: words of the bundled lexicon (`english.txt`, 35 %), raw keys of the ambiguity table (`ambiguity.tsv`, the words valid in both languages, 30 %) and Telex keyings of Vietnamese syllables (`vietnamese-keyings.txt`, 35 %), the first one in sentence case 15 % of the time; between them a space mostly, or `, . ? ! ; : )` and a space, Return (`↵`), Tab (`⇥`), `…`, `”` or a no-break space; after each boundary the restore key 35 % of the time, twice 5 % and after a Backspace 5 %; seed 23112026 |
| `h_phrases` | 1,320 | each of the 330 bundled phrases (`phrases.txt`) from an empty field, after `and` and after `vieejt`, then a space and the restore key; and followed by `nhaf` and a space |
| `i_census` | 40,715 | `Thanks Giving `, then each word of `english.txt`, `tech-always.txt` and `tech-code-only.txt` (the word list of ENG-T10, unique, in byte order), a space and the restore key |

The lines have capitals only where a `g_mixed` line starts in sentence case and in the census context, and no reset
event (a click or a focus change); the engine tests cover those (`ContextRestoreUndoTests`,
`ContextRestoreUndoRealDataTests`).

The bundled data is the same at both commits. SHA-256 of the sets the defaults write: `f_fuzz.txt`
`84ad4b74eedc658d3bda9744f663988c6f69da69f0b47454eb1c088a0ac47656`, `g_mixed.txt`
`a0f5581663cf1dc26580e14d8aad7ad2fe661f54eee8547790bff8d30343c252`, `h_phrases.txt`
`fa11f03018792d7a9b527a17f295eb64144f185d2da720c7e9d375b30e267a2d`, `i_census.txt`
`e8daee19ee5f848a85e5cd5524a322ddf8dfd0c98b29bb251b8dd4628d1590c5`.

| File | Role |
|---|---|
| `generate-inputs.py` | writes the input sets into a directory (`--seed`, `--mixed`) |
| `prepare-tree.sh` | exports `Packages/VietnameseEngine` of a commit with `git archive` into a scratch directory, copies the harness into its test target `VietnameseEngineDataTests` and builds the package with its tests under `nice`, in a private scratch path inside that copy |
| `ContextRestoreMeasureTests.swift` | the harness, a Swift Testing test that reads `CRM_INPUT`, `CRM_OUTPUT`, `CRM_CORRECTION`, `CRM_LOOKAHEAD` and `CRM_AUTORESTORE`; it does nothing without the first two |
| `run-tree.sh` | runs the harness of one prepared tree over every input set, `typoCorrection` off and on, and writes `LABEL-SET-c0.tsv` and `LABEL-SET-c1.tsv` with the test log next to each; `--lookahead-off` and `--autorestore-off` turn that switch off |
| `compare.py` | compares the outputs of the two trees, prints the figures and a few differing lines per set; `--census FILE` writes and sums up the covered words of `i_census` |

## How to run

From the repository root, with a Swift 6 toolchain and a scratch directory outside the checkout:

```sh
M=Packages/VietnameseEngine/Scripts/context-restore-measure
W=/path/to/scratch
python3 -I "$M/generate-inputs.py" "$W/inputs"
"$M/prepare-tree.sh" 28dbd6d0 "$W/base"
"$M/prepare-tree.sh" 996c0780 "$W/head"
"$M/run-tree.sh" "$W/base" "$W/inputs" "$W/out" base
"$M/run-tree.sh" "$W/head" "$W/inputs" "$W/out" head
python3 -I "$M/compare.py" --inputs "$W/inputs" --out "$W/out" --census "$W/census.tsv"
for label in base head; do
  "$M/run-tree.sh" --lookahead-off --sets g_mixed,h_phrases,i_census "$W/$label" "$W/inputs" "$W/out" "$label-nolook"
  "$M/run-tree.sh" --autorestore-off --sets g_mixed,h_phrases,i_census "$W/$label" "$W/inputs" "$W/out" "$label-noauto"
done
python3 -I "$M/compare.py" --inputs "$W/inputs" --out "$W/out" --base base-nolook --head head-nolook
python3 -I "$M/compare.py" --inputs "$W/inputs" --out "$W/out" --base base-noauto --head head-noauto
```

`run-tree.sh --sets g_mixed` runs one set only; `compare.py` skips a set whose outputs are missing. `prepare-tree.sh`
on a tree that already holds the package of the same commit (recorded in `TREE/.crm-commit`) skips the export, copies
the harness again and builds again; it refuses a tree that holds another commit or has no record. The build is a debug
build.

## Figures of 2026-11-23

Base `28dbd6d0`, head `996c0780`, the inputs of `generate-inputs.py` with its defaults. The figures are the same with
`typoCorrection` off and on. The first three sets were run first; the census set and the runs with a switch off were
added in the review of the same day and the first three sets run again with this harness, with the same figures (the
engine package's `Sources/` are the same at `996c0780` and at the head of the branch).

| Set | Lines | Lines flagged (restore keys flagged) | Lines that differ (final field) | Differ without the flag | Flagged and unchanged |
|---|---|---|---|---|---|
| `f_fuzz` | 100,000 | 0 (0) | 0 (0) | 0 | 0 |
| `g_mixed` | 60,000 | 3,167 (3,353) | 3,167 (3,167) | 0 | 0 |
| `h_phrases` | 1,320 | 296 (296) | 296 (296) | 0 | 0 |
| `i_census` | 40,715 | 289 (289) | 289 (289) | 0 | 0 |

With a switch off (`run-tree.sh --lookahead-off` or `--autorestore-off`, sets `g_mixed`, `h_phrases` and `i_census`),
again the same with `typoCorrection` off and on, no line differs without the flag and every flagged line differs:

| Set | `lookaheadRevision` off: lines flagged and differing (restore keys flagged) | `autoRestore` off: lines flagged and differing |
|---|---|---|
| `g_mixed` | 3,704 (3,983) | 0 |
| `h_phrases` | 183 (183) | 0 |
| `i_census` | 342 (342) | 0 |

With `lookaheadRevision` off rule L9b restores nothing, so the phrase lines that differ are those where an English word
of the phrase, or the `and` before it, makes an English run and rule L10 restores the next word (77 typed alone, 104
after `and`, 2 after `vieejt`), and the `run: vi` exemption of rule L10 (ENG-R829) is off, so the census grows by the
53 `vi` rows whose `run` column is `vi`; with auto restore off rules L10 and L9b restore nothing and there is nothing
to undo.

The census (`compare.py --census`): 289 of the 40,715 words are covered after `Thanks Giving `, every one a `vi` row of
the ambiguity table whose `run` column is `en` (10 `proposed`, 279 `unreviewed`); those rows are 292, and the other
three (`chown`, `ef`, `max`) are kept as Vietnamese there because only the code context makes them English. 32 of the
289 are English function words (`english-function-words.txt`): `as away been did has here hers hes his how hows if ifs
its last lest lets mes most must nor now of own sir thee there these this thus too us`. The flagged lines of
`h_phrases` hold 104 of the 330 phrases (96 typed alone, 104 after `and`, 96 after `vieejt`).

Where the spec quotes them: ENG-R706, amendment of 23/11/2026: "every line whose text or signals differ (3,167 of the
60,000 mixed lines and 296 of the 1,320 phrase lines, the same with `typoCorrection` on and off) holds a restore key
right after a commit that ENG-R706 covers, and every line that holds one differs; the 100,000 random sequences of the
`w` doubling harness do not differ".

A line that differs can differ after the undo too: the undone word is Vietnamese evidence for the window (ENG-R823), so
a later collision word that the English run restored at base is kept at head (`disobeying ⎋vats ⎋swoon. ⎋` gives
`disobeying vats swoon. ` at base and `disobeying vát suôn. ` at head). Lines of `compare.py --examples 4`:

```text
'beef ⎋disordered; bows ⎋huir ⎋weaves↵⌫⎋'    base 'bề disordered; bows hủi weaves'   head 'bề disordered; bớ hủi weaves'
'Piano ⎋morns\xa0lows ⎋sins. '                base 'Piano món\xa0lows sins. '          head 'Piano món\xa0lớ sins. '
'a lot of ⎋'                                  base 'a lot of '                         head 'a lot ò '
'a must ⎋'                                    base 'a must '                           head 'a mút '
```

The base runs took about three and a half minutes, the head runs four and a half, on an Apple M4 under a load average
of 10 to 14 (debug build).
