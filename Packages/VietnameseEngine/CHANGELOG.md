# Changelog

All notable changes to the engine package are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows Semantic Versioning,
separately from the app (spec/04-quality-release.md QA-R27).

## [0.1.0-dev] - Unreleased

### Added

- Letter model and the generated table of the 146 emittable letters, built from Unicode character data
  (ENG-R301).
- Syllable model of spec section 3: onsets, the 156 Tier A rhymes, the 41 `qu` rhymes, the `gi` rules with
  `gi + êc`, Tier B extensions including the `dz` onset; the parser of 3.13, validity tiers, the viability
  automaton generated from the tables (3.14), horn normalisation (5.5), tone placement in both styles
  (5.1, 5.2). Public `Orthography.analyze` and `Orthography.validity(of:)`.
- Composition (sections 4 to 7, 9.1): Telex and VNI key maps, the order of interpretation with viability
  gating, literal mode, free order, sticky escapes, the standalone `w` and bracket options, tone placement
  and relocation on every key, horn handling for `u o`, Backspace inside a token, the restore toggle,
  case and camel case, the 64-key literal cap. The display is a fold over the raw keys (ENG-R601); edits
  are minimal (ENG-R611).
- `Engine.reduce` and `Session` for key, Backspace, restore toggle and reset events.
- Commit decisions (section 8.1): rules L0 to L11 in order with a reason code for each commit; auto restore
  off, user lists, learning signals, app context `code`, the English run, and the `uơ` spelling of an open
  `ươ`. Every boundary key of 9.2 commits the same way and is delivered after the edit.
- History (section 10): Backspace re-opens the previous word across `", "`, `". "` and double spaces;
  configurable limit; resets clear the token and the history.
- Macros (section 11): table validation, matching on the raw span by a fixed-size hash key, expansion
  before L0 with adaptive casing, and the toggle that brings the trigger back.
- DocC comments on every public declaration, checked by a test.
- `VietnameseEngineTesting`: independent oracle, generated O1 to O4 corpus with the ENG-T03 variants,
  loaders for the worked examples extracted from the spec, the 13.9 fixture resources, the simulated text
  field, the fuzz invariant checker (ENG-T30 to ENG-T37), full-alphabet seeded event streams, random macro
  tables, and harnesses for the English corpus (ENG-T10) and prose typists (ENG-T20).
- Fuzz campaign: 1,000,000 events over 80 option combinations plus tokens up to 100,000 keys in the
  default test run; `ENGINE_FUZZ_EVENTS` scales it (QA-R8).
- QA-R4 corpus files `rhymes-rare`, `no-shortcuts`, `macros`, `proper-nouns`, `english`, `collisions`,
  `editing`, `crash-regressions`, `restore-exact` and `layouts`, behind one loader; `known-exceptions.txt`
  and a prose sample.
- `Packages/VietnameseEngineFuzz`: libFuzzer harness with a readable seed corpus (QA-R8, QA-R9).
- `engine-benchmark`, `Benchmarks/baseline.json` and `Benchmarks/compare.py`: the ENG-T40 benchmark and its
  calibrated gate (ENG-R1230 to ENG-R1233, QA-R14).
- Scripts: `benchmark.sh`, `coverage.sh` / `coverage.py` (QA-R2), `check-traceability.py`,
  `generate-layout-corpus.py`, `vietnamese-keys.py`.
- `TRACEABILITY.md`: every ENG-R, ENG-T and REG identifier mapped to code and tests.
- Gates of spec 8.8 on the bundled data (`VietnameseEngineDataTests/RealData`): ENG-R870 over the generated
  corpus, ENG-T10 (ENG-R871, ENG-R872) over the 40,701 lexicon and tech words, ENG-T20 (ENG-R873) over
  `data/corpus/prose-vi.txt`, with the measurements of docs/decisions/0202.
- In-process unit tests of `lexicon-builder` (`VietnameseEngineDataTests` depends on it).
- `lexicon-builder ambiguity-candidates` lists words whose display is a valid but unattested Tier A syllable
  and words with a digit typed in VNI, with `method`, `attested` and `merge_as` columns; `--merge` adds
  `en / proposed` rows where rule L8 or the tech-always list restores the word, in a separate
  `# [generated en rows]` block, with a `[generated:unattested]` or `[generated:tech-always]` token in the
  note; `build` and `check` fail when that reason no longer holds.
- `ProseCorpusCheck.run(style:)`: the ENG-T20 typists run in both tone styles; the gate accepts a 5.2
  placement difference only when the typed token is the source spelled in the typist's own style.
