# Changelog

All notable changes to the engine package. Format: one section per release, newest first.

## Unreleased

- Letter model and the generated table of the 146 emittable letters (ENG-R301).
- Syllable model of spec section 3: onsets, Tier A rhymes (156), `qu` rhymes (41), `gi` rules with
  `gi + êc`, Tier B extensions including the `dz` onset; parser (3.13), validity tiers, viability
  automaton (3.14), horn normalisation (5.5), tone placement in both styles (5.1, 5.2).
- Public `Orthography.analyze` and `Orthography.validity(of:)`.
- `VietnameseEngineTesting`: independent oracle, generated O1 to O4 corpus with ENG-T03 variants, loaders
  for the worked examples extracted from the spec, and the 13.9 fixture resources.
