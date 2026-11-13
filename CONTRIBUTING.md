# Contributing to {{AppName}}

Thank you for helping. This project has one maintainer, so the rules below are deliberately short and mechanical. Everything here is binding for every contribution, whatever tools were used to write it.

Read first: [spec/05-clean-room.md](spec/05-clean-room.md) (clean-room rules), then [spec/README.md](spec/README.md). Requirement IDs (ENG-R, PLT-R, PRD-R, QA-R, CLR-R) come from the specification and should be cited in code comments and tests where a requirement drives a non-obvious behaviour.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), never through public issues.

## 1. Before you start

1. Search existing issues and Discussions. Questions and ideas go to GitHub Discussions; bugs and compatibility reports go to issues, using the forms (blank issues are disabled).
2. For anything beyond a typo fix, open or pick an issue first. A PR must reference one (QA-R63).
3. Do not add dependencies or settings without the written justification described in section 7.

## 2. Clean-room rule and attestation (QA-R62, CLR-R14)

{{AppName}} is an independent implementation. You MUST NOT read, open, fetch, search or quote the source code of any other Vietnamese input method while writing a change. This includes XKey, OpenKey, Unikey (and ibus-unikey, fcitx-unikey), PHTV, Vikey, LibreKey, EVKey, GoTiengViet, Gõ Nhanh, vi-rs, bamboo-core, VietTelex and any fork, and includes GitHub web views, raw URLs, code-search results and snippets quoted in blog posts or AI answers.

Allowed sources: this repository's `spec/`, Apple documentation, the Unicode standard, public descriptions of Vietnamese orthography and of the Telex and VNI conventions, and general Swift and macOS knowledge. Behavioural facts about other products that come from public bug reports, release notes or observing a running app are fine; their code is not (CLR-R5).

Every PR carries this attestation, and PRs from contributors who cannot tick it are declined politely:

> I did not read or copy code from other Vietnamese input methods while writing this change (see spec/05-clean-room.md).

If an AI assistant produced code that looks like it comes from a known input method (identifiers, comments, table layouts or bit layouts that were not designed here), discard it and rewrite it from the spec (CLR-R4).

Word lists, dictionaries and test corpora need a recorded permissive licence (MIT, BSD, Apache-2.0, CC0, CC-BY or public domain). GPL or LGPL data must not be bundled or downloaded (CLR-R6). Icons, images and copy must be original or properly licensed, with the source recorded (CLR-R7).

Process details for the similarity review that the maintainer runs before public releases: [docs/provenance/README.md](docs/provenance/README.md).

## 3. Sign-off and licences (QA-R61)

| Area | Licence | Sign-off |
|---|---|---|
| `Packages/VietnameseEngine/` (and the fuzz package `Packages/VietnameseEngineFuzz/`, VERIFY against its own `LICENSE`) | MPL-2.0 (SPDX `MPL-2.0`) | Developer Certificate of Origin: add `Signed-off-by: Your Name <you@example.com>` to every commit with `git commit -s`. A DCO check (`scripts/check-dco.sh`) enforces it on pull requests from forks; the e-mail must match the commit author. |
| Everything else (app, AppCore, TestHost, scripts, site, docs) | **Pending.** The app licence is an open decision (spec/00-overview.md section 5, item 2). Source files carry `SPDX-License-Identifier: LicenseRef-App-Pending`. | **External pull requests to these areas are not accepted until the licence and the sign-off method (DCO or CLA) are decided and this section is updated.** Issues, compatibility reports and discussion are welcome now. |

The DCO sign-off also confirms that you followed the clean-room rule above (CLR-R14). The reasoning is recorded in [docs/decisions/0401-interim-contribution-policy.md](docs/decisions/0401-interim-contribution-policy.md).

Every source file starts with an SPDX header (CLR-R11). The engine package uses `MPL-2.0`; everything else uses `LicenseRef-App-Pending`.

## 4. Build and test commands

Run from the repository root. Each test layer has one command (QA-R1). Hosted CI runs layers 1 to 4; layers 5 to 7 need permissions or real apps.

| # | Layer | Command | Where it runs |
|---|---|---|---|
| 1 | Engine unit tests (Swift Testing) | `cd Packages/VietnameseEngine && swift build && swift test` | Everywhere, macOS and Linux |
| 2 | Engine corpus tests (`Tests/Corpus/`, data files) | Included in the engine `swift test` run above | Every PR, macOS and Linux (QA-R5) |
| 3 | Property tests and fuzzing | Property tests are part of the engine `swift test`; coverage-guided fuzzing uses the package in `Packages/VietnameseEngineFuzz/` on a Linux toolchain (see its README) | Per PR (60 s), nightly (30 min per method) |
| 4 | App logic tests | `cd Packages/AppCore && swift build && swift test` | Everywhere, no permissions needed |
| 5 | Platform integration tests against `TestHost/` | `scripts/run-tests.sh` (see the header of the script for the integration option) | Self-hosted Mac only, permissions granted ([runbook](docs/runbooks/self-hosted-runner.md)) |
| 6 | Compatibility checks on real apps | Follow [compat/SCRIPT.md](compat/SCRIPT.md) by hand | Maintainer or community, results recorded in `compat/matrix.json` |
| 7 | Upgrade tests | Release runbook, step "Upgrade test" ([docs/runbooks/release.md](docs/runbooks/release.md)) | Self-hosted runner or clean VM, before every release |

Other commands:

