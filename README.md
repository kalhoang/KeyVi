# KeyVi™

[Tiếng Việt](README.vi.md)

KeyVi™ is a Vietnamese input method for macOS, written from scratch by Kal. It is a menu-bar app that types Vietnamese (Telex or VNI) in any app, restores English words automatically, and tells you plainly when something cannot work.

> **Name:** the product name and its identifiers (slug, bundle IDs, website host) come from [`Config/Brand.xcconfig`](Config/Brand.xcconfig) and [`scripts/brand.env`](scripts/brand.env).

## Status

**Pre-alpha. There is no public download yet.**

The first milestone is a private alpha (Kal plus up to 10 invited testers). It starts only when the engine corpus is green, fuzzing is clean and onboarding is usable, and it requires every P0 test to pass (PRD-R0). The three P0 items are the reason this project exists:

1. Typing is never blocked "at random": the app pauses only for the operating system's secure-input state or a real password field, and says which app holds secure input.
2. Slang such as `dzô` and `hẹo` can be typed: validity comes from the rules of Vietnamese spelling, not from a dictionary.
3. Automatic return to English works on every boundary key (punctuation, Return, Tab), not only on Space.

The roadmap (private alpha, closed beta, public beta, 1.0) and its entry and exit criteria are in [spec/03-product.md](spec/03-product.md) section 3.3. This README makes no claim beyond the specification.

## What it is

- Telex and VNI typing with Unicode (NFC) output.
- Automatic English restore with bundled data, no download.
- Per-app Vietnamese/English memory and per-app rules.
- Macros (text expansion).
- A menu-bar indicator, onboarding with a practice field, a small Settings window.
- Diagnostics and a one-click bug report that never contain typed content.
- Updates through Sparkle 2, with stable and beta channels.
- Vietnamese and English interface.

The full scope and the list of things that are deliberately not built are in [spec/03-product.md](spec/03-product.md) sections 3.1 and 3.2.

## Install

Both options are placeholders until the first public build exists.

| Method | Command or link |
|---|---|
| Notarized DMG | Download from `https://keyvi.kal.vn/tai-ve` (not available yet) |
| Homebrew tap | `brew install --cask OWNER/tap/keyvi` (tap owner: VERIFY) |

Requirements: macOS 12 Monterey or later, Apple silicon or Intel (universal binary) (PRD-R8, [ADR 0315](docs/decisions/0315-minimum-macos-12.md)).

Move the app to `/Applications` before the first launch. The app offers to move itself and never asks for permission while it runs from the DMG or another temporary location.

## Privacy

- Typed content never leaves your Mac and is never written to disk. The only exception is a typing trace for a bug report that you start by hand: 60 to 180 seconds, visible countdown, reviewed by you before sharing, deleted after 24 hours, never sent automatically.
- The only automatic network traffic is the update check (the appcast and update archives on `keyvi.kal.vn`).
- No telemetry, no analytics, no crash-reporting service, no remote configuration.
- Diagnostics contain no typed characters, words, macro contents, clipboard contents or window titles.

Details: [spec/03-product.md](spec/03-product.md) principle 4 and section 11, [spec/02-platform.md](spec/02-platform.md) section 9. The public privacy page is `/rieng-tu` on the website.

## Permissions

| Permission | Why | When |
|---|---|---|
| Accessibility (named "Device Control and Data Access" on macOS 27) | Receive key presses, post the corrected text, read which field has focus | Always, requested in onboarding |
| Input Monitoring | Only if macOS refuses the keyboard tap without it | Only if needed, and the app says so explicitly |

No other permission is requested: no Automation, Screen Recording, Full Disk Access, Contacts, camera or network access beyond the update check. Password fields are always passed through untouched. If a permission is missing or revoked, the keyboard keeps working normally and the menu shows what to do (fail open).

Details: [spec/02-platform.md](spec/02-platform.md) section 7. IT administrators who pre-approve the permissions with a device management profile: see [Managed Macs](docs/support/managed-macs.md).

## Build from source

Requirements: macOS with the Xcode version pinned by the project (recorded in the CI workflow), [XcodeGen](https://github.com/yonaskolb/XcodeGen), Swift 6.

```sh
# Engine (MPL-2.0, stdlib only, also builds on Linux)
cd Packages/VietnameseEngine && swift build && swift test

# App logic (no UI, no permissions needed)
cd Packages/AppCore && swift build && swift test

# App (the .xcodeproj is generated and not committed)
xcodegen generate
xcodebuild -project App.xcodeproj -scheme App -configuration Debug build

# Lint
scripts/lint.sh
```

All layers, the coverage targets and the contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository map

| Path | Contents |
|---|---|
| `Packages/VietnameseEngine/` | The typing engine (MPL-2.0) |
| `Packages/AppCore/` | Platform modules without UI |
| `App/`, `TestHost/` | Menu-bar app and the test host app |
| `compat/` | Per-app behaviour rules, verification matrix, [compatibility script](compat/SCRIPT.md) |
| `data/` | Pinned inputs for bundled word lists |
| `site/`, `deploy/site/`, `deploy/umami/` | The website (Vietnamese at `/`, English at `/en/`), its container for the Kalera Docker Swarm ([site deploy runbook](docs/runbooks/site-deploy.md)) and its self-hosted, cookieless analytics ([analytics runbook](docs/runbooks/analytics.md)) |
| `docs/` | [Decisions](docs/decisions/), [architecture](docs/architecture/), [runbooks](docs/runbooks/release.md), [support replies](docs/support/replies.md), [managed Macs](docs/support/managed-macs.md), [provenance](docs/provenance/README.md) |
| `spec/` | The specification, the single source of truth |

## Licence and provenance

- KeyVi™ is free software under the GNU General Public License, version 3 or (at your option) any later version: [LICENSE](LICENSE). Copyright (c) 2026 the KeyVi authors.
- The Vietnamese engine packages, the word-list pipeline and the reference model are under the Mozilla Public License 2.0 (MPL-2.0): any app, open source or not, can embed them, while changes to their own files stay open: [Packages/VietnameseEngine/LICENSE](Packages/VietnameseEngine/LICENSE), [Packages/VietnameseEngineFuzz/LICENSE](Packages/VietnameseEngineFuzz/LICENSE), [data/LICENSE](data/LICENSE), [spec/reference-model/LICENSE](spec/reference-model/LICENSE). Their copyright lines are in the `NOTICE` files beside them.
- Contributions are signed off (Developer Certificate of Origin); every contribution is also licensed to the project under MIT, with no CLA ([CONTRIBUTING.md](CONTRIBUTING.md) section 3, [ADR 0006](docs/decisions/0006-app-licence-and-pro-edition.md)).
- KeyVi™ is an independent implementation written under clean-room rules: [spec/05-clean-room.md](spec/05-clean-room.md). Third-party components: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Links

- Specification: [spec/README.md](spec/README.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reports: [SECURITY.md](SECURITY.md)
- Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Website: `https://keyvi.kal.vn`
- Support: GitHub Issues for bugs and compatibility, GitHub Discussions for questions
