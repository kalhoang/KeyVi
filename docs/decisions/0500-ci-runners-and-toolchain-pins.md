# 0500. CI runners and toolchain pins

- Status: accepted, 2026-11-13
- Requirements: QA-R22, QA-R23, QA-R24, QA-R5, PLT-R101, PLT-R910

## Context

QA-R23 asks to pin Xcode with `xcode-select`, record it in build metadata, and VERIFY the runner labels
available at implementation time. PLT-R101 notes that Xcode 27 might still be a preview on hosted runners.
The local development Mac runs Xcode 27.2 (build 27B52) with Swift 6.4.2 on macOS 27.2.

## What was verified (2026-11-13)

Source: `actions/runner-images` README and image readmes (fetched 2026-11-13; image versions 20261102 to 20261104).

| Label | Image | Xcode on the image | Status |
|---|---|---|---|
| `macos-26` / `macos-latest` | macOS 26.7.2 arm64 | 26.0.1 to 26.6 (default 26.6) | GA |
| `macos-15` | macOS 15 arm64 | Xcode 16 line | GA |
| `macos-14` | macOS 14 arm64 | | deprecated, retired for Actions on 2026-11-02 |
| `xcode-27` | macOS 27.0.1 arm64 | 27.0, 27.1 (default), 27.2 (27B52) | public preview |
| `ubuntu-24.04` | Ubuntu 24.04 x64 | | GA (shellcheck preinstalled) |
| `ubuntu-26.04` | Ubuntu 26.04 x64 | | GA |

There is no `macos-27` label yet; macOS 27 is only available through the `xcode-27` preview image.

## Decision

- macOS jobs run on `xcode-27` and select `/Applications/Xcode_27.2.app` with `xcode-select`
  (composite action `.github/actions/select-xcode`, the single place of the pin). Reasons: it is the same
  Xcode and Swift as development, and QA-R23 requires testing on the newest macOS available.
- The selected Xcode, Swift and macOS versions are written to the job summary; `scripts/build-release.sh`
  writes them to `build-info.json`, which is attached to every draft release.
- Linux jobs run on `ubuntu-24.04` inside the official Swift image `swift:6.4.2-noble`, pinned by its
  manifest-list digest `sha256:23d9b28a...e5f4`, so Linux and macOS use the same Swift 6.4.2.
- Downloaded tools are pinned by version and SHA-256: XcodeGen 2.46.0 (`scripts/install-xcodegen.sh`),
  actionlint 1.7.12 (`ci.yml`), Sparkle 2.10.1 tools (`scripts/publish-release`).
- Third-party actions are pinned by full commit SHA with the tag in a comment (resolved with
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag>`; all were lightweight tags pointing at commits):

| Action | Tag | Commit |
|---|---|---|
| actions/checkout | v7.0.1 | 3d3c42e5aac5ba805825da76410c181273ba90b1 |
| actions/upload-artifact | v7.0.2 | cf430e030ddbb5b0abf93d22962f4752f3646cd9 |
| actions/download-artifact | v8.0.2 | 9000827ccba6bdab643e8b6fd33ac0654aef8333 |
| actions/attest-build-provenance | v4.2.2 | 4d101475d8b20a2381f78447822ac1eab6504dd8 |
| actions/setup-node | v7.1.0 | 949feb2413d6458794dcd2491c4babbbce0c15c1 |

- Dependabot updates the action SHAs and SwiftPM pins. It does not track the container digest, XcodeGen,
  actionlint, Sparkle tool pins or the Xcode version: those are bumped by hand together with this record.

## Fallback

If the `xcode-27` preview is withdrawn or unstable, switch every `runs-on: xcode-27` to `macos-26` and the
`select-xcode` default to the newest Xcode 26.x, then run the engine tests on the self-hosted Mac (macOS 27)
until a `macos-27` label is GA. When `macos-27` becomes GA, move to it and keep the Xcode pin explicit.

## Consequences

- Preview images have no SLA; a queue or image problem blocks macOS CI until the fallback is applied.
- `scripts/actionlint.yaml` declares `xcode-27` (and the self-hosted `tcc-granted`) as known labels;
  `.github/actionlint.yaml` mirrors it for a plain `actionlint` run and editor integrations.
- QA-R12 VERIFY (TCC grants on hosted runners) is not resolved here: integration tests stay on the
  self-hosted runner (`integration.yml`).

## Note, 2026-11-18: status and cost of `xcode-27`

Checked in GitHub's public documentation and changelog ([0009](0009-pa-decisions-2026-11-18.md) item 6): `xcode-27`
is a standard GitHub-hosted runner label (Apple silicon, 3 CPU, 7 GB), listed with `macos-15`, `macos-26` and
`macos-latest` among the standard runners for public repositories, and GitHub announced the image as generally
available on 15/10/2026 (the `actions/runner-images` README still called it a preview). Standard GitHub-hosted
runners are free in public repositories; only larger runners such as `xcode-27-xlarge` are billed. The table above
keeps the state of 13/11/2026. The macOS workflows are disabled by the product owner's decision of 18/11/2026, not
because of this label.
