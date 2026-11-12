# Changelog

All notable changes to the engine package. Format: one section per release, newest first.

## Unreleased

- Letter model and the generated table of the 146 emittable letters (ENG-R301).
- Syllable model of spec section 3: onsets, Tier A rhymes (156), `qu` rhymes (41), `gi` rules with
  `gi + êc`, Tier B extensions including the `dz` onset; parser (3.13), validity tiers, viability
  automaton (3.14), horn normalisation (5.5), tone placement in both styles (5.1, 5.2).
- Public `Orthography.analyze` and `Orthography.validity(of:)`.
- Composition (sections 4 to 7, 9.1): Telex and VNI key maps, the order of interpretation with viability
  gating, literal mode, free order, sticky escapes, standalone `w` and bracket options, tone placement and
  relocation on every key, horn handling for `u o`, Backspace inside a token, the restore toggle within the
  active token, case and camel case, and the 64-key literal cap. The display is a fold over the raw keys
  (ENG-R601); edits are minimal (ENG-R611).
- `Engine.reduce` and `Session` for key, Backspace, restore toggle and reset events.
- Commit decisions (section 8.1): rules L0 to L11 in order, each commit reporting its `CommitDecision`;
  auto restore off, user lists, learning signals, app context `code`, the English run of the last three
  tokens, and the `uơ` spelling of an open `ươ` at commit. Every boundary key of section 9.2 commits the
  same way and is delivered after the edit.
- History (section 10): Backspace re-opens the previous word across `", "`, `". "` and double spaces;
  configurable limit; resets clear token and history.
- Macros (section 11): table validation, matching on the raw span (up to 32 characters, punctuation and
  digits included) by a fixed-size hash key, expansion before L0 with adaptive casing, and the toggle that
  brings the trigger back.
- Tests: B001-B064 with every boundary key, REG-01 to REG-30, QA-R4 `macros` and `editing` corpora, the
  generated corpus committed in Vietnamese context (ENG-R870), the ENG-T12 spot list.
- `VietnameseEngineTesting`: simulated text field and engine driver (ENG-T31), seeded random event streams.
- `VietnameseEngineTesting`: independent oracle, generated O1 to O4 corpus with ENG-T03 variants, loaders
  for the worked examples extracted from the spec, and the 13.9 fixture resources.
