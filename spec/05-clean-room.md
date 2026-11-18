# 05. Clean-room rules and provenance

Prefix: CLR-R

{{AppName}} is written from scratch. Its typing engine and input host must not be derived from any existing Vietnamese input method. This file is binding for every human and AI agent that writes code in this repository.

## 1. Why

- Several Vietnamese input methods on macOS (XKey, PHTV, Vikey, LibreKey, OpenKey itself) derive from OpenKey (GPL-3.0). XKey shipped OpenKey-derived code under an MIT label, which is a licence violation that anyone can point out publicly.
- {{AppName}} wants a clean licence (an engine any app can embed, licences chosen freely by the author) and a clean story: "written from scratch by Kal".
- Copyright protects code and its specific expression, not the rules of Vietnamese orthography, Telex/VNI conventions, or the set of valid syllables. Everything in this spec is behaviour, so implementing it independently is safe as long as no protected code reaches this repository.

## 2. Rules for implementers

- CLR-R1 Implementers MUST NOT read, open, fetch or search the source code of: XKey, OpenKey, Unikey / ibus-unikey / fcitx-unikey, PHTV, Vikey, LibreKey, EVKey (any version, including GPL rewrites), GoTiengViet, or any fork of these. This includes GitHub web views, raw file URLs, code search results and snippets quoted in blog posts or AI answers.
- CLR-R2 Implementers MUST NOT read the source of other open-source Vietnamese engines either (vi-rs, bamboo-core, Gõ Nhanh core, VietTelex) while writing the engine. Using one as a dependency requires an explicit decision by the author, recorded in `docs/decisions/`, and a licence entry in `THIRD_PARTY_NOTICES.md`.
- CLR-R3 Allowed sources: this spec folder, Apple developer documentation and sample code, the Unicode standard, public descriptions of Vietnamese orthography and of the Telex and VNI conventions (encyclopedias, textbooks, standards), and general Swift/macOS knowledge.
- CLR-R4 If an AI assistant produces code that looks like it comes from a known input method (identifiers, comments, table layouts or bit layouts that were not designed here), discard it and rewrite from the spec. Never paste code from a chat answer whose origin is unknown.
- CLR-R5 Behavioural facts about other products (for example "app X duplicates letters in the Chrome address bar") are allowed when they come from public bug reports, release notes or observing the running app. Their code is not.
- CLR-R6 Third-party word lists, dictionaries and test corpora MUST have a recorded permissive licence (MIT, BSD, Apache-2.0, CC0, CC-BY or public domain); lists and corpora written for this project carry the engine licence (ENG-R109). GPL/LGPL data (for example the hunspell-vi / Aspell Vietnamese list) MUST NOT be bundled or downloaded. The syllable validator is rule-based (see 01-engine.md), so no Vietnamese dictionary is needed.
- CLR-R7 Icons, images and copy are original or properly licensed; record the source of every asset.

## 3. Setting up AI agents for this repository

- CLR-R8 Use a new, empty memory project (for example a new Munin context core) for this repository. Do not connect agents to memory stores that contain notes about the internals of other input methods.
- CLR-R9 Do not add the old research folder (the one that contains the XKey clone and the audit) as a working directory, and do not copy it into this repository. Only this `spec/` folder comes across.
- CLR-R10 Put a short clean-room notice in the repository's agent instructions file (`CLAUDE.md` / `AGENTS.md`). Ready-to-paste text:

```markdown
## Clean-room rule (mandatory)
This project is an independent implementation. Do not read, fetch, search or quote the source code of any
other Vietnamese input method (XKey, OpenKey, Unikey, PHTV, Vikey, LibreKey, EVKey, GoTiengViet, Gõ Nhanh,
vi-rs, bamboo-core, VietTelex, or forks). Work only from spec/ and public documentation (Apple, Unicode,
Vietnamese orthography). If generated code resembles another project, discard it and rewrite from the spec.
See spec/05-clean-room.md.
```

## 4. Provenance record

- CLR-R11 Every source file carries an SPDX licence header: `MPL-2.0` in the engine packages, the `data/` pipeline and the reference model, `GPL-3.0-or-later` elsewhere (`docs/decisions/0006-app-licence-and-pro-edition.md`).
- CLR-R12 Keep the git history intact from the first commit (no squashing of the early history). The spec, the decision log (`docs/decisions/`) and the commit history together are the evidence of independent creation. *(Amendment of 2026-11-15, the product owner's decision before the repository became public, `docs/decisions/0005-pa-decisions-2026-11-13.md`.)* The history was rewritten when the repository became public (15 and 16/11/2026): every commit keeps its author, its dates, its place in the order and its message (wording edits only where decision 0005 of 15/11/2026 applies), while the licence statements of the engine parts read MPL-2.0 in every commit, the documents follow the wording decision of the same day (no development tools named, no chat quotes) and instructions that apply only to the maintainer's own machine are left out. The original history, with its commit IDs, stays as evidence in a private repository of the product owner and in an offline `git bundle`, together with the map from original to published commit IDs. No further rewrite is allowed.
- CLR-R13 Before the first public release and before 1.0, run a similarity review performed by someone who is allowed to look at the other codebases (the "dirty side", never an implementer): compare identifiers, data-structure layouts, table orderings and comments against OpenKey and XKey. Record the result in `docs/provenance/`. Any match gets rewritten from the spec by a clean implementer. *(Amendment of 2026-11-18, the product owner's decision, `docs/decisions/0009-pa-decisions-2026-11-18.md` item 2:)* 1.0.0, the first public release and 1.0, shipped before this comparison was done (its provenance report, note N1). The comparison is performed by a reviewer the product owner appoints, under `docs/runbooks/similarity-review.md`: the first run covers the shipped 1.0.0 commit `9d63a360`, and every later public release that changes the paths of that runbook's section 4 gets a delta report. A `fail` verdict blocks the release. Until the product owner confirms otherwise, a comparison that is commissioned but not finished does not block a release by itself: the release's provenance report records that it is pending (integrator's call in the same record, awaiting confirmation).
- CLR-R14 External contributions: contributors confirm they followed this file (via the DCO sign-off or CLA chosen in 04-quality-release.md).

## 5. Acceptance

- A provenance review report exists in `docs/provenance/` for each public release, with no unresolved matches.
- `THIRD_PARTY_NOTICES.md` lists every dependency, word list and asset with its licence.
- The agent instructions file contains the clean-room notice from CLR-R10.
