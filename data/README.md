# data/: pinned inputs and build of the bundled word lists

The engine's bundled resources (spec/01-engine.md 8.2) are built by `lexicon-builder` from the pinned inputs
in this directory. The output is byte-reproducible (ENG-R810) and lands in
`Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources/`, where `Resources.bundled(...)` loads it.
Sources, licences and the reasoning behind every choice: `docs/decisions/0200-data-sources-and-licences.md`
and `docs/decisions/0201-bundled-resource-format-and-build-policy.md`. Notices: `data/NOTICES.md`.

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
| `inputs/attested-additions.txt` | `syllable<TAB>reason` added to the attested list | hand, reviewed by Pa |
| `inputs/ambiguity.tsv` | `raw  decision  status  display  note` (ENG-R821) | hand / `ambiguity-candidates --merge` |
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
| `"$BUILDER" build` | Verifies the inputs against `MANIFEST.sha256`, writes `english.txt`, `tech-always.txt`, `tech-code-only.txt`, `attested.txt`, `ambiguity.tsv`, `NOTICES.txt`, `manifest.json` into the package resources and `data/derived/attested-candidates.tsv`. `--output DIR` writes `DIR/Resources` and `DIR/derived` instead. |
| `"$BUILDER" check` | CI gate: verifies the pins, rebuilds everything in memory (resources, `derived/`, prose corpus) and fails if any committed file differs. |
| `"$BUILDER" prose-corpus` | Writes `data/corpus/prose-vi.txt`. `--min-tokens N` (default 250000), `--output FILE` or `-`. |
| `"$BUILDER" ambiguity-candidates` | ENG-R820: types every English and tech word through the engine (Telex defaults, traditional and modern style; words with a digit also in VNI) and writes the words whose display is a Tier A syllable to `data/derived/ambiguity-candidates.tsv`, most frequent first, with the columns `raw method traditional modern attested source corpus_count merge_as current_row`. Words whose display is not attested are listed too, because rule L8 restores them (docs/decisions/0202). `--merge` appends each candidate without a row as `merge_as` says: `en`/`proposed` for English words with an unattested display and for tech-always words, `vi`/`unreviewed` otherwise. `--fake-engine FILE` (tests) replaces the engine with a `raw  traditional  modern  validity  [telex\|vni]` table; `--output FILE` or `-`. |
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
by the merge policy, delete it first. Pa reviews at least the 300 most frequent candidate rows (ENG-R821).
Done for the engine merge on 2026-11-13 (docs/decisions/0202).

**Check the gates** after any data change: `swift test --filter VietnameseEngineDataTests` in
`Packages/VietnameseEngine` runs the spec 8.8 targets on the bundled data (ENG-R870 generated corpus, ENG-T10
English corpus with `Tests/VietnameseEngineTests/Corpus/known-exceptions.txt`, ENG-T20 over
`data/corpus/prose-vi.txt`, ENG-R1231 load budget) and prints every changed word with its rule.

**Add a legal document**: put the official `.doc` URL in `inputs/legal/SOURCES.tsv` (id, cache file
`legal/<id>.doc`, URL, SHA-256, size, date, title, number, issuing date, issuer, official page),
`data/fetch.sh`, `import legal`, `build`, `prose-corpus`. Only legal normative or administrative documents
(Law on Intellectual Property, Article 15(2)); never other Vietnamese text.

## Resource format 1

- Word lists: UTF-8, LF, one entry per line, final newline, no blank lines or comments, unique, sorted by
  UTF-8 bytes. English `a-z` (one-letter entries only `a` and `i`); tech lists `a-z0-9` with a letter;
  attested lowercase NFC Vietnamese letters.
- `ambiguity.tsv`: header `raw  decision  status  display  note`, tab-separated; `proposed` and `reviewed`
  rows apply their decision, `unreviewed` rows behave as `vi`.
- `manifest.json`: `format`, `inputsSHA256`, `files[]` (`name`, `bytes`, `entries`, `sha256`), `stats`. The
  loader rejects a file whose size, entry count or SHA-256 differs.
- `NOTICES.txt`: built from `licenses/bundled-notices.txt`; `@include <file>` lines are replaced by the
  named file from `licenses/`. The host shows it in its acknowledgements (`Resources.bundledNotices()`,
  ENG-R811).
