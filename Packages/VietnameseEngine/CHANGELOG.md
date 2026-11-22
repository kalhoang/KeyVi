<!-- SPDX-License-Identifier: MPL-2.0 -->
# Changelog

All notable changes to the engine package are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows Semantic Versioning,
separately from the app (spec/04-quality-release.md QA-R27). Releases are tagged `engine-vX.Y.Z`.

## [Unreleased]

### Added

- `CommitRule.toneRemoval`, the reason code of the new rule L4a (spec/01-engine.md 8.1, ENG-R411, REG-39). A
  consumer that switches exhaustively over `CommitRule` needs the new case, so this is a source-breaking addition
  and the next tag is `engine-v0.2.0`.
- The typo correction of spec/01-engine.md section 11A (1.1.0, ENG-R1110 to ENG-R1125): at the commit of a word the
  engine replaces one clearly mistyped English word with the only word of the correction lexicon one edit away
  (`androdi` gives `android`, `gramar` gives `grammar`), never a Vietnamese word or a word one key from Vietnamese
  (`ddi pahir` stays `đi pahir`), only in the general context, at whitespace, Return, Tab or an ASCII closer of prose,
  with nothing glued before the word. The restore toggle right after the correction, or after Backspace re-opened
  it, brings back the keys as typed and sends `LearningSignal.neverCorrect`. The public API of the feature:
  `EngineConfiguration.typoCorrection` (default true; off, every commit is exactly as without the section),
  `CommitDecision.corrected(CommitRule)`, `LearningSignal.neverCorrect(raw:)`, `CorrectionData`,
  `ApproximateWordSet`, `Resources.userNeverCorrect` and `Resources.correction`. A consumer that switches
  exhaustively over `CommitDecision` or `LearningSignal` needs the new cases, so these are source-breaking additions
  in the same minor bump (`engine-v0.2.0`). The bundled correction data (the guard list, the keyboard neighbours,
  the unmarked shapes and the Vietnamese keyings, ENG-R1120) is built by `lexicon-builder` and documented with it.
- `PackedWordSet` (spec 12.2, sixth amendment): the type of `CorrectionData.unmarkedShapes` and `vietnameseKeyings`.
  Each word of 1 to 12 letters `a` to `z` is one `UInt64` (5 bits per letter) in a sorted array searched by halves;
  any other word is kept beside it in an ordinary set. As `WordSet`s the two lists took 1.30 MB resident, over the
  1 MB of ENG-R1120; packed, the correction data and the engine's index of it take 0.38 MB, and the index reads the
  two sets in place. `CorrectionData` keeps an initialiser that takes `WordSet`s and packs them, so callers written
  against the earlier 1.1.0 API compile unchanged; code that reads the two fields as `WordSet`s needs
  `PackedWordSet`, whose `contains(_:)` is the same.
