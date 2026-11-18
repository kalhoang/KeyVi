# data/: pinned inputs and build of the bundled word lists

The engine's bundled resources (spec/01-engine.md 8.2) are built by `lexicon-builder` from the pinned inputs
in this directory. The output is byte-reproducible (ENG-R810) and lands in
`Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources/`, where `Resources.bundled(...)` loads it.
Sources, licences and the reasoning behind every choice: `docs/decisions/0200-data-sources-and-licences.md`
and `docs/decisions/0201-bundled-resource-format-and-build-policy.md`. Notices: `data/NOTICES.md`.

Licence: what the project wrote here is under the Mozilla Public License 2.0, like the engine (`LICENSE`, the
verbatim text; the copyright line and the MPL-2.0 Exhibit A notice are in `NOTICE`). The SCOWL lists and the
legal texts keep their own terms (`NOTICES.md`).

## Layout

| Path | Contents | Edited by |
|---|---|---|
| `inputs/MANIFEST.sha256` | SHA-256 of every file under `inputs/` and `licenses/` (shasum format, paths relative to `data/`) | `lexicon-builder pin` |
| `inputs/english/SOURCES.tsv` | SCOWL archive URL, SHA-256, size, retrieval date | hand |
| `inputs/english/scowl-2020.12.07/` | the 12 SCOWL component lists used (ISO-8859-1, verbatim from the archive) | `lexicon-builder import scowl` |
| `inputs/legal/SOURCES.tsv` | legal documents: id, cache file, URL, raw SHA-256 and size, retrieval date, title, number, issuing date, issuer, official page | hand |
| `inputs/legal/<id>.txt` | extracted UTF-8 NFC text of each document | `lexicon-builder import legal` |
| `inputs/tech-always.txt` | words that always stay as typed (rule L11) | hand, reviewed by Pa |
| `inputs/tech-code-only.txt` | shell commands and flags, restored only in the code context (rule L9) | hand, reviewed by Pa |
| `inputs/tech-code-capitalized.txt` | code-only words that rule L9 still restores in sentence case at a line start (`host`; ENG-R850); every entry must be on `tech-code-only.txt` | hand, decided by Pa |
| `inputs/attested-additions.txt` | `syllable<TAB>reason` added to the attested list | hand, reviewed by Pa |
| `inputs/ambiguity.tsv` | `raw  decision  status  display  run  viKind  note` (ENG-R821, ENG-R827) | hand / `ambiguity-candidates --merge` |
| `inputs/phrases.txt`, `inputs/collision-supplement.txt`, `inputs/boundary-particles.txt`, `inputs/english-function-words.txt`, `inputs/english-lean-neutral.txt`, `inputs/vi-tail-words.txt`, `inputs/english-pre-guard.txt` | the collision lists (spec/01-engine.md 8.2, ENG-R825 to ENG-R828, ENG-R863); each file's header says what it is for | hand, reviewed by Pa |
| `licenses/` | SCOWL `Copyright` and `README` (verbatim) and `bundled-notices.txt`, the template of `NOTICES.txt` | import / hand |
| `derived/attested-candidates.tsv` | every legal-text token with its count, before the validity filter | `lexicon-builder build` |
| `derived/ambiguity-candidates.tsv` | output of `ambiguity-candidates`, committed as Pa's review list (not checked by `check`) | `lexicon-builder ambiguity-candidates` |
| `corpus/prose-vi.txt` | prose corpus for ENG-T20 (250,000 tokens) | `lexicon-builder prose-corpus` |
| `cache/` | raw downloads (gitignored) | `data/fetch.sh` |
| `fetch.sh` | downloads every source into `cache/` and verifies its SHA-256 | |

## Commands

Build the tool once (any scratch path works; several builds may share the package):

```sh
cd Packages/VietnameseEngine
swift build --product lexicon-builder
BUILDER="$(swift build --product lexicon-builder --show-bin-path)/lexicon-builder"
cd ../..   # run the commands from the repository root (or pass --data-root data)
```