- `GeneratedCorpusGateTests.exclusionTotal` prints the ENG-R870 exclusions over all shards.
- `Scripts/coverage.py` also reports the line coverage of the data target and `lexicon-builder`.
- `ResetReason.unseenInput`: input reached the app that the host never saw (a keyUp without its keyDown,
  PLT-R397A). `FuzzAlphabet` encodes it as DEL, which was a second Backspace.
- `site-demo-frames` (not a product): types the website's demo sentences (`site/demo/script.json`) through the
  engine and writes `site/demo/frames.json`, the field after every key with each commit and revision; `--check`
  fails when the committed file is stale (PRD-R73). The engine coverage gates exclude it like `lexicon-builder`.
  Schema version 2 of both files: a kept English word carries `plain`, what the engine shows for its keys with auto
  restore off when that differs (`test` gives `tét`, ENG-R802), and a learning demo (`teachKeys`, `teach`,
  `teachExpect`) is taught first: its teaching passes feed their collision signals to `ReferenceCollisionMemory`
  (ENG-R863), the engine is rebuilt with each snapshot (ENG-R865), and the tool fails unless every pass corrects and
  the final pass keeps a word by rule L9c.

### Changed

- The package is licensed under the Mozilla Public License 2.0 instead of MIT, decided on 15/11/2026 before any
  release (ENG-R109, `docs/decisions/0006-app-licence-and-pro-edition.md`): `LICENSE` is the verbatim MPL-2.0
  text, `NOTICE` holds the copyright line, and every source file carries `SPDX-License-Identifier: MPL-2.0`.
- `Engine.init` builds the generated tables, so their one-time construction (about 12 ms in release) no
  longer lands on the first keystroke (ENG-R1230).
- Committing or toggling a long literal token costs a copy, not per-character work: a 100,000-key token
  commits in 0.3 ms instead of 5.7 ms (REG-02, ENG-R1232).
- Bundled data rebuilt with the real engine and retuned for the 8.8 gates (docs/decisions/0202): 1,954
  attested syllables, 619 ambiguity rows, six commands moved to and the Roman numeral `xix` added to the
  tech-always list, `a3` and `a5` removed from it (VNI `ạ`, `ả`), one-letter lexicon entries other than `a`
  and `i` dropped (40,205 words), 53 ENG-T11 exceptions pending review.
- `engine-benchmark` uses the bundled resources and replays the prose corpus with the three typists (ENG-T40);
  `Benchmarks/baseline.json` re-recorded for the new workloads.
- The resource loader proves the uniqueness of byte-sorted lists without building a second set (ENG-R1231).
- Backspace on an escape letter removes the escaping key and the keys whose effect it undid, so the display
  loses exactly one character and the kind is no longer escaped (ENG-R711, ENG-R714, product owner
  15/11/2026): `boss` + Backspace gives `bo`, `nhaamff` + Backspace gives `nhâm`. `InvariantChecker` and
  `BackspaceProbe` check strict deletion for escapes (the `escapeUndone` and `literalRecomputed` outcomes are
  gone). In the replay a tone key that finds no vowel yet waits for the next letter (`wsaw` + Backspace gives
  `á`); a bracket escape keeps a mark key that still marks a letter that stays (`]ow]` + Backspace gives `ơ`);
  the fallbacks keep a standalone `w` or bracket letter shown unmarked as a `u` or `o` key and otherwise
  retype the token from the letters shown (`dwndw` + Backspace gives `đn`). After a mark removal only the
  later mark keys count for the shared-key rule of ENG-R710 (`wzow` + Backspace gives `ư`).
  `BackspaceExhaustiveTests` checks ENG-T38 on every sequence of up to five transform keys.
- Telex `z` and VNI `0` remove one layer per press: the tone, then every vowel mark and `đ` (ENG-R411,
  REG-34): `daauszz` gives `dau`. ENG-T36 probes the removal key with three presses.

### Fixed

- English run (ENG-R823, REG-32, product owner 14/11/2026): an English loanword in a Vietnamese sentence no
  longer makes the run English. The run is English only when the previous three committed tokens hold an
  English token and no Vietnamese one, and a token kept by rule L11 is neutral, so `cũng tricky as` commits
  `á` and `trên server been` commits `bên`. The rule only removes L10 restores, never adds one; the cost is
  that a collision within three tokens after a switch from Vietnamese to English stays Vietnamese. The
  prose-corpus difference `Cơ -> Cow` is gone. Spec rows B065-B072 (13.9.2), checked by
  `spec/reference-model/boundary.py`.