```sh
# App (the .xcodeproj is generated, never committed)
xcodegen generate
xcodebuild -project App.xcodeproj -scheme App -configuration Debug build
# Updater unit tests (no TEST_HOST, so the app is never launched); locally add -derivedDataPath under /tmp
xcodebuild -project App.xcodeproj -scheme App -configuration Debug -destination 'platform=macOS' \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY='' test -only-testing:UpdaterTests

# Lint: swift-format, bundle-ID literal lint, log interpolation lint, URL host allowlist
scripts/lint.sh

# Everything the hosted CI runs, locally
scripts/run-tests.sh

# Reproducibility of the bundled word-list data (ENG-R810)
swift run --package-path Packages/VietnameseEngine lexicon-builder check

# Engine benchmark compared with the stored baseline
scripts/bench-compare.sh

# Engine API documentation (DocC, QA-R66, ADR 0402), macOS with Xcode; open the archive in Xcode
(cd Packages/VietnameseEngine && xcodebuild docbuild -scheme VietnameseEngine \
  -destination 'generic/platform=macOS' -derivedDataPath .build/docc)
# output: Packages/VietnameseEngine/.build/docc/Build/Products/Debug/VietnameseEngine.doccarchive

# Website
node site/test.mjs    # site tests: links, anchors, privacy rules, the help anchors the app opens
node site/build.mjs   # output in site/dist
node deploy/site/test.mjs   # the site container's nginx headers match site/static/_headers (ADR 0602)
```

When several builds of the same package run at once (from several terminals, for example), use a private scratch path: `swift build --scratch-path .build-<name>`.

Coverage targets (QA-R2): engine at least 95 %, app logic modules at least 80 %. A drop of more than 1 point fails the check.

## 5. Tests first (QA-R3)

- Write the failing test first, then the fix. Every bug fix adds a failing test first (an engine corpus line, an app logic test or a compatibility script step) that references the issue number.
- A bug-fix PR without a test is not merged unless the PR explains why it cannot be tested and adds a compatibility script step instead.
- A new per-app profile comes with an integration test that reproduces the app's behaviour in `TestHost/`, not only a data entry (QA-R21).
- New tests use Swift Testing.

### Corpus changes and performance baselines

- A corpus case may change its expected output only in a PR labelled **`corpus-change`**, with the reason in the PR description. Bulk regeneration of expected values without review is forbidden (QA-R6).
- The performance baseline file changes only in a PR labelled **`perf-baseline`**, with the reason (QA-R15). Never change a baseline to make a regression pass.

## 6. Formatting, commits and pull requests

**Formatting.** Swift 6 language mode with complete strict concurrency. Formatting follows the repository's swift-format configuration; `scripts/lint.sh` must pass. Code comments and commit messages are in English.

**Conventional Commits** in English: `type: description`, with type one of `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`. Examples: `fix: keep Return until the restore edit is delivered`, `docs: explain secure input hint for iTerm2`. Keep the history intact: no squashing of early history and no history rewriting on shared branches (CLR-R12).

**Pull requests (QA-R63) MUST:**

1. Reference an issue, except for typo fixes.
2. Include tests as described in section 5.
3. Pass CI.
4. Follow the formatting configuration.
5. Use English Conventional Commits.
6. Not add dependencies without a decision record in `docs/decisions/`.
7. Not add settings without a written justification against PRD principle 5 (few settings, [spec/03-product.md](spec/03-product.md) section 1).

Fill in the pull request template completely, including the clean-room attestation and, for sensitive areas, the security review checklist (QA-R59).

Rules that code review will check (details in [CLAUDE.md](CLAUDE.md)):

- No per-app branches in code: bundle IDs live only in `compat/rules.json`, test fixtures and the conflicting-apps list (PLT-R501).
- Never log, print or persist typed content (PLT-R901, ENG-R1220). Use the typed logging API.
- No new network endpoint without a decision record and an update to the privacy page in the same PR (QA-R60).
- The event tap callback does no I/O, Accessibility calls, blocking locks, sleeps or steady-state allocations (PLT-R304, PLT-R305).
- Never hard-code the product name, slug, bundle ID or site host; they come from `Config/Brand.xcconfig` and `scripts/brand.env`.

## 7. Dependencies and settings

- The only runtime dependency is Sparkle 2. Any other dependency needs a decision record (QA-R24) and an entry in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The engine package depends on the Swift standard library only.
- A new setting needs a written justification: why real users need both values, and why a better default or per-app data is not enough. "Turn on setting X" as a support answer is a bug in the defaults.

## 8. Documentation is part of done (QA-R67)

A PR that changes user-visible behaviour updates the relevant user document and `CHANGELOG.md` in the same PR. Changelog entries are written in user-visible language and name the apps involved. A PR that changes a process (release, support, security) updates the matching file in `docs/runbooks/` or `docs/support/`.

## 9. AI-assisted contributions (QA-R64)

AI-assisted contributions are welcome under exactly the same rules. You are responsible for provenance (CLR-R4): you must be able to attest that nothing in the change came from another Vietnamese input method's code. Do not point an assistant at those projects, and do not paste code from a chat answer whose origin you cannot explain. Agent instructions are in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).

## 10. Compatibility reports

Use the "Compatibility report" issue form. The 12-step script takes under 3 minutes per app: [compat/SCRIPT.md](compat/SCRIPT.md). A maintainer confirms a community result before the status becomes "Hoạt động tốt" (QA-R20).

## 11. Questions

GitHub Discussions. Please do not send support requests by private message on social networks.