| Command | What it does |
|---|---|
| `"$BUILDER" build` | Verifies the inputs against `MANIFEST.sha256`, writes `english.txt`, `tech-always.txt`, `tech-code-only.txt`, `tech-code-capitalized.txt`, `attested.txt`, `ambiguity.tsv`, the eight collision lists (`phrases.txt`, `collision-supplement.txt`, `boundary-particles.txt`, `english-function-words.txt`, `english-lean-neutral.txt`, `vi-tail-words.txt`, `vi-tail-particles.txt`, `english-pre-guard.txt`), `NOTICES.txt`, `manifest.json` into the package resources and `data/derived/attested-candidates.tsv`. `--output DIR` writes `DIR/Resources` and `DIR/derived` instead. It fails when a phrase's Vietnamese reading occurs in `data/corpus/prose-vi.txt`, when a capitalized code word is not on `tech-code-only.txt`, or when a collision-supplement word does not type as its listed display, the display is not attested, or the word is English. |
| `"$BUILDER" check` | CI gate: verifies the pins, rebuilds everything in memory (resources, `derived/`, prose corpus) and fails if any committed file differs. |
| `"$BUILDER" prose-corpus` | Writes `data/corpus/prose-vi.txt`. `--min-tokens N` (default 250000), `--output FILE` or `-`. |
| `"$BUILDER" ambiguity-candidates` | ENG-R820: types every English and tech word through the engine (Telex defaults, traditional and modern style; words with a digit also in VNI) and writes the words whose display is a Tier A syllable to `data/derived/ambiguity-candidates.tsv`, most frequent first, with the columns `raw method traditional modern attested source corpus_count merge_as current_row`. Words whose display is not attested are listed too, because rule L8 restores them (docs/decisions/0202). `--merge` adds each candidate without a row as `merge_as` says: `en`/`proposed` for English words with an unattested display and for tech-always words (in the last block, `# [generated en rows]`, with a `[generated:unattested]` or `[generated:tech-always]` token in the note), `vi`/`unreviewed` otherwise (before that block). `build` and `check` fail when a generated row's reason no longer holds. `--fake-engine FILE` (tests) replaces the engine with a `raw  traditional  modern  validity  [telex\|vni]` table; `--output FILE` or `-`. |
| `"$BUILDER" pin` | Rewrites `inputs/MANIFEST.sha256` from the files on disk. Run after a reviewed change of any input. |
| `"$BUILDER" import scowl` | Extracts the 12 SCOWL lists, `Copyright` and `README` from the verified archive in `cache/`, then pins. |
| `"$BUILDER" import legal` | Converts every verified `.doc` in `cache/legal/` with macOS `textutil`, normalises (NFC, `Ð` to `Đ`, line ends, spaces) into `inputs/legal/<id>.txt`, then pins. macOS only. |
| `"$BUILDER" tokenize [--prose]` | Prints the tokens of standard input, one per line (attested tokeniser, or the case-keeping prose tokeniser). |
| `data/fetch.sh [--verify-only] [--force]` | Downloads every row of both `SOURCES.tsv` files into `cache/` and checks the pinned SHA-256; a mismatch is kept as `*.mismatch` and fails. |

Global options: `--data-root DIR` (default: the `data/` found above the working directory) and
`--resources DIR` (default: the package resource directory).

Verify the pins without the tool: `cd data && shasum -a 256 -c inputs/MANIFEST.sha256`.

## Workflows

**Edit a hand list** (tech lists, additions, ambiguity table): edit, then `pin`, `build`, run the engine
tests, commit inputs, manifest and resources together. `check` in CI fails if one of them is missing.

**Refresh from upstream**: `data/fetch.sh --force`; on a checksum change, inspect the new file, update the
row in `SOURCES.tsv` (sha256, bytes, retrieved), `import scowl|legal`, `build`, `prose-corpus`, review the
diff, commit.

**After a change that moves candidates** (lexicon, tech lists, additions, an engine change that alters a
display): `build`, then `ambiguity-candidates --merge`, `pin`, `build`, `ambiguity-candidates` (refreshes the
`current_row` column), review and commit. The merge never edits an existing row: to re-decide a generated row
by the merge policy, delete it first; `build` names the generated rows to delete after attesting a syllable
or editing a list they depend on. Pa reviews at least the 300 most frequent candidate rows (ENG-R821).
Done for the engine merge on 2026-11-13 (docs/decisions/0202).