- `Orthography` is `Sendable`, as ENG-R1203 requires of every public type.
- `lexicon-builder` checked NFC with String `==`, which accepted decomposed text; it compares scalars now.
- Review of the integration branch: `ĩ` (ầm ĩ) is attested and `ix` is no longer a tech-always word, so
  Telex users can type it; VNI users can type `ạ` and `ả` again; `chown` and `ef` are code-only again
  (`chơn`, `è` are Vietnamese).
- `lexicon-builder ambiguity-candidates` listed `h2o` and `m4a` (a digit ends the token in Telex) with the
  displays `o` and `a`.
- Backspace no longer changes a letter it does not delete (REG-31, ENG-R710 as amended on 14/11/2026): one
  Telex `w` or VNI `7` on `uo` stays with the `ư` when the `ơ` is deleted (`thuowr` + Backspace gives `thư`,
  `nguowif`, space, 3 Backspaces give `ngư`), a re-opened `thuở` gives `thu`, and a `u` whose horns a
  circumflex replaced stays plain. `BackspaceProbe` and the ENG-T38 property tests (generated corpus,
  English lexicon, prose corpus, fuzz invariant) check that every Backspace only deletes, except the
  documented exceptions of ENG-R714.
- A re-opened token that a commit rule restored composes again once Backspace leaves keys that compose to
  the text shown (ENG-R1005, REG-33, product owner 15/11/2026): `tiesng`, space, five Backspaces, `eesn` gives
  `tiến`, not `tieesn`. A user restore (L1) stays literal.
- Rule L9 follows the line, not the app (ENG-R850, REG-35, product owner 15/11/2026, dev trace in iTerm2): in
  the code context a code-only word is restored only outside Vietnamese text, so `Suwar looxi chinhs tar"`
  commits `Sửa lỗi chính tả"` instead of `Sửa lỗi chính tar"`. A token is in Vietnamese text when a Vietnamese
  word (a `vi` token, or a Vietnamese syllable typed unchanged, the RV4 evidence) stands among the previous
  three tokens of the line, the previous token is neither English nor a code word shown as typed, and the
  characters between them hold a space and no code character (backquote, `|`, `&`, `$`); a word glued to the
  previous one with no space is a code join (`cp anh.tar.gz`, `ssh minh@host` keep their keys); the line is the history, so Return, Tab and a reset start a
  new one. `tar -xzf` at the start of a line, `sudo tar`, `echo "xong" | tee` and `ssh -p 22 host` keep the
  keys as typed. The rule only removes L9 restores and does not read `lookaheadRevision`
  (`CommitPolicy.isInVietnameseText`, `CollisionFacts.vietnameseAsTyped`, `CommitContext.inVietnameseText`).
  With the bundled data L9 reaches Telex `host`, `tar` and `tee`. In the code context the prose corpus now
  commits exactly as in the general context (8 `tả` were restored per typist before), and the W11 corpus keeps
  every Vietnamese-intent collision of the general context (tone last 620 of 623, was 613; tone after the vowel
  501 of 507, was 493); English intent in the code context 550 of 720 (was 559; 548 in the general context).
  Spec rows B035-B035i and B064a, B064b; `spec/reference-model/boundary.py` models the rule (`CODE_RUNS`);
  `ProseCorpusCheck.run` takes an `appContext`.
