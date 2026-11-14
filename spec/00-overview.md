# 00. Overview

{{AppName}} is a Vietnamese input method for macOS, written from scratch by Kal and published as a personal project on `{{app-slug}}.kal.vn`. It exists because the input methods available on the Mac in 2026 work "well enough" but are full of daily annoyances: wrong defaults, English words getting Vietnamese marks, typing that breaks in specific apps, and blocks that nobody explains. The whole point of this product is product quality: correct out of the box, invisible while typing, smooth in every app, strict about privacy, honest when something cannot work.

## 1. Decisions already made (Pa, 13/11/2026)

| Topic | Decision |
|---|---|
| Platform | macOS only. Windows already has good input methods. |
| Code base | Written from scratch under clean-room rules (05-clean-room.md). No code from XKey, OpenKey, Unikey or other input methods. |
| Brand | Personal project "by Kal", home `{{app-slug}}.kal.vn`, signed with Pa's individual Developer ID. Not a Kalera company product. |
| Distribution | Notarized DMG, Homebrew cask, Sparkle 2 updates signed with EdDSA. No Mac App Store. |
| Funding | Free and open source. Donations via a bank VietQR code (bank name and account number shown, never the holder name; no MoMo, decided later the same day), plus GitHub Sponsors once a sponsor page exists. Polar.sh is not used for donations (its policy forbids them). |
| P0 | The three daily annoyances in 03-product.md section 3.0 (blocked typing in iTerm2, slang `dz` / `hẹo`, English restore only on Space) are release blockers. |
| Slang | `z` and `dz` are accepted slang onsets; `f`, `j`, `w` are not (they would make English words compose). |
| Memory store | The implementation uses a new, empty memory project (05-clean-room.md CLR-R8). |

## 2. Main product and engineering choices in this spec

- **Engine:** pure Swift package, no globals, no AppKit. Telex (default) and VNI, Unicode NFC only. Validity comes from Vietnamese spelling rules (Tier A standard, Tier B names, loans and slang), never from a dictionary. Traditional tone placement by default (`hòa`, `thủy`). Free-order tone keys. English restore on by default with bundled data, decided at every boundary key. No Quick Telex. Macros in v1.
- **Platform:** one menu-bar process, no IMKit bundle in v1. Event tap at session level on its own thread; the callback only decides and enqueues; a serial injection queue keeps key order. Data-driven per-app compatibility rules instead of hard-coded hacks. Fail-open when permission is revoked. Pauses only for real secure input or password fields, and says which app holds secure input.
- **Product:** few settings with right defaults (03-product.md section 4), Control+Shift to switch by default, per-app Vietnamese/English memory, honest diagnostics with one-click redacted bug reports, non-nagging donations, Vietnamese UI first.
- **Quality:** generated corpus of about 238,000 cases, fuzzing with long tokens, per-app automated scenarios, latency gates, an issue policy that closes only after the reporter confirms.
- **Minimum macOS:** 12.0 with Intel support (Pa, 13/11/2026; `docs/decisions/0315-minimum-macos-12.md`).

## 3. Reading order

| File | What it is | Lines (approx.) |
|---|---|---|
| `00-overview.md` | This file | 110 |
| `03-product.md` | Principles, personas, P0 list, scope, defaults, UI, onboarding copy, website | 510 |
| `01-engine.md` | Orthography, key maps, tone placement, composition, restore, API, tests (ENG-R) | 1,320 |
| `02-platform.md` | Process model, event tap, injection strategies, compatibility rules, permissions, privacy, updates, diagnostics (PLT-R) | 860 |
| `04-quality-release.md` | Test strategy, CI, release process, issue policy, support (QA-R) | 340 |
| `05-clean-room.md` | Rules every implementer must follow (CLR-R) | 50 |
| `reference-model/` | Python test oracle used to generate and check engine test data (not shipped) | small |

Implementers read 05 first, then 03 section 3.0, then the file for the part they build.

## 4. Name

