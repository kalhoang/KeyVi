# Reference model (test oracle, not shipped)

A small Python model of the orthography and composition rules in `../01-engine.md`, written by the author of that file from the spec text only (no other input method's code was consulted). It generated the corpus counts quoted in 01-engine.md section 3 and checked the worked examples.

- `ortho.py`: syllable inventory, tiers, tone rules.
- `compose.py`: keystroke-to-display composition (Telex, VNI, both tone styles).
- `boundary.py`: commit / restore decisions; `common_en.txt` is a hand-written English fixture list. `type_run` models the English run of ENG-R823 as amended on 14/11/2026 (an `en` token and no `vi` token among the previous three; a token kept by L11 is neutral), and `python3 -I boundary.py` checks rows B065-B072 of 13.9.2 and the sentences of ENG-R823 (none expected to differ).
- `corpus.py`: generates the O1-O4 corpus; `examples.py` checks its example list (and writes `examples.json`) and every 13.8 row of `rows.json` (`python3 -I examples.py` prints the mismatches; none expected).
- `compose.py` models Backspace by ENG-R710 as amended on 14/11/2026 (a modifier key shared with a letter that stays keeps marking it, REG-31) and the space boundary with re-open (ENG-R1002) for rows W243h and W243i; the restore decisions of section 8 are left to `boundary.py`. It also models the amendments of 15/11/2026: tone removal by layers (ENG-R411: the tone, then every mark and `đ`, REG-34), Backspace on an escape letter with the keys it undid and its fallbacks (ENG-R711, rows W241, W242, W242a-W242u: tone keys that wait for their vowel in the replay, a standalone `w` letter shown plain kept as a plain key, the letters shown retyped), the shared-key rule counting only mark keys after a mark removal (ENG-R710, W242s, W242t), and a removal key that would replay as a letter being left out (ENG-R710). The bracket doubling escape (4.8) is not modelled. Rows W243k-W243o (a re-opened restored word, ENG-R1005) are not in `rows.json`: they depend on the restore decisions of section 8.

Known gaps (update the model from the spec before relying on it):

1. It predates two review additions: rhyme `êc` after `gi` (`giếc`, ENG-R305) and open `y` after `th` (`Thy`, ENG-R314).
2. It predates the product owner's P0 additions: the `dz` onset (01-engine.md 3.3, ENG-R316), worked examples W249-W253 and boundary rows B053-B064.
3. It counts the spelling `giu` twice: once as onset `g` + rhyme `iu` and once as onset `gi` + rhyme `u`. The normative parse of 01-engine.md 3.13 reads `giu` only as `gi` + `u` (ENG-R305, ENG-R306), so every count derived from the model is one pair, six toned syllables and 92 O1 to O4 cases too high. The first version of 3.15 and ENG-T04 quoted such counts (3,368 Tier A pairs, 15,412 toned syllables, 6,209 Tier B pairs, 237,916 cases); they now quote the corrected counts (decision of the product owner, 13/11/2026, docs/decisions/0005-pa-decisions-2026-11-13.md; analysis in docs/decisions/0100-engine-syllable-counts.md).

The Swift engine's test suite is the authority; this model only exists to generate and cross-check test data.

## Licence

Copyright (c) 2026 the {{AppName}} authors. Licence: MPL-2.0, the same as the engine packages (`docs/decisions/0006-app-licence-and-pro-edition.md`, amended on 15/11/2026). The licence text is `LICENSE` in this directory, verbatim, and each script carries `SPDX-License-Identifier: MPL-2.0`. The notice of MPL-2.0 Exhibit A applies to every file here: This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/. No Exhibit B notice applies, so the model may be combined with code under the GNU GPL (Secondary Licenses, MPL-2.0 section 3.3).