- RV5, a revision of the code context (ENG-R828, ENG-R850, REG-36, product owner's retest of 16/11/2026 in iTerm2):
  at the start of a line nothing stands before a token, so L9 restores a code-only word there (`Tar thuwr cais nayf`
  gave `Tar thử cái này`); once the next word shows the line is Vietnamese text, the word takes the display the rules
  after L9 give it, as in the general context (`Tả thử cái này`, reason `lineVietnamese`, the token becomes neutral,
  the restore toggle right after undoes it). Guards: the word was restored by L9 as the first word of its line
  (no token since the start of input, Return, Tab, a reset, also in the middle of a line, or a Backspace that
  emptied the line, and before it only spaces and the openers of prose, as for the sentence condition below), the rules after L9 keep its Vietnamese display with its own run
  and window (never an `en` row, L10 or a learned English vote), one space follows it, the next word is kept by L7 with
  a Vietnamese-only letter (an unchanged syllable is not evidence: `host minh`) and is committed by a space, Return,
  `,`, `!` or `?` (`tee nhật.log`, `tee nhật-ký.log` and Tab keep the command). The case of the word never widens
  this evidence (a widening by a capital first letter, added after a review the same day, was withdrawn with the
  sentence condition below: `Host minh` keeps its keys). New public switch
  `EngineConfiguration.lineStartRevision` (default on, independent of `lookaheadRevision`, which the rules turn off in
  every code-context app; the host passes D29) and `RevisionReason.lineVietnamese` (`CommitPolicy.lineStartRevision`,
  `CollisionFacts.vietnameseAtLineStart`, `CommitPolicy.keepsVietnameseAfterCodeRule`). With the bundled data RV5
  reaches Telex `host`, `tar` and `tee`. The W11 corpus in the code context: one more revision per habit (99 and 97),
  English intent 549 of 720 (was 550): CS0571 `Host mới chạy nhanh gấp đôi` now shows `Hót` as in the general
  context; Vietnamese intent unchanged (620 of 623, 501 of 507); with `lookaheadRevision` off, as the rules of
  terminals set it, RV5 fires once in the corpus (the same CS0571; English intent 423 of 720, was 424); the
  general-context numbers do not move. Spec rows
  B035j-B035l and table 13.9.4 (K01-K16); `spec/reference-model/boundary.py` models RV5.
- The sentence condition of rule L9 (ENG-R850 as amended by the product owner on 16/11/2026, REG-36): shell commands
  are typed in lowercase, so a capital first letter at the start of a line is itself a sign of a Vietnamese sentence.
  In the code context L9 does not apply to a code-only word that is the first word of its line (no token yet on the
  line, and before it at most 63 spaces and openers of prose: the straight and opening curly quotes, `(`, `[`, and the
  list, heading, block-quote and comment markers `-`, `*`, `#`, `>`, `/`; the line start RV5 shares, after the review
  of the same day, so `"Tar`, `- Tar`, `# Tar` and an indented `Tar` count, while `| Tee`, `./Tar` and `1. Tar` do
  not), written in sentence case (the first letter uppercase, every other letter lowercase, at least
  two letters: `Tar`, `Tee`; not `TAR` or `tar`), committed by a space (`Tee-Object`, `Host:`, `Tar.` keep L9) and not
  on the new capitalized code-word list (v1: `host`, for `Host github.com` in `~/.ssh/config` and the HTTP header
  `Host:`). The rules after L9 decide it at its own commit, as in the general context, with their reason code
  (`Tar` gives `Tả`, `.kept(.ambiguityTable)` with the bundled data, where `tar` has a `vi` row, and
  `.kept(.defaultVietnamese)` with the 13.9 fixtures), except that the English run of the lines before, which
  survives Return, does not reach it (a capital at a line start opens a new sentence): after `git status` and Return,
  `Tar thuwr cais nayf` gives `Tả thử cái này`, where the general context keeps `Tar` by L10; it reads neither `lookaheadRevision` nor
  `lineStartRevision`. `Tar thuwr cais nayf` now gives `Tả thử cái này` with no revision, also with D29 off; `Host
  minh` keeps its keys and `Host nayf` gives `Hót này` by RV5; `TAR thuwr` gives `TẢ thử` by RV5. New public
  `Resources.techCodeCapitalized` (init parameter after `techCodeOnly`, default empty), bundled as
  `tech-code-capitalized.txt` from `data/inputs/tech-code-capitalized.txt` (the build refuses an entry that is not on
  `tech-code-only.txt`); `CommitPolicy.startsSentence`, `CommitPolicy.isSentenceCase`, `CommitPolicy.isLineStart`,
  `CommitContext.atLineStart`;
  `RevisionEvidence.isSentenceCapital` is removed. Known costs: an English line or a command typed with a capital
  first letter shows the Vietnamese display of its first word (`Tar archives are` gives `Tả archives are`, `Tee
  nhaatj.log` gives `Tê nhật.log`, also after an English line or behind a list or comment marker; the escape `Tarr`
  keeps `Tar`); a numbered list item (`1. Tar thử`) keeps the keys. Spec rows B035j-B035n, B064c and table 13.9.4
  (K01-K25); `spec/reference-model/boundary.py` models the condition (`CODE_RUNS`, `CODE_RUNS_CAPITALIZED`). The W11 corpus
  does not move: in the code context English intent 549 of 720, Vietnamese intent 620 of 623 and 501 of 507, 99 and
  97 revisions, the one reviewed wrong revision still CS0571 `Host mới` (`host` is on the list, so RV5 decides it as
  before); the general-context numbers and the prose corpus in the code context are unchanged.