- Resource format 3 (`VietnameseEngineData`, docs/decisions/0203-correction-data.md): `manifest.json` says
  `"format": 3` and four files follow the collision lists: `guard-list.bloom` (a 32-byte `KVGL` header, then the
  Bloom filter's bits: the SCOWL words of sizes 40 to 70 and the proper names, 77,488 words, 2^20 bits, 8 hashes),
  `keyboard-neighbours.txt`, `unmarked-shapes.txt` (3,953) and `vietnamese-keyings.txt` (27,277). The loader reads
  format 3 only and refuses formats 1 and 2. Problems are reported with the existing `Resources.LoadError` cases.

### Changed

- The loader refuses an empty `unmarked-shapes.txt` or `vietnamese-keyings.txt` with
  `malformedResource("<file>: no entry")`, even when its manifest row agrees: the lists are generated and never empty
  (spec 12.2, the fifth amendment of 1.1.0), and an empty one would silently turn off ENG-R1110 (d) and ENG-R1125.
- The loader splits the UTF-8 lists (the attested syllables, the ambiguity table, the phrases, the neighbours table)
  on the LF byte instead of on characters: a CR before the LF now stays in its line and fails the entry check
  (`invalidCharacter`) instead of `missingFinalNewline`. With the packed shapes and keyings and the raw-pointer
  parsing, `Resources.bundled` takes 22 to 24 ms of CPU in a debug build (52 to 58 ms on the merged 1.1.0 branch
  before, against the 50 ms of ENG-R1231) and 10 to 15 ms in a release build.

- Rule L4a, the tone removal at commit (product owner, 18/11/2026, Q9 of spec section 15): when the last key of a
  token is a tone-removal key (Telex `z`, VNI `0`) that removed the tone or the letter marks, the commit keeps the
  display, syllable or not, unless the raw keys are English, as an escape keeps its form (L4). `dduwowngfzz` + space
  gives `duong` (it restored `dduwowngfzz` by L5), `vieejtz` gives `viêt`, `daauszz` gives `dau`, VNI `vie65t0` gives
  `viêt`; `quartz` is restored. A removal that more letters follow is decided by the rules after L4a as before
  (`Amazon` stays `Amazon`): read anywhere in the token, the rule committed 193 words of `/usr/share/dict/words` as
  text that is no syllable; at the end of the token it changes 3 (`bortz`, `hertz`, `wootz` give `bot`, `het`, `uot`,
  the known cost). Spec rows B052a to B052d; `spec/reference-model/boundary.py` models the rule (`REMOVAL_RUNS`).
- Rule L9 for code-only words whose raw keys are not English (product owner, 18/11/2026, REG-38, the open point of
  ENG-R850): in the code context such a word is decided by L9 right after L5, before L6 and L7, so it follows the line
  exactly as `tar` does. Outside Vietnamese text and not at a sentence start it keeps its keys (`sudo chown -R`,
  `ls; chown`, `ps -ef`, which gave `chơn` and `è`); RV5 revises it at a line start before a Vietnamese word
  (`chown thuwr` gives `chơn thử`); in Vietnamese text and in sentence case at a line start it keeps its Vietnamese
  display (`tay chơn`, `Chơn`). Code-only words whose keys are English reach L9 in its place as before; the general
  context and VNI do not change. With the bundled data L9 now reaches `awk`, `chown`, `ef`, `host`, `tar` and `tee`;
  the prose corpus and the W11 corpus in the code context do not move. Spec rows B035o to B035t (`chown` joins the
  13.9 fixture code-only list) and K26 to K32.
- Bundled data: 18 developer words on the tech-always list (406 entries), `frontend`, `backend`, `rebase`,
  `debounce`, `upsert`, `structs` and their corrected inflections among them (ENG-R1124, the W11 row;
  docs/decisions/0203-correction-data.md section 10). The typo correction changed each into another English word
  one edit away (`frontend` gave `fronted`, `upsert` gave `upset`); listed, they are words of the correction lexicon
  and stay as typed. Their compositions are invalid, so rule L5 already restored them and no 1.0 output moves.
- Bundled data: the phrases `day off`, `sale off` and `a mess` (product owner, 18/11/2026; 330 phrases). The phrase
  evidence of rule L4 (ENG-R804 (a)) now keeps the word typed in `day off`, `a mess` and `Ê có sale off`, which kept
  the escapes `day of`, `a mes` and `sale of`; `ok off`, `50% off`, `mess up`, `off topic` and `Off the record` keep
  them (parked). The W11 corpus gains one exact sentence per habit (CS0010), the collision numbers do not move. Spec
  rows X25 to X27.
- The prose-corpus gate pins Telex `IX` -> `Ĩ` (two tokens per Telex typist) as the product owner's decision Q26 of
  13/11/2026 instead of recording it as a known issue (docs/decisions/0202, open issue 3).
- Rule L4 and a `w` doubled out of habit (product owner, 20/11/2026, ENG-R804, REG-40): `R′`, the raw keys without
  the key of each `w` doubling (a Telex `w` escape right after the `w` key whose effect it removes), is restored when
  it is English and neither `C` nor `R` is ((c′): `answwer` gives `answer`), and the restore of (d) puts back `R′`
  when every `w` doubling removed the `ư` of a standalone `w` (`wwebview` gives `webview`, it gave `wwebview`); `R`
  English decides first (`www`, `powwow`), and the reason code stays `escape`. The typed word of the typo correction
  is `R′` in that case (`wwindwos` gives `windows`), a re-opened token shows `R′`, every later commit of it that
  restores writes `R′` again (`answwer`, space, two Backspaces, space gives `answe `), and the toggle composes it.
  The `w` doublings are a habit only when no `w` key follows them and none is a capital right after a lowercase `w`
  (`wwwexample` and `dwWidth` keep every `w`), and rule L3b restores `R′` for camel case keys with that habit
  (`WwordPress` gives `WordPress`, ENG-R904). A Backspace that takes the doubling a re-opened token does not show
  ends the omission, and a commit that writes the token's text unchanged (the typed word the toggle took back from a
  correction) keeps it showing `R′` (ENG-R701, ENG-R1005, ENG-R1117). Every
  word of `/usr/share/dict/words` typed as written commits the same text as before. Spec rows X28 to X39;
  `spec/reference-model/boundary.py` models the rule.
