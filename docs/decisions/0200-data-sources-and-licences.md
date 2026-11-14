# 0200. Data sources and licences for the bundled word lists

- Status: accepted (engine-data track), 2026-11-13. Pa may override any choice below with a new record.
- Requirements: spec/01-engine.md 8.2 (ENG-R810 to ENG-R812), 8.3 (ENG-R820, ENG-R821), 12.4 (ENG-R1231),
  13.4 (ENG-T20); spec/05-clean-room.md CLR-R6.
- Inputs and pins: `data/inputs/` (checksums in `data/inputs/MANIFEST.sha256`), raw download pins in
  `data/inputs/english/SOURCES.tsv` and `data/inputs/legal/SOURCES.tsv`.

## 1. English lexicon: SCOWL 2020.12.07, levels 10, 20 and 35

**Choice.** SCOWL (Spell Checker Oriented Word Lists) by Kevin Atkinson, release 2020.12.07, the latest
release of the classic SCOWL format, from the project's official SourceForge download area:
`https://downloads.sourceforge.net/project/wordlist/SCOWL/2020.12.07/scowl-2020.12.07.tar.gz`,
SHA-256 `5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc` (2,569,810 bytes, retrieved
2026-11-13). The newer en-wl/wordlist `rel-2026.02.25` release only ships speller dictionaries (aspell,
hunspell) built from the new database (ESDB, "SCOWLv2"); the classic per-level lists are what this build
needs and are reproducible from the archive above.

**Selection.** The `words` lists of the categories `english`, `american`, `british` and `british_z`
(British -ize) at size levels 10, 20 and 35: 12 files, imported verbatim (ISO-8859-1) into
`data/inputs/english/scowl-2020.12.07/`. The build lowercases each entry and keeps only entries made of
the ASCII letters `a`-`z` (apostrophes, accented words and anything else are dropped), then deduplicates:
**40,206 words**. Excluded on purpose: `variant_1..3` lists (less common spellings, more collisions with
Telex), proper names, abbreviations, contractions, upper-case lists, levels above 35. Spec 8.2 says
"VERIFY final level by measuring collisions": the measurement needs the real engine
(`lexicon-builder ambiguity-candidates`, ENG-R820) and is pending until the engine track's composition is
merged; level 35 is the spec's proposal and the standard "small" SCOWL size.

**Licence.** The SCOWL `Copyright` file is reproduced verbatim in
`data/licenses/SCOWL-2020.12.07-Copyright.txt` and in the shipped `NOTICES.txt` (ENG-R811). Its main
grant:

> "Permission to use, copy, modify, distribute and sell these word lists, the associated scripts, the
> output created from the scripts, and its documentation for any purpose is hereby granted without fee,
> provided that the above copyright notice appears in all copies and that both that copyright notice and
> this permission notice appear in supporting documentation."

Sources of the levels used, from the same file:

> "The 10 level includes the 1000 most common English words (according to the Moby (TM) Words II
> [MWords] package), a subset of the 1000 most common words on the Internet (again, according to Moby
> Words II), and frequently class 16 from Brian Kelk's "UK English Wordlist with Frequency
> Classification"." (Moby: "placed in the public domain"; Kelk's list: "also in the Public Domain".)
>
> "The 20 level includes frequency classes 7-15 from Brian's word list."
>
> "The 35 level includes frequency classes 2-6 and words appearing in at least 11 of 12 dictionaries as
> indicated in the 12Dicts package. All words from the 12Dicts package have had likely inflections added
> via my inflection database." ... "The 12Dicts package and Supplement is in the Public Domain."

The inflection database used WordNet (Princeton licence, permissive, notice required) and the
American/British split used VarCon (permissive notice) and Ispell word lists (BSD-style, notice required
in documentation of binary redistributions). All of these notices are inside the reproduced `Copyright`
file, so shipping that file in `NOTICES.txt` and the app's acknowledgements satisfies them.

**COCA / NDA (the spec's VERIFY).** Findings:

1. The NDA wording is in the copyright file of the *new* database (ESDB, previously "SCOWLv2", en-wl/wordlist
   `master`), not in the 2020.12.07 release used here:
   > "Data from the Corpus of Contemporary American English (COCA) was also used. All data from COCA comes
   > from 3-gram data that is not freely available; however, the usage is within the rights given by the
   > NDA that was signed when purchasing the data."
2. The 2020.12.07 release used COCA only as a frequency signal to pick extra words. Its `README` change
   log, "From Version 2015.04.24 to 2015.05.18": "Added some new words found to have a high frequency in
   the COCA corpus. (http://corpus.byu.edu/coca/)." Its `Copyright` file does not mention COCA or an NDA,
   and its `README` notes that using COCA frequency data "will require permission".
3. What is redistributed is a list of single common English words: no COCA text, n-grams or frequency
   values. Single words are facts, not protected expression; the selection is Kevin Atkinson's compilation,
   which the author licenses for redistribution with the notice above, and the author states that the COCA
   use is within the NDA. An NDA binds its signatory, not downstream users of the published lists.

**Conclusion:** levels 10 to 35 of SCOWL 2020.12.07 are redistributable under the SCOWL notice. Residual
risk is low and contractual only (between the SCOWL author and the COCA vendor). If Pa wants zero COCA
influence, the documented fallback is 12dicts (Alan Beale, public domain; `2of12inf` or `3esl`), which needs
only a new importer and a re-pin.

**Rejected:** wordfreq (CC BY-SA 4.0), google-10000-english (LDC-derived, licence advises against commercial
use), hunspell-vi / Aspell Vietnamese (GPL), Wiktionary (CC BY-SA) and any input method's data
(spec/01-engine.md 8.2, CLR-R6).

## 2. Attested syllables and prose corpus: Vietnamese legal normative documents

**Legal basis.** Law on Intellectual Property No. 50/2005/QH11, Article 15, quoted from the official
consolidated text 11/VBHN-VPQH of 8 July 2022 (Office of the National Assembly), downloaded from the portal
of the Intellectual Property Office of Viet Nam (`ip-law` row of `data/inputs/legal/SOURCES.tsv`) and
committed as `data/inputs/legal/ip-law.txt`:

> "Điều 15. Các đối tượng không thuộc phạm vi bảo hộ quyền tác giả
> 1. Tin tức thời sự thuần tuý đưa tin.
> 2. Văn bản quy phạm pháp luật, văn bản hành chính, văn bản khác thuộc lĩnh vực tư pháp và bản dịch
> chính thức của văn bản đó.
> 3. Quy trình, hệ thống, phương pháp hoạt động, khái niệm, nguyên lý, số liệu."

Translation: "Article 15. Objects not protected as copyright: ... 2. Legal normative documents,
administrative documents, other documents in the judicial domain and their official translations."
Cross-check: the later consolidated text 155/VBHN-VPQH (2025), published on the Government portal at
`https://datafiles.chinhphu.vn/cpp/files/vbpq/2025/9/155-vbhn-vpqh.pdf`, has the same wording for
clauses 1 and 2 (checked 2026-11-13), so the exclusion is current law after the 2025 amendment. Codes and laws
passed by the National Assembly are legal normative documents; a consolidated text (văn bản hợp nhất) is an
official document of the Office of the National Assembly that only merges such laws, so it is covered by the
same clause (administrative/official document of the legal domain). Wikimedia Commons applies the same
article to host Vietnamese laws as public domain.

**Documents.** 13 laws and codes (Penal Code 2015, Criminal Procedure Code 2015, Civil Procedure Code 2015,
Labour Code 2019, Law on Intellectual Property (consolidated 2022), Commercial Law 2005, Law on Enterprises
2014, Law on Information Technology 2006, Law on Science and Technology 2013, Publishing Law 2012,
Competition Law 2018, Law on Technology Transfer 2017, Law on Handling of Administrative Violations 2012).
Sources: static Word (.doc) files linked from `https://www.ipvietnam.gov.vn/bo-luat-luat` (Intellectual
Property Office, a government agency) and, for the Labour Code, from the Official Gazette
(`congbao.chinhphu.vn`, Government Office). `SOURCES.tsv` records title, number, issuing date, issuer, URL,
raw SHA-256 and size, and retrieval date for each. `data/fetch.sh` re-downloads and verifies every file
(all 14 sources re-downloaded with matching SHA-256 on 2026-11-13).

**Why these and not others.**
- `vbpl.vn` (national legal database) serves dynamic HTML whose bytes change on every request (view counters,
  anti-bot tokens), so a raw SHA-256 pin is impossible; it also blocks scripted clients.
- PDF-only documents (Constitution 2013, Civil Code 2015, Law on Education 2019 as published) extract with
  split syllables (`Điề u`), which would pollute the token data. The Constitution and the Civil Code are
  therefore not included; the 13 documents above give 673,599 tokens, far above the 250,000 target.

**Extraction.** macOS `textutil` converts each .doc to UTF-8 text; `lexicon-builder import legal` then
normalises to NFC, maps the Icelandic eth `Ð`/`ð` (a common typing slip in these files) to `Đ`/`đ`, unifies
line separators, trims spaces and collapses blank lines. The extracted texts are committed and pinned, so
builds never depend on `textutil` or the network.

**What ships.** Only single syllables (`attested.txt`), never the texts. The repository keeps the extracted
texts and the prose corpus (`data/corpus/prose-vi.txt`) as test inputs. Attribution of the download portals
is given in `data/NOTICES.md` as a courtesy (the portals ask for their name when information is republished).

## 3. Lists written by the project

`tech-always.txt` (384 entries), `tech-code-only.txt` (229 entries), `attested-additions.txt` (252 entries,
each with a reason) and `ambiguity.tsv` (18 ENG-R821 proposals plus 7 unreviewed spec 8.3 examples) are
original work licensed with the engine (MPL-2.0 since 15/11/2026, MIT before;
[0006](0006-app-licence-and-pro-edition.md)). Product names in `tech-always.txt` are used only so that typing
them is not altered.

Every tech word was checked for collisions with the reference model in `spec/reference-model/`
(spec material, allowed by CLR-R3) before it was listed: words whose Telex typing gives a common Tier A
syllable were removed from tech-always because rule L11 would restore that syllable (`gif` -> `gì`,
`uri` -> `ủi`, `rar` -> `rả`, `rest` -> `rét`, `visa` -> `vía`, `sars` -> `sá`, plus `be` and `pin`, which are
Vietnamese words). The remaining tech-always collisions are rare syllables (`exe` -> `ễ`, `ux` -> `ũ`,
`momo` -> `môm`, `nextjs` -> `nét`). The code-only list keeps real shell commands even when they collide
(`tar` -> `tả`, `tee` -> `tê`, `host` -> `hót`) because it applies only in the code context (L9, ENG-R850).
The attested additions cover the displays of the ENG-R821 proposals and everyday or colloquial syllables that
the legal texts lack (legal prose has only 1,784 distinct syllables); candidates were found by typing the
SCOWL words through the reference model and keeping displays that are real Vietnamese words. Pa reviews all
four files.

## Consequences

- `english.txt` and the notices are final; `attested.txt` holds only the hand additions (259 syllables with
  tone-style variants) until the engine's `Orthography.validity` replaces the stub. Re-running
  `lexicon-builder build` after the engine merge adds the legal-text syllables (about 1,700 valid ones) and
  `lexicon-builder check` will fail until the regenerated files are committed.
- The ambiguity table needs `lexicon-builder ambiguity-candidates --merge` after the engine merge, then Pa's
  review of at least the 300 most frequent candidates (ENG-R821).
- `data/NOTICES.md` is the input for the docs track's `THIRD_PARTY_NOTICES.md`.

## Amendment, 2026-11-13 (engine integration, docs/decisions/0202)

- **SCOWL level measured** (the VERIFY of section 1): Tier A collisions per cumulative level are 3.19 % (10),
  2.52 % (10-20), 1.50 % (10-35), 1.42 % (10-40) and 1.16 % (10-50) of the words. Level 50 would add 23,210
  rare words and 100 more English words whose unattested display rule L8 restores; levels 10, 20 and 35 stay.
- **Lexicon**: one-letter entries other than `a` and `i` are dropped (SCOWL lists `m`, which Vietnamese uses as
  a list marker and a chat abbreviation): **40,205 words**.
- **Project lists now** (after the branch review of 0202): `tech-always.txt` 389 entries (six commands moved
  from the code-only list because their typing gives no Vietnamese syllable, the Roman numeral `xix` added,
  `a3` and `a5` removed because they type `ả` and `ạ` in VNI), `tech-code-only.txt` 223,
  `attested-additions.txt` 272 (20 everyday syllables whose natural typing is an English word or a tech word,
  such as `sên` typed `seen` and `ĩ` typed `ix`), `ambiguity.tsv` 619 rows. Every change carries a reason in
  its file and waits for Pa's review.
- The consequences above are done: `attested.txt` holds 1,954 syllables (1,678 from the legal texts) and the
  ambiguity table holds the merged candidates.