Every file uses `{{AppName}}` (display name) and `{{app-slug}}` (ASCII slug: bundle ID `vn.kal.{{app-slug}}`, cask `{{app-slug}}`, site `{{app-slug}}.kal.vn`). The product owner chose the name on 13/11/2026 (`docs/decisions/0005-pa-decisions-2026-11-13.md`). The name lives only in `Config/Brand.xcconfig` and `scripts/brand.env` (renamed with `scripts/rename-app.sh`), so this spec keeps the placeholders and a later rename needs no spec change.

## 5. Open decisions for Pa (consolidated)

All answered on 13/11/2026; the app licence followed the same evening. The full list of answers, with the place that implements each one, is `docs/decisions/0005-pa-decisions-2026-11-13.md`.

| # | Decision | Answer (Pa, 13/11/2026) | Where |
|---|---|---|---|
| 1 | Product name | Chosen; kept only in the brand files | section 4 |
| 2 | App licence (affects contribution rules) | GPL-3.0-or-later for the app; engine packages, `data/` pipeline and reference model MPL-2.0; DCO sign-off with inbound MIT, no CLA; no paid edition, donations and sponsorships only (amended 15/11/2026; `docs/decisions/0006-app-licence-and-pro-edition.md`) | 03 s.18, 02 s.14, 04 s.10 |
| 3 | Engine licence: MIT or Apache-2.0 | MPL-2.0 | ENG Q1 |
| 4 | Default tone placement | Traditional (`hòa`, `thủy`), with the setting | ENG Q2, 03 D2 |
| 5 | Restore-last-word hotkey | Escape by default, with an on/off setting and exclusions through compatibility rules | ENG Q4, 03 D8, PLT-R353 |
| 6 | Minimum macOS | 12.0, Intel kept | 03 PRD-R8, 02 s.14 |
| 7 | Macro triggers limited to printable ASCII, no Vietnamese letters | Yes | ENG Q6, 03 PRD-R29 |
| 8 | Learn from the user's restore toggles automatically | Yes, after two identical signals, stored per app | ENG Q5, ENG-R862 |
| 9 | Attested-syllable source (tie-breaker data only) | Vietnamese legal texts plus reviewed additions | ENG Q7 |
| 10 | Review of the English/Vietnamese ambiguity table (top 300 rows) | Later; unreviewed rows behave as Vietnamese | ENG Q3 |
| 11 | Terminals default mode | Inherit (Vietnamese allowed in TUIs) | 02 s.14 |
| 12 | Chromium/Electron accessibility enabling via rules | Off unless a rule proves no side effect (`axEnable: manual`) | 02 s.14 |
| 13 | Zero-width placeholder for Google Sheets / Excel autocomplete | Only under the PLT-R422 gate; both rules use `axSelection` until it exists | 02 s.14 |
| 14 | Signing and notarization in protected CI vs only on Pa's Mac | On Pa's Mac; CI builds stay unsigned | 02 s.14, 04 QA-R31 |
| 15 | Archive hosting | `{{app-slug}}.kal.vn` only | 02 s.14, PLT-R906 |
| 16 | Self-hosted Mac runner for compatibility automation | Proposed: a tart macOS virtual machine on Pa's Mac (awaiting Pa) | 02 s.14, 04 QA-R12 |
| 17 | IMKit edition later | Decide after spike S1 | 02 PLT-R207, PLT-R398D |
| 18 | Website analytics | Self-hosted Umami, cookieless | 03 PRD-R74 |
| 19 | Donation account details, public sponsor list | Bank VietQR, bank name and account number shown, no holder name; no sponsor list for now | 03 PRD-R59, PRD-R61 |

## 6. Suggested first steps for the implementation repository

1. Create the repository (personal GitHub handle), add the clean-room block from 05-clean-room.md to `CLAUDE.md` / `AGENTS.md`, connect a new memory project.
2. Run spike S1 (PLT-R398D) and the platform VERIFY items that decide architecture (02-platform.md) in the first week.
3. Build the engine package first, test-driven against the generated corpus, the worked examples and the P0 rows (REG-28 to REG-30, B053-B064). Fuzz from day one.
4. Build the event-tap host with the injection queue and the P0-1 secure-input behaviour, then the compatibility rules for the Tier 1 apps (03-product.md section 9).
5. Private alpha only when every P0 test passes (PRD-R0).
