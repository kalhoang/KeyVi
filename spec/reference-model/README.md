# Reference model (test oracle, not shipped)

A small Python model of the orthography and composition rules in `../01-engine.md`, written by the author of that file from the spec text only (no other input method's code was consulted). It generated the corpus counts quoted in 01-engine.md section 3 and checked the worked examples.

- `ortho.py`: syllable inventory, tiers, tone rules.
- `compose.py`: keystroke-to-display composition (Telex, VNI, both tone styles).
- `boundary.py`: commit / restore decisions; `common_en.txt` is a hand-written English fixture list.
- `corpus.py`: generates the O1-O4 corpus; `examples.py` checks `examples.json` / `rows.json`.

Known gaps (update the model from the spec before relying on it):

1. It predates two review additions: rhyme `êc` after `gi` (`giếc`, ENG-R305) and open `y` after `th` (`Thy`, ENG-R314).
2. It predates the product owner's P0 additions: the `dz` onset (01-engine.md 3.3, ENG-R316), worked examples W249-W253 and boundary rows B053-B064.

The Swift engine's test suite is the authority; this model only exists to generate and cross-check test data. Licence: same as the engine package.
