# Data notices (input for THIRD_PARTY_NOTICES.md)

Every data source used by the engine's bundled word lists and test corpora, with its licence and the
attribution it requires. The shipped `NOTICES.txt` (generated from `data/licenses/bundled-notices.txt`) carries
the texts that must reach users; the app shows it in its acknowledgements (spec/01-engine.md ENG-R811).
Details and quotes: `docs/decisions/0200-data-sources-and-licences.md`.

| Data | Shipped as | Source | Licence | Required attribution |
|---|---|---|---|---|
| English lexicon | `english.txt` | SCOWL 2020.12.07 by Kevin Atkinson, levels 10/20/35, `words` lists for English, American, British (-ise, -ize); http://wordlist.aspell.net/ | SCOWL permission notice (MIT/X11-style); component sources public domain (Moby Words II, Brian Kelk's UK list, 12dicts) or permissive with notice (WordNet 1.6, VarCon, Ispell) | Reproduce the full SCOWL `Copyright` file (`data/licenses/SCOWL-2020.12.07-Copyright.txt`) in the documentation / acknowledgements. Done in `NOTICES.txt`. |
| Attested syllables | `attested.txt` (syllables only) | 13 Vietnamese laws and codes listed in `data/inputs/legal/SOURCES.tsv`, downloaded from the portal of the Intellectual Property Office of Viet Nam (ipvietnam.gov.vn) and the Official Gazette (congbao.chinhphu.vn) | Not protected by copyright: Law on Intellectual Property No. 50/2005/QH11, Article 15(2) | None required. Courtesy credit, given in `NOTICES.txt`: "Legal texts obtained from the Intellectual Property Office of Viet Nam (ipvietnam.gov.vn) and the Official Gazette (congbao.chinhphu.vn)." (both portals ask for their name when information is republished) |
| Prose corpus (tests only, not shipped) | `data/corpus/prose-vi.txt` | same legal texts | same | same courtesy credit |
| Tech-always list, code-only list, attested additions, ambiguity table | `tech-always.txt`, `tech-code-only.txt`, part of `attested.txt`, `ambiguity.tsv` | written by the project | MPL-2.0, as the engine package | Covered by the engine's licence (`data/LICENSE`, `data/NOTICE`). Product names are trademarks of their owners. |

Text to paste into `THIRD_PARTY_NOTICES.md` (the SCOWL block must be the verbatim file):

```text
English word list (VietnameseEngineData english.txt)
Derived from SCOWL (Spell Checker Oriented Word Lists) release 2020.12.07 by Kevin Atkinson,
http://wordlist.aspell.net/, size levels 10, 20 and 35.
<verbatim contents of data/licenses/SCOWL-2020.12.07-Copyright.txt>

Vietnamese syllable list (VietnameseEngineData attested.txt)
Built from Vietnamese legal normative documents, which are not objects of copyright protection under
Article 15(2) of the Law on Intellectual Property of Viet Nam (No. 50/2005/QH11). Legal texts obtained from
the Intellectual Property Office of Viet Nam (ipvietnam.gov.vn) and the Official Gazette (congbao.chinhphu.vn).
```

Not used, by rule (spec/01-engine.md 8.2, spec/05-clean-room.md CLR-R6): wordfreq, google-10000-english,
hunspell-vi / Aspell Vietnamese, Wiktionary, data of any other input method.
