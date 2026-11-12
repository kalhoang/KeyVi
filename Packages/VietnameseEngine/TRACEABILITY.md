# Traceability: engine requirements to code and tests

Requirement IDs are from `spec/01-engine.md`. Paths are relative to this package. Rows are added as the
composition, commit and quality work lands.

| Requirement | Code | Tests |
|---|---|---|
| ENG-R102, ENG-R301 (146 precomposed letters, generated from Unicode data, ordered by code point) | `Scripts/generate-letter-table.py`, `Sources/VietnameseEngine/Generated/LetterTable.swift`, `Letters/LetterTableLookup.swift` | `Letters/LetterTableTests.swift` |
| 3.2 letters and modifiers | `Letters/Letter.swift` | `Letters/LetterTableTests.swift` (`LetterTests`) |
| 3.3 onsets (Tier A, Tier B clusters, `z`, `dz`), ENG-R316 | `Orthography/Onset.swift` | `Orthography/SyllableParserTests.swift`, `Orthography/ValidityTests.swift` |
| 3.7, 3.8, 3.9, 3.12 rhyme lists, ENG-R302, ENG-R303, ENG-R305 | `Orthography/RhymeInventory.swift` | `Orthography/SyllableCountTests.swift` |
| 3.4, 3.10, 3.11, 3.12 rules, ENG-R304 to ENG-R315, ENG-R320, ENG-R321, ENG-R330 | `Orthography/SyllableRules.swift`, `Orthography/Rhyme.swift`, `Orthography/SyllableTables.swift` | `Orthography/ValidityTests.swift`, `Orthography/SyllableCountTests.swift` |
| 3.13 parse, ENG-R340 | `Orthography/SyllableParser.swift` | `Orthography/SyllableParserTests.swift` |
| 3.14 viability, ENG-R345, ENG-R346 | `Orthography/ViabilityAutomaton.swift` | `Orthography/ViabilityTests.swift` |
| 3.15 counts, ENG-R350 | `Orthography/SyllableTables.swift` | `Orthography/SyllableCountTests.swift` (prints counts); `docs/decisions/0100-engine-syllable-counts.md` |
| 5.1, 5.2, ENG-R501, ENG-R502, ENG-R510, ENG-R511 | `Orthography/TonePlacement.swift` | `Orthography/TonePlacementTests.swift` |
| 5.5, ENG-R530 to ENG-R532 | `Orthography/HornNormalisation.swift` | `Orthography/HornNormalisationTests.swift` |
| ENG-R1212 `Orthography.analyze`, `validity(of:)` | `Orthography/Orthography.swift` | `Orthography/OrthographyAnalyzeTests.swift`, `Orthography/ValidityTests.swift` |
| ENG-T01 oracle | `Sources/VietnameseEngineTesting/Oracle/SyllableOracle.swift` | `Oracle/SyllableOracleTests.swift` |
| ENG-T02, ENG-T03, ENG-T04 generated corpus | `Sources/VietnameseEngineTesting/Oracle/KeySequenceGenerator.swift`, `GeneratedCorpus.swift` | `Oracle/GeneratedCorpusTests.swift` (prints case counts) |
| 13.8, 13.9, 13.9.1, 13.10 worked examples | `Scripts/extract-spec-examples.py`, `Tests/VietnameseEngineTests/Corpus/*.tsv`, `Sources/VietnameseEngineTesting/Fixtures/` | `Fixtures/SpecFixtureFileTests.swift` |
| ENG-R1201, ENG-R1202 (standard library only, no mutable static state) | whole core target | checked by review; the core has no `import` and no `static var` |