**Check the gates** after any data change: `swift test --filter VietnameseEngineDataTests` in
`Packages/VietnameseEngine` runs the spec 8.8 targets on the bundled data (ENG-R870 generated corpus, ENG-T10
English corpus with `Tests/VietnameseEngineTests/Corpus/known-exceptions.txt`, ENG-T20 over
`data/corpus/prose-vi.txt`, ENG-R1231 load budget) and prints every changed word with its rule.

**Add a legal document**: put the official `.doc` URL in `inputs/legal/SOURCES.tsv` (id, cache file
`legal/<id>.doc`, URL, SHA-256, size, date, title, number, issuing date, issuer, official page),
`data/fetch.sh`, `import legal`, `build`, `prose-corpus`. Only legal normative or administrative documents
(Law on Intellectual Property, Article 15(2)); never other Vietnamese text.

## Decisions of the product owner (13/11/2026)

Recorded in `docs/decisions/0005-pa-decisions-2026-11-13.md` (Q25 to Q34); the inputs carry the same notes.

| Topic | Decision | Where in the data |
|---|---|---|
| VNI `co2` | Vietnamese: it types `cò` (con cò, cò kè). Whoever needs CO2 types the escape `co22`. | removed from `inputs/tech-always.txt` (comment next to `a3`/`a5`) and its generated `en` row from `inputs/ambiguity.tsv`; `cò` was already attested |
| `chơn` | Attested (tay chơn, chơn chất, Chơn Thành). Behaviour is unchanged: Telex `chown` is a code-only word, not English, so rule L7 already kept `chơn` outside the code context; it stays an ENG-T11 entry. Since the product owner's decision of 18/11/2026 (REG-38) rule L9 restores `chown` in the code context outside Vietnamese text, as it restores `tar`. | `inputs/attested-additions.txt` |
| VNI `a3`, `a5`, `a4` | Kept: `a3` types `ả`, `a5` types `ạ`, `a4` stays as typed. | `inputs/tech-always.txt` |
| Generated `en` rows | Accepted: rows that restate rule L8 or the tech-always list count as `en` rows for ENG-R870 (spec 8.8 amended). | `inputs/ambiguity.tsv`, block `# [generated en rows]` |
| ENG-T11 entries: 53 in total (50 L4 escapes that leave English words, 1 L6 `awk`, 2 L7 `chown` and `ef`) | Accepted as known issues on 13/11/2026. | `known-exceptions.txt` of the engine tests |
| SCOWL size level | Keep level 35. | `inputs/english/` |
| Attested sources | Keep the legal texts plus reviewed additions. | `inputs/legal/`, `inputs/attested-additions.txt` |
| Review of the word lists | Later; unreviewed rows behave as `vi` (ENG-R821). Short English words missing from level 35 (`max`) need no change: Telex `max` gives `mã`, the reading the ENG-R821 row wants. | `inputs/ambiguity.tsv`, `derived/ambiguity-candidates.tsv` |

## Resource format 2

- Word lists: UTF-8, LF, one entry per line, final newline, no blank lines or comments, unique, sorted by
  UTF-8 bytes. English `a-z` (one-letter entries only `a` and `i`); tech lists `a-z0-9` with a letter;
  attested lowercase NFC Vietnamese letters.
- `ambiguity.tsv`: header `raw  decision  status  display  run  viKind  note`, tab-separated; `proposed` and
  `reviewed` rows apply their decision, `unreviewed` rows behave as `vi`; `run` is `en` or `vi` (`vi`: rule L10
  never restores the word), `viKind` is `particle`, `function` or `content`.
- Collision lists: `phrases.txt` holds 2 to 4 lowercase words `a-z` separated by one space; the other lists hold
  one lowercase word per line (ASCII for the English lists and the supplement, NFC Vietnamese letters for
  `vi-tail-words.txt` and `vi-tail-particles.txt`), sorted by UTF-8 bytes. Format 1 is no longer loaded.
- `manifest.json`: `format`, `inputsSHA256`, `files[]` (`name`, `bytes`, `entries`, `sha256`), `stats`. The
  loader rejects a file whose size, entry count or SHA-256 differs.
- `NOTICES.txt`: built from `licenses/bundled-notices.txt`; `@include <file>` lines are replaced by the
  named file from `licenses/`. The host shows it in its acknowledgements (`Resources.bundledNotices()`,
  ENG-R811).
