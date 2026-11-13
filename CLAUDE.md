# Project instructions (agents and humans)

## Clean-room rule (mandatory)
This project is an independent implementation. Do not read, fetch, search or quote the source code of any
other Vietnamese input method (XKey, OpenKey, Unikey, PHTV, Vikey, LibreKey, EVKey, GoTiengViet, Gõ Nhanh,
vi-rs, bamboo-core, VietTelex, or forks). Work only from spec/ and public documentation (Apple, Unicode,
Vietnamese orthography). If generated code resembles another project, discard it and rewrite from the spec.
See spec/05-clean-room.md.

Never open, inspect, disassemble, `strings`, `class-dump` or read the preferences or containers of an installed
input method. Do not search memory stores for notes about other input methods' internals; if a recalled memory
shows code or data structures of another input method, stop reading it and do not use it.

## What this is
A Vietnamese input method for macOS (menu-bar app with an event tap), written from scratch.
`spec/` is the single source of truth. Reading order: `spec/05-clean-room.md`, `spec/03-product.md` section 3.0
(P0 list), then the file for the part you build (`01-engine.md`, `02-platform.md`, `04-quality-release.md`).
Requirement IDs (ENG-R, PLT-R, PRD-R, QA-R, CLR-R) must be cited in code comments and tests where a
requirement drives a non-obvious behaviour.

## Name
The product name is "KeyVi" (slug `keyvi`), chosen by Pa on 2026-11-13. The only source is `Config/Brand.xcconfig`
(and `scripts/brand.env` for scripts). Never hard-code the display name, slug, bundle ID or site host in Swift,
UI strings, docs templates or scripts; read them from the bundle (`Brand` helper) or the brand files.
UI strings take the app name as a format argument. `scripts/rename-app.sh` must keep working.

## Layout
| Path | Contents |
|---|---|
| `Packages/VietnameseEngine/` | MPL-2.0 engine package: `VietnameseEngine` (stdlib only), `VietnameseEngineData`, `VietnameseEngineTesting`, `lexicon-builder` |
| `Packages/AppCore/` | Platform modules without UI: Diagnostics, SettingsStore, CompatRules, Injection, InputHost, TestSupport, CompatHarness |
| `App/` | Menu-bar app target (AppKit + SwiftUI), resources, String Catalog, Sparkle wrapper |
| `TestHost/` | Test host app for platform integration tests (QA-R10) |
| `compat/` | `rules.json` (behaviour, shipped as `compat-rules.json`), `matrix.json` (verification status), schemas, `SCRIPT.md` |
| `data/` | Pinned inputs and build scripts for bundled word lists (ENG-R810) |
| `scripts/` | Build, lint, release and publish scripts |
| `site/` | Static website (vi at `/`, en at `/en/`) |
| `docs/` | `decisions/` (ADRs), `architecture/`, `runbooks/`, `provenance/`, `support/` |

## Commands
- Engine: `cd Packages/VietnameseEngine && swift build && swift test`
- AppCore: `cd Packages/AppCore && swift build && swift test`
- App: `xcodegen generate && xcodebuild -project App.xcodeproj -scheme App -configuration Debug build` (the `.xcodeproj` is generated, not committed; internal target/scheme names are brand-neutral: `App`, `TestHost`, `SpikeIMK`)
- Lint: `scripts/lint.sh` (swift-format, bundle-ID literal lint, log interpolation lint, URL host allowlist)
- When several agents build the same package at once, use a private scratch path: `swift build --scratch-path .build-<name>`.

## Engineering rules
- Swift 6 language mode, complete strict concurrency. No global or static mutable state in the engine (ENG-R1202).
- Every source file starts with an SPDX header: engine packages, the `data/` pipeline and `spec/reference-model` `MPL-2.0`;
  everything else `GPL-3.0-or-later` (Pa, 2026-11-13; `docs/decisions/0006-app-licence-and-pro-edition.md`). Root `LICENSE`
  is the verbatim GPL-3.0 text (never edit it); the MPL-2.0 parts carry their own `LICENSE`. Contributions need a DCO sign-off;
  contributions to GPL parts are also licensed to the project under MIT (`CONTRIBUTING.md` section 3).
- No per-app branches in code: bundle IDs live only in `compat/rules.json`, test fixtures and the
  conflicting-apps list (PLT-R501).
- Privacy: never log, print or persist typed content (PLT-R901, ENG-R1220). Typed logging API only.
- The tap callback does no I/O, AX, locks that can block, sleeps or allocations in steady state (PLT-R304/305).
- Tests first (QA-R3). Swift Testing for new tests. Engine coverage at least 95 %, app logic at least 80 % (QA-R2).
- Product UI copy follows `spec/03-product.md` verbatim where a draft exists; new copy is standard, neutral
  Vietnamese addressed to "bạn" (PRD-R62). Code comments and commit messages are English.
- Commits: English Conventional Commits (`type: description`). No AI attribution or Co-authored-by lines.
  Keep the history intact (CLR-R12): no squashing of early history.