- A capitalised word typed `Ww` (product owner, 22/11/2026, ENG-R903, ENG-R804, REG-41): the escaped letter of a
  standalone `w` doubling takes the place of the `ư` it removed, so it is a capital when either `w` key is one (`Ww`
  shows `W`, as `WW` and `wW` do; `ww` shows `w`; `Composition.showsEscapedWAsCapital`). `Wwade` shows and commits
  `Wade` and `Wwarden` gives `Warden`, which gave `wade` and `warden`: the escape appended its own key, a lowercase
  `w`, and rule L4 (b) or the deliberate form kept that display. No rule of 8.1 changes; horn and breve doublings,
  every other escape and capitals typed on both keys keep the case of the escaping key, and the raw keys stay as typed.
  Every word of `/usr/share/dict/words` typed as written commits the same text as before; of its 3,947 words that
  start with `w` or `W`, typed with the habit, 3,947 commit the word with `typoCorrection` off (3,913 before). Spec
  rows X40 to X43; `spec/reference-model/compose.py` models it.
- The restore toggle right after a commit whose restore the words before decided (product owner, 23/11/2026,
  ENG-R706, REG-42): when rule L10 (the English run) or L9b (a phrase) restored the token and rule L11 alone would
  keep it, the toggle answers with an edit that puts the composed form back, the boundary character unchanged
  (`Thanks Giving bar`, space, toggle gives `Thanks Giving bả `; it passed through, ENG-R703), marks the token user-kept,
  carries `preferredVietnamese(raw)` and a strong `CollisionSignal` for the Vietnamese side, as Backspace then the
  toggle do, and withdraws the token's weak signal; the next toggle passes through. No undo after Return, Tab or a
  non-ASCII boundary, and a commit that also revised the token before is undone as a revision (ENG-R829). Restores
  that the token alone decides (`best`, an `en` row), L9, L9c and L4 are left as they were. The words covered after an
  English run are the `vi` rows of the ambiguity table whose `run` column is `en`: 289 words of the bundled English
  lists, common English words such as `there` and `this` among them (`I will be there`, space, toggle gives
  `I will be thể `). No public API changes. Spec rows E09 to E13; the measurement harness, with the census of the
  covered words, is `Scripts/context-restore-measure/`.

## [0.1.0] - 2026-11-18

The engine as shipped in the app 1.0.0.

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
- Rule L4, the escape at commit (ENG-R804, REG-37, product owner 17/11/2026): `leecher` committed `lecher`, because
  the third `e` escaped the circumflex of `lêch` and the old L4 kept the escaped form when neither form was English
  (about 4,600 words of `/usr/share/dict/words`), and `dessert`, `costs`, `pass` and `off` committed `desert`,
  `cots`, `pas` and `of` because the escaped form was English. A deliberate escape is now a doubling (the escape
  key right after the key whose effect it removes, `Composition.escapedAcrossKeys`). With both forms English the
  escaped form is kept only for a needed doubling (the keys of `C` alone commit something else, learned memory left
  out) outside an English context (the run of ENG-R823 or a phrase of ENG-R826): `off` alone and `tắt of đi` keep
  `of`, `turn off the light` and `the mess` keep the keys, `pass` and `dessert` always do. With neither form
  English the escaped form is kept when every escape was a doubling and it has one vowel group at most
  (`CommittedTextFacts.vowelGroups`) or ends with the escape (`Composition.endsWithEscape`): `nhâmf`, `booong`,
  `Krông Ana` stay, `leecher`, `cheeseburger`, `coffeehouse`, `pajama` commit as typed. The reason code stays
  `escape`. Sweeps with the default configuration: 4,696 of 5,824 differing words of web2 and 45 of 392 of the
  lexicon now commit as typed, none newly changed; ENG-T11 lists no L4 entry for the English run (56 changed
  words, was 106) and five Vietnamese-context entries; the W11 fixtures keep `pass`, `posts`, `costs`, `off`,
  `Terraform`, `Grafana`, `DeepSeek` in 34 more sentences with the collision numbers unchanged. Spec rows X01 to X24
  (13.9.5), `escape-regression.txt` (393 words). Known costs, pinned by tests: the English context looks back only
  (`day off`, `mess up` and `Off the record` keep `day of`, `mes up`, `Of the record`), and a tone key between the
  circumflex key and its escape breaks the doubling (`theesee` is restored, `thesee` keeps `thée`).
