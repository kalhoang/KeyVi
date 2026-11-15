SPDX-License-Identifier: MPL-2.0

W11 collision fixtures of the QA-R68 gate (spec/04-quality-release.md QA-R68, spec/01-engine.md 13.11, ENG-R876,
ENG-R877). Test data only; nothing here ships in the app.

Files
  corpus-tone-last.tsv          1,206 sentences of chat, office, developer and control text, tone key typed at the
                                end of each word (11,180 words, 720 English-intent and 623 Vietnamese-intent
                                collisions)
  corpus-tone-after-vowel.tsv   the same sentences, tone key typed right after its vowel (720 and 507 collisions:
                                some words are collisions in one habit only)
  set-adversarial.tsv           57 lines written to break the precision-first rule set
  set-stress.tsv                42 lines written to break the accuracy-first rule set
  set-held-out.tsv              81 lines written before the final rules were run (held out)

Provenance
  Every sentence was written for this project during the W11 collision research (13/11 to 15/11/2026): the
  corpus by the research workstream from the product owner's own examples (ids PA..) plus project-written chat,
  office, developer and control sentences; the three sets by the design and review workstreams of that research.
  No sentence comes from another input method, a third-party corpus or a web page. Licence: MPL-2.0, as the
  engine package.
  The expected outputs were generated once, on 15/11/2026, by replaying every line through the engine of main
  58c494a in host mode with the research replay kit (a Swift replay over `Session` plus scoring scripts, kept
  outside the repository) and checked against the kit's numbers (13.11). 75 lines were then reviewed by hand
  (30 random corpus lines, 20 corpus lines with a revision, 10 lines of the tone-after-vowel file, 5 lines of each
  set): every label is right and every output follows the rules of spec 8.1 and ENG-R828, including the known
  failures listed in docs/decisions/0008-collision-learning.md. Then the files were frozen.

Format (tab-separated, one sentence per line, lines starting with # are comments)
  id        sentence id (PA, CS, EN, VI for the corpus; ADV, STR, HLD for the sets)
  group     mixed, pure-vi or pure-en for the corpus, set for the sets
  half      A or B: the fixed split of the held-out memory test of ENG-R877 (drawn once with a seeded generator);
            - for the sets
  keys      the keys typed; {RET} is Return (the replay also reads {TAB}, {ESC} and {BS})
  expected  the field after the replay, {RET} for a line break
  revised   the words the next word revised (ENG-R828) as index:reason (phrase, particleTail, nextEnglish,
            nextVietnamese), comma separated, or -
  tokens    one item per word of the field (a run of letters), separated by single spaces:
              word                          not scored as a collision
              word/H                        a Vietnamese word whose keys are a collision outside the English
                                            lexicon (`cos` for `có`): no rule may change it, a learned vote could
              word/E|V/category/positions   a collision meant as English (E) or Vietnamese (V), its category
                                            (table-vi, table-en, enkeys-row-vi, unattested, nonlex, tierB-kept;
                                            set for the sets) and its position tags, comma separated, or -
            `word` is always the intended word.

Updating
  The gate fails when the replay differs from `expected` or `revised` (QA-R6: a corpus case changes its expected
  output only with the corpus-change label and the reason in the pull request). To review a change that moves the
  numbers, for example an edit of a bundled collision list:
    COLLISION_CORPUS_RECORD=/tmp/collision-fixtures swift test --package-path Packages/VietnameseEngine \
      --filter CollisionCorpusTests
  writes every fixture with the new expected and revised columns to that directory; diff it against this one,
  review every changed sentence with the list change, then copy the files here. Never regenerate the labels or the
  intended words: they are the research's hand judgements and only a reviewed correction may change one.
  A change that moves the numbers of 13.11 also updates, in the same pull request, the counts the tests state on
  their own: CollisionCorpusTests.swift (1,206 sentences, 720 and 623 collisions, 507 for the tone after the
  vowel and its floor, the baseline 421, 589 and 876), CollisionMemorySimulationTests.swift (the measured
  held-out loss), spec/01-engine.md 13.11, docs/decisions/0008-collision-learning.md and the ENG-R876 and QA-R68
  rows of docs/architecture/traceability.md and Packages/VietnameseEngine/TRACEABILITY.md.
