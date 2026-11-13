# 0001. Working defaults for the open decisions

- Status: accepted (working defaults until Pa decides), 2026-11-13
- Context: spec/00-overview.md section 5 lists 19 open decisions; "the spec's proposed default applies until Pa decides".

## Decision

| # | Decision | Working default used by the implementation |
|---|---|---|
| 1 | Product name | Temporary name **Kal Key**, slug `kalkey`, bundle ID `vn.kal.kalkey` (dev: `vn.kal.kalkey.dev`). Single source: `Config/Brand.xcconfig` + `scripts/brand.env`; rename with `scripts/rename-app.sh`. The spec's recommendation (Xuôi, `xuoi`) is not applied because Pa said the name is not chosen yet. |
| 2 | App licence | Pending. Non-engine sources carry `SPDX-License-Identifier: GPL-3.0-or-later`; no top-level LICENSE until Pa decides. |
| 3 | Engine licence | MPL-2.0 (`Packages/VietnameseEngine/LICENSE`). |
| 4 | Default tone placement | Traditional (`hòa`, `thủy`). |
| 5 | Restore-last-word hotkey | Unset by default. |
| 6 | Minimum macOS | 15.0; no API newer than macOS 14 outside the `Synchronization` module (PLT-R106). |
| 7 | Macro triggers | Printable ASCII only, no whitespace, no Vietnamese letters. |
| 8 | Learning from restore toggles | Automatic after two identical signals, visible and removable. |
| 9 | Attested-syllable source | Vietnamese legal normative texts (pinned, checksummed) plus a reviewed additions file. |
| 10 | Ambiguity table review | Unreviewed rows behave as `vi`; proposed rows of ENG-R821 pre-filled and marked "proposed". |
| 11 | Terminals default mode | Inherit. |
| 12 | Chromium/Electron AX enabling | Off unless a rule proves no side effect. |
| 13 | Zero-width placeholder | Only under the PLT-R422 test gate; no shipped rule enables it until its test exists. |
| 14 | Signing/notarization | Scripts support both; the EdDSA key stays on Pa's Mac. |
| 15 | Archive hosting | Site host only by default; GitHub Releases optional flag in the publish script. |
| 16 | Self-hosted runner | Workflows written; runner registration left to Pa. |
| 17 | IMKit edition | Spike S1 prepared; decision after Pa runs it. |
| 18 | Website analytics | None. |
| 19 | Donation details | Placeholders marked VERIFY; no real account data in the repo. |

## Consequences
Every item can be changed by Pa later; each change gets its own decision record that supersedes the row above.
