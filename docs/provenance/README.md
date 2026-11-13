# Provenance review (clean-room similarity review)

Owner: the maintainer. Specification: [spec/05-clean-room.md](../../spec/05-clean-room.md) (CLR-R11, CLR-R12, CLR-R13, CLR-R14, acceptance in section 5).

{{AppName}} is written from scratch. The spec, the decision log in `docs/decisions/`, and the unbroken commit history together are the evidence of independent creation. This folder holds the written reviews that check, before public releases, that no protected code reached the repository.

## 1. Who may do the review (the "dirty side")

The review compares this repository against the code of other Vietnamese input methods. Only someone who is **allowed to look at those codebases** may do it: the "dirty side". The rule has two halves:

- **Never an implementer.** Nobody who wrote or reviewed engine or input-host code for this project, human or AI agent, may perform or assist the review, because that would contaminate the clean side.
- **Never an AI agent session that also worked on this repository.** If an AI tool helps with the comparison, use a separate session and workspace that never touched this repository's implementation work, and treat its output as a lead, not as proof.

The reviewer should not write engine or input-host code afterwards for the areas compared, and must not hand any code, identifiers or table layouts of the other codebases to the clean side. The clean side only ever receives an abstract finding ("these table orderings in file X match") and rewrites from the spec.

The maintainer records who the reviewer is and why they qualify in each report.

## 2. When

| Moment | Requirement |
|---|---|
| Before the first public release | Full review (CLR-R13) |
| Before 1.0 | Full review (CLR-R13) |
| Every other public release | A report must exist (spec section 5 acceptance): either a delta review of the changes since the last report, or a recorded statement that no engine or input-host code changed since it |
| Any time a contribution looks suspicious | Targeted review of that change |

A public release is not published while a report has an unresolved match ([release runbook](../runbooks/release.md) section 2).

## 3. What is compared

Compare this repository against OpenKey and XKey in particular, and against the other implementations named in CLR-R1 and CLR-R2 where practical. Record the exact version of each codebase (tag or commit) that was compared.

Compare at least:

1. **Identifiers**: names of types, functions, constants, enum cases and files.
2. **Data-structure layouts**: field orders, bit layouts, packed encodings, state-machine shapes.
3. **Table orderings**: key maps, character tables, vowel and consonant lists, tone tables, the order of entries in any data table.
4. **Comments**: wording, typos and unusual remarks.
5. **Test data and word lists**: copied fixtures, shared mistakes, shared quirks.
6. **Behavioural fingerprints**: unusual behaviours that are not in the spec and not required by Vietnamese orthography.

Suggested methods: automated token or identifier overlap measures between the two trees; extracting the identifier sets and diffing them; manual side-by-side reading of the key tables and the composition core; searching distinctive comment strings. Record the tools and versions used.

Common vocabulary is not a match: Vietnamese linguistic terms, Telex and VNI letters, Unicode code points and the names of Apple APIs will legitimately appear in every implementation. The report must say which similarities were judged inevitable and why.

## 4. Process

1. **Freeze the target**: record the commit SHA of this repository under review and the versions of the compared codebases.
2. **Run the comparison** (section 3) and fill in the [report template](report-template.md). Do not quote the other codebase's code in the report: describe locations (file path and line range in the compared project) and the nature of the similarity.
3. **Classify each finding**: `none`, `inevitable` (with reason), `suspect`, `match`.
4. **Remediate every `suspect` or `match`**: a clean implementer (not the reviewer) rewrites the affected code from the spec, without seeing the other code. The reviewer then re-checks only that the rewritten area no longer matches, and records the new commit SHA. Do not "tweak" the matching code: rewrite it.
5. **Close the report** with a conclusion, the reviewer's signature (name and date) and the maintainer's acknowledgement. Unresolved matches block the release.
6. **Store the report** in `docs/provenance/reports/YYYY-MM-DD-<release>.md`, committed on `main` without rewriting history.

## 5. Related rules

- **CLR-R11**: every source file carries an SPDX header (`MPL-2.0` in the engine package, `LicenseRef-App-Pending` elsewhere). The review checks that no source file lacks one.
- **CLR-R12**: the git history is intact from the first commit. No squashing of the early history, no history rewriting on `main`, no deleting and recreating the repository. The review lists the first commit and confirms continuity.
- **CLR-R14**: external contributors confirm they followed the clean-room rule, through the DCO sign-off and the pull request attestation ([CONTRIBUTING.md](../../CONTRIBUTING.md) section 2).
- **CLR-R6 and CLR-R7**: word lists, corpora, icons and images have recorded permissive licences or original authorship ([THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)). The review cross-checks that file.
- **CLR-R8**: this repository's AI agents use a new, empty memory project. The review notes whether any agent worked with a memory store that held other input methods' internals.

