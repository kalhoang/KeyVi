# VietnameseEngine

A Vietnamese composition engine (Telex and VNI) written from scratch from `spec/01-engine.md`. It turns
characters typed on any keyboard layout into precomposed (NFC) Vietnamese text, decides at each word
boundary whether a word should be restored to the keys as typed, and expands macros. It has no state
outside the values it returns, performs no I/O and imports only the Swift standard library.

Licence: MPL-2.0 (see `LICENSE`). Bundled word lists in `VietnameseEngineData` keep their own notices.

## Targets

| Target | Contents |
|---|---|
| `VietnameseEngine` | Core: letters, orthography (syllable tiers, viability, tone placement), composition, commit rules. Standard library only. |
| `VietnameseEngineData` | Bundled resources and `Resources.bundled()`. |
| `VietnameseEngineTesting` | Test support: independent oracle, generated corpus, spec fixture loaders. |
| `lexicon-builder` | Builds the bundled resources from pinned inputs. |

## API sketch

```swift
import VietnameseEngine

let engine = Engine(configuration: EngineConfiguration(), resources: .empty)
var session = Session(engine: engine)
for key in "vieetj " {
    let output = session.handle(.key(KeyInput(key)))
    // output.action: .passThrough, or .edit(TextEdit(delete, insert), thenPassThrough:)
    // output.composingText: the active token for marked-text hosts
}

Orthography.validity(of: "Krông")   // .extended (Tier B)
Orthography.analyze("giếc")         // onset "gi", vowel group "ê", coda "c", tone .acute, .standard
```

The full public API is in `Sources/VietnameseEngine/PublicAPI.swift` (spec section 12.2).

## Generated sources and data

| Output | Generator | Check |
|---|---|---|
| `Sources/VietnameseEngine/Generated/LetterTable.swift` (146 letters, ENG-R301) | `python3 -I Scripts/generate-letter-table.py` | `--check` |
| `Tests/VietnameseEngineTests/Corpus/{worked-examples,commit-decisions,restore-toggle,commit-fixtures}.tsv` (spec 13.8 to 13.10) | `python3 -I Scripts/extract-spec-examples.py` | `--check` |

Never edit these files by hand; change the spec or the generator and regenerate.

## Tests

`swift build && swift test` from this directory. Tests use Swift Testing and are organised by area:

| Folder | What it checks |
|---|---|
| `Tests/VietnameseEngineTests/Letters` | the letter model and the generated letter table, re-derived from Unicode data |
| `Tests/VietnameseEngineTests/Orthography` | parser (3.13), validity tiers (3.10 to 3.12), viability (3.14), tone placement (5.1 to 5.4), horn normalisation (5.5), `Orthography.analyze`, and the inventory counts printed for ENG-R350 |
| `Tests/VietnameseEngineTests/Oracle` | the oracle (ENG-T01) and the generated O1 to O4 corpus and variants (ENG-T02, ENG-T03) |
| `Tests/VietnameseEngineTests/Fixtures` | integrity of the extracted spec fixtures and the 13.9 fixture resources |
| `Tests/VietnameseEngineTests/Corpus` | data files (QA-R4), read through `CorpusFiles` |

The counts and their differences from the spec's reference model are explained in
`docs/decisions/0100-engine-syllable-counts.md`; the internal representations in
`docs/decisions/0101-engine-letter-model-and-orthography-structures.md`.
