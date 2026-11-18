# 0008. Collision learning: words that are English and Vietnamese at once

- Status: accepted, 2026-11-15; the one open question (the held-out floor of ENG-R877, see the last section
  before Consequences) was settled on 2026-11-18 (amendment at the end). The product owner decided on 15/11/2026 that {{AppName}} learns how each user
  resolves these words (per user across all apps, from corrections and from silent acceptance, behind a switch that
  is on by default), proposed that the next word decide the word before it, asked for many more cases before an
  algorithm was chosen, and then reviewed the data lists ([0005](0005-pa-decisions-2026-11-13.md), "Decisions of
  15/11/2026"). Engine rules and data: workstream W15-A. Host memory store, revision edit job and compatibility
  flag: W11-B. Settings: W11-C. Corpus gate, measurements and this record: W11-D.
- Spec: `spec/01-engine.md` 8.1 (rules L9a, L9b, L9c), 8.2 (data), ENG-R823 (amended), ENG-R824 to ENG-R829,
  ENG-R861 to ENG-R866, ENG-R876, ENG-R877, worked examples 13.9.3, corpus 13.11; `spec/04-quality-release.md`
  QA-R68. Host and Settings parts in `spec/02-platform.md` and `spec/03-product.md` (W11-B, W11-C).
- Tests: the QA-R68 gate in `Packages/VietnameseEngine/Tests/CollisionCorpusTests` (fixtures and provenance in its
  `Fixtures/README.txt`); the rule tests in `Packages/VietnameseEngine/Tests/VietnameseEngineTests/Collision/`.

## Context

Some English words type as real Vietnamese syllables in Telex: `as` gives `á`, `car` gives `cả`, `been` gives
`bên`, `this` gives `thí`, `did` gives `đi`. Before this decision the engine decided each such word alone at commit:
the ambiguity table (rule L11) and the English run of the three previous words (L10). On the labelled corpus below
that got 58.5 % of the words meant as English right and 94.5 % of the words meant as Vietnamese. The product owner's
own examples show why one decision per word cannot work: `tricky á.` and `tricky á nha` are Vietnamese, `tricky as
hell` is English, with the same word after the same word.

The research round of 13/11 to 15/11/2026 built, all from material written for this project:

- an inventory of the collisions of the English lexicon with their readings, kinds and phrases;
- a labelled corpus of 1,206 chat, office, developer and control sentences (11,180 words, 1,343 collisions: 720 meant
  as English, 623 as Vietnamese), each word labelled with its intended language, category and position;
- two rule designs, one precision-first and one accuracy-first, each attacked by a small set written against the
  other (57 and 42 lines);
- a review that took the precision-first skeleton, grafted four parts of the other design, and wrote a third set of
  81 lines before running the final rules on it (the held-out set).

## Decision

1. **Decide at commit when the word or its neighbours already show the language.** A boundary particle (`as`,
   the only entry) before `.`, `!`, `?` or Return keeps `á` (L9a, ENG-R825); a word that continues a bundled English
   phrase with the one to three words before it is restored (L9b, 327 phrases, ENG-R826); the user's learned choice
   decides (L9c, ENG-R863); common Vietnamese words never join the English run (`run: vi`, ENG-R827); unchanged
   English-lean words such as `the` and `my` count as English in the window (ENG-R823).
2. **Revise the previous word once, inside the next word's commit edit**, when the next word shows the language:
   the next word continues a phrase (RV1), a Vietnamese tail particle follows a restored `as` (RV2), an English
   function word follows a kept word that is not a particle (RV3), or Vietnamese content follows a function word the
   English run restored (RV4), with the guards of ENG-R828 (tail words, the pre-guard list). Nothing older than the
   previous word changes; a revised word is never revised again. Escape right after the revising commit undoes it
   (ENG-R829). `EngineConfiguration.lookaheadRevision` turns all of this off; the host passes the app's value
   (terminals, code editors and launchers off, W11-B).
3. **Learn per user, only collision words.** The memory keys only words of the bundled collision list (the ambiguity
   table plus a supplement of 34 words outside the English lexicon), by the class of the previous word (sentence
   start, after Vietnamese, after English, after a neutral word) plus one entry for any context. Corrections are
   strong signals, silent acceptance weak; acceptance creates entries but an entry without a correction never votes;
   the thresholds, the conflict and the any-context two-class rule are those of ENG-R863. Ordinary words keep the
   per-app learning of ENG-R862.
4. **Privacy.** The memory stores the bundled word itself (an index would reset with every data update), a context
   class, counters and a day; never the neighbouring word, the app or the field. Collision words never reach logs or
   diagnostics, which show the entry count only (ENG-R866, PLT-R901).
5. **The QA-R68 gate.** The corpus (both typing habits) and the three sets are fixtures of the engine package with the
   output of the engine of 15/11/2026 frozen; CI fails on any wrong revision, on any change of a word that is not a
   collision, below the ENG-R876 floors (and below 98.8 % on the Vietnamese side with the tone typed after the
   vowel, that habit's measured share), and on any difference from the frozen outputs, so a list change that moves a
   number updates the fixtures and is reviewed with the list (QA-R6). The corpus only meets RV1 with one older
   token (L9b restores a word that continues a phrase at its own commit), so a separate case pins RV1 with two older
   tokens after the memory keeps a word inside a phrase (`more or less` with `or` learned as `ỏ`). A memory simulation checks ENG-R877 with a
   reference model written from the text of ENG-R863 (`ReferenceCollisionMemory` in VietnameseEngineTesting); the
   host's store must give the same votes for the same signals (parity test of W11-B).

## Measured results

Engine of main 58c494a with the bundled data, Telex, defaults, replayed in host mode (Return and Tab end the
composition with a reset, Escape is the restore binding), by `CollisionCorpusTests`. The research replay kit gives
the same numbers to the token.

| Corpus | English intent | Vietnamese intent | Revisions (wrong) | Non-collision words changed | Exact sentences | Hidden collisions intact |
|---|---|---|---|---|---|---|
| Tone at the end, collision rules on | 76.1 % (548 / 720) | 99.5 % (620 / 623) | 98 (0) | 0 | 1,000 / 1,206 | 230 / 230 |
| Tone after the vowel, collision rules on | 76.1 % (548 / 720) | 98.8 % (501 / 507) | 96 (0) | 0 | 997 / 1,206 | 231 / 231 |
| Tone at the end, collision rules off | 58.5 % (421 / 720) | 94.5 % (589 / 623) | 0 | - | 876 / 1,206 | 230 / 230 |

The tone-after-vowel file has fewer Vietnamese-intent collisions because some words collide in one habit only.
ENG-R876 states its 99 % floor for the habit 13.11 measures first; the other habit is held at its measured 98.8 % by
the frozen outputs. Per 1,000 words: 8.8 revisions. By position (English, tone at the end, off then on): line start
24.6 % to 71.9 %, after a Vietnamese word 42.9 % to 53.0 %, after one English word 62.5 % to 85.3 %, inside a listed
phrase 44.2 % to 93.7 %. Deciding rule of the 1,343 collisions (right / wrong): L9a 33 / 0, L9b 83 / 0, L10 165 / 3,
L11 675 / 142, L6 and L7 0 / 30, L8 114 / 0, RV1 77 / 0, RV2 1 / 0, RV3 8 / 0, RV4 12 / 0.

| Set | English intent | Vietnamese intent | Revisions (wrong) | Exact lines |
|---|---|---|---|---|
| Adversarial, 57 lines | 98.6 % (71 / 72) | 100 % (24 / 24) | 15 (0) | 56 |
| Stress, 42 lines | 92.5 % (37 / 40) | 96.4 % (27 / 28) | 11 (0) | 38 |
| Held-out, 81 lines | 93.1 % (95 / 102) | 90.9 % (30 / 33) | 21 (0) | 72 |

The Vietnamese prose corpus (250,000 words, ENG-R873) shows no change and no revision with the rules on
(`ProseCorpusGateTests.collisionRulesLeaveProseUnchanged`).

Memory simulation (`CollisionMemorySimulationTests`, corpus with the tone at the end, five shuffled passes, the
snapshot rebuilt after every sentence because each ends with Return). A user who corrects every error does it
through the engine: Backspace, Escape and the boundary key again right after the commit; Escape on the active word
before Return; Escape right after a revising commit.

| User | Pass 1 (EN / VI) | Pass 2 | Pass 3 | Pass 4 | Pass 5 | Memory decisions right / wrong | Entries (voting) |
|---|---|---|---|---|---|---|---|
| corrects every error | 79.7 / 98.6 | 87.4 / 98.7 | 92.2 / 98.4 | 91.9 / 99.4 | 91.5 / 98.9 | 1,158 / 57 | 638 (131) |
| never corrects (three passes) | 76.1 / 99.5 | 76.1 / 99.5 | 76.1 / 99.5 | | | 0 / 0 | 638 (0) |

Hidden Vietnamese words with collision keys outside the lexicon (`có` typed `cos`): 6 damaged over the five passes,
each repaired by the user's next correction. Held-out (four passes on half A, then half B with the memory frozen):
without memory 74.0 % / 99.7 % (325 of 326 Vietnamese-intent words), with it 80.4 % / 98.2 % (320 of 326; memory
decisions 37 right, 4 wrong). The research simulation, which computed contexts itself instead of reading the
engine's signals, measured 81.3 % / 98.5 %.

The `CollisionCorpusTests` target runs in about 8 seconds on an Apple silicon Mac in a debug build (the corpus
replays take about 3.5 s, the memory simulation about 8 s, in parallel), after the build.

## Known failures

- 142 English words kept Vietnamese by L11, mostly loanwords and tech words in Vietnamese sentences with a `vi` row
  (`xe bus`, `cái box`, `mấy cái tips`, `reset lại`, `vest`, `toast`); only a review of the ambiguity table or the
  memory fixes them.
- English function words with no clue yet: at a line start before a content word (`These tests`, `Has anyone`), or
  after a Vietnamese word (`ít format` for `its`).
- 30 words that L6 or L7 keep because their keys are not English words: 27 outside the English lexicon (`docs`,
  `gif`, `max`, `DDoS`, `NestJS`) and 3 Tier B spellings. Adding the first group to the lexicon damages Vietnamese
  words, so only the memory can learn them.
- 3 Vietnamese words after a strong English run (`unit test cases sẽ xong`).
- Costs of the guards: `Thank you bên mình` stays `been` (pre-guard), `Welcome back cả team` stays `car` (the next
  word is English), `easy as pie` stays `á`.

## Rejected alternatives

- **Per-word boundary rows for more particles** (`has`, `did`, `theres`, `w` kept Vietnamese before `.`, `!`, `?`):
  turns real English replies into Vietnamese (`Yes she has.` gives `há`, `Yes he did.` gives `đi`). Only `as` is on
  the list.
- **The sandwich route** (a particle reading between two English words taken as English, `bug á fix` gives `as`)
  and a line-start allowance (`Has anyone` gives `Has`, but also `Á yes` gives `As`): 0.2 English points on the
  corpus and new wrong revisions on the small sets.
- **Hashed neighbour words in the memory** (keying entries by a hash of the previous word): on held-out sentences 2.2
  English points more but 1.0 Vietnamese point less, and it stores a derivative of typed text. Keying by the
  previous word itself (83.5 % / 97.5 % held out) stores typed content outright.
- **A lexicon supplement instead of the collision list** (adding `cos`, `gif`, `docs` to the English lexicon so that
  the rules restore them): damages 24 Vietnamese words (`có`, `gì`, `đó`) on the corpus. The supplement keys only the
  memory and never restores by rule.
- **The nearest-word window** (deciding the run from the nearest word instead of the three-word window): 77.4 % /
  97.8 % with 110 revisions, 1.7 Vietnamese points lost for 1.3 English points.
- **Silent acceptance that votes on its own**: drifts to 74.7 % / 100 % with 422 wrong memory decisions; a user who
  never corrects must get exactly the rules' output (ENG-R877).
- **An ungated Vietnamese-content revision and an English-function-word revision of particles**: revise inside
  English noun phrases (`I parked the car rồi` gives `cả`, `Have you been ở` gives `bên`) and on Vietnamese particles
  (`Ngon á but mắc` gives `as`).

## Simulator caveat

The research simulator checked the boundary particle before the phrase, while the engine lets a phrase win over L9a
since 15/11/2026 (`such as.` stays English, ENG-R825). None of the corpora has a phrase-final `as` before `.`, `!` or
`?`, so the simulator's numbers and the engine's agree; the fixtures are the engine's output, so a sentence of that
shape added later is scored by the engine's order.

## Open question: the held-out floor of ENG-R877

ENG-R877 allows the memory to lower Vietnamese-intent accuracy on held-out sentences by at most 1.5 points. Measured
with the engine and the reference model: 99.7 % to 98.2 %, 1.53 points (325 to 320 of 326 words). Four loanwords are
meant as English in half A and as Vietnamese in the same context class in half B: `tips`, `cans` and `tee` after a
Vietnamese word, `teen` after a neutral one (`típ`, `cán`, `tê`, `tên`); the fifth word is an English-run restore
(L10) after a word the memory learned as English at the start of a sentence. A stricter vote for English after a Vietnamese word (a score of 3 or 4 instead of 2) does
not change the result: the training user keeps correcting the same words until the memory follows. Reading the
first condition of ENG-R863 as a conflict as soon as one side reaches the score but misses the ratio does not change
it either (still 320 of 326), while it contradicts the worked cases of the text (six corrections against two give
the six). "Held out" means half B of the corpus here, not `set-held-out.tsv`. The gate holds
the loss at the measured five words (a larger loss fails) and records the 1.5-point floor as a known issue until the
product owner chooses: widen the floor to 2 points, accept the loss for these loanwords, or decide those rows of the
ambiguity table so that the memory has less to learn.

## Consequences

- CI runs the gate as its own step on Linux for every pull request and again inside the macOS engine coverage run;
  `scripts/run-tests.sh` has a `collision` layer.
- A change of a bundled collision list or of a rule that moves a fixture output updates the fixture in the same pull
  request, with the `corpus-change` label and every changed sentence reviewed (`Fixtures/README.txt` explains the
  record mode).
- The host's memory store (W11-B) must pass a parity test against `ReferenceCollisionMemory` and the worked cases of
  `CollisionMemoryVoteCases`, so the simulated numbers hold for the shipped memory.

## Amendment, 2026-11-18: the held-out floor of ENG-R877

Settled by the integrator under the product owner's delegation of 18/11/2026
([0009](0009-pa-decisions-2026-11-18.md), "Integrator's calls"). Of the three options of the open question, the
second is taken: the loss of 1.53 points against the 1.5-point floor is accepted for the five pinned cases (`tips`,
`cans` and `tee` after a Vietnamese word, `teen` after a neutral one, and the L10 restore after a word the memory
learned as English at the start of a sentence) as known costs, until the review of the ambiguity table and the
phrase list (parked in 0009). The floor of ENG-R877 is not widened, and the gate keeps holding the loss at those
five words, so any further loss still fails. Reason: each case is a loanword that one user means as English and
another as Vietnamese in the same context, which a per-user memory cannot tell apart from the training user's
corrections; widening the floor would hide a sixth case, and deciding the rows of the ambiguity table belongs to
that review. The requirement text of ENG-R877 in `spec/01-engine.md` section 8.8 is the engine track's to annotate.