## 6. Acceptance

- A report exists in `docs/provenance/reports/` for each public release, with no unresolved matches.
- `THIRD_PARTY_NOTICES.md` lists every dependency, word list and asset with its licence.
- The agent instructions file contains the clean-room notice from CLR-R10 ([CLAUDE.md](../../CLAUDE.md), [AGENTS.md](../../AGENTS.md)).

## 7. Asset sources (CLR-R7)

Every icon, image and piece of artwork in the repository has a recorded source. The review (section 3) checks
that each asset below still matches its record and that no new asset arrived without one.
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) section 4 carries the same entries with licences;
`scripts/tests/test_docs_and_workflows.py` (`AssetRecordTests`) fails when an image has no entry in either file, or when
an SVG has no source comment. Pa's original SVGs under `assets/` are exempt from the comment while they stay
byte-identical to the files Pa supplied (the test pins their SHA-256): the project never edits the product owner's originals. Every image file in the repository is listed, shipped or not.

| Asset | Files | Source record | Origin | Status |
|---|---|---|---|---|
| Source artwork (Pa) | `assets/keyvi_logo.png`, `assets/keyvi_menubar_on_light.svg`, `assets/keyvi_menubar_on_dark.svg`, `assets/keyvi_menubar_off_light.svg`, `assets/keyvi_menubar_off_dark.svg` | This table and THIRD_PARTY_NOTICES.md section 4 | Pa's own artwork, supplied on 2026-11-13 (decision S7), commit `e6b3855` | Source files; every icon below is generated from them |
| App icon | `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png`, `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png` and `App/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` (16 to 512 pt at 1x and 2x) | Header of `scripts/make-app-icon.py`, this table | Generated on 2026-11-13 by `scripts/make-app-icon.py app-icon` from `assets/keyvi_logo.png`: keycap cut out with a rounded-square mask, soft shadow, Apple's macOS icon grid | Final artwork from Pa; re-run the script when the logo changes |
| Menu-bar status icons (8 states: `StatusIcon-vietnamese`, `StatusIcon-english`, `StatusIcon-paused`, `StatusIcon-notWorking`, `StatusIcon-ignoredApp`, `StatusIcon-secureInputVietnamese`, `StatusIcon-secureInputEnglish`, `StatusIcon-capturing`) | `App/Resources/Assets.xcassets/StatusIcon-*.imageset/*.svg` (light, dark, light high contrast, dark high contrast) | XML comment at the top of each SVG | `vietnamese` and `english` (light, dark) are Pa's `assets/keyvi_menubar_on_*` and `keyvi_menubar_off_*` files with a source comment added; the high-contrast variants and the other states are derived from the same mark by `scripts/make-app-icon.py menu-bar` on 2026-11-13 | Final artwork from Pa; `menu-bar --check` (scripts/tests) fails when a file drifts from the generator |
| Status glyph loader | `App/Sources/Shell/StatusGlyph.swift` | Header comment of the file | Original code written for this repository; loads the catalog images and draws no artwork (fallback: the system "keyboard" SF Symbol, requested by name, not bundled) | Current |
| Donation VietQR code (`DonationVietQR`) | `App/Resources/Donation.xcassets/DonationVietQR.imageset/vietqr.png`, `site/static/assets/qr/vietqr.png` (the same file) | This table, THIRD_PARTY_NOTICES.md section 4 and [donation setup](../runbooks/donation-setup.md) | Generated on 2026-11-13 by `scripts/make-vietqr.py` from Pa's bank details (decision S8) with the keycap of `assets/keyvi_logo.png` in the centre; rendered with the `qrcode` and Pillow packages (generation tools, not shipped) | Final; no MoMo code (S8). Pa scans it with two banking apps before the first public build |
| Website icons | `site/static/favicon.svg`, `site/static/favicon.ico`, `site/static/apple-touch-icon.png`, `site/static/assets/brand/app-icon-64.png`, `site/static/assets/brand/app-icon-128.png` | XML comment in `favicon.svg`, this table and THIRD_PARTY_NOTICES.md section 4 | Generated on 2026-11-13 by `scripts/make-app-icon.py site` from Pa's artwork (the KV mark for the SVG, the cut-out keycap for the raster files) | Final; replaces the interim "V" favicon of commit `4b77ba8` |
| Input method spike icon (not shipped) | `SpikeIMK/Resources/SpikeIMK.tiff` | Header comment of `SpikeIMK/Tools/make-icon.py` | Original pixel art generated on 2026-11-13 (commit `82012a6`) by `SpikeIMK/Tools/make-icon.py`, which regenerates it | Test target only, never released |

## Index of reports

| Date | Release | Reviewer | Result | Report |
|---|---|---|---|---|
| (none yet) | | | | |
