# 0402. Engine API documentation (DocC)

- Status: accepted, 2026-11-13; item 4 confirmed by Pa on 2026-11-13 (nightly artifact only, not published)
- Spec: QA-R66 (engine API docs, DocC, generated from the engine package, for integrators), QA-R24 (no new dependency without a decision record), QA-R22 (nightly checks)

## Context

The public API of the engine package carries DocC comments (`Packages/VietnameseEngine/Sources/VietnameseEngine/PublicAPI.swift` and the orthography API), but no script, workflow or documented command generated the documentation, so the QA-R66 row "Engine API docs (DocC), generated from the engine package" was unmet.

## Decision

1. **Generator: Xcode's DocC, no new dependency.** `xcodebuild docbuild` builds the documentation straight from the SwiftPM package with the DocC compiler that ships with the pinned Xcode ([ADR 0500](0500-ci-runners-and-toolchain-pins.md)). The `swift-docc-plugin` package would be a new dependency and would need its own decision under QA-R24; it is not used. The command, documented in `CONTRIBUTING.md` section 4:

   ```sh
   (cd Packages/VietnameseEngine && xcodebuild docbuild -scheme VietnameseEngine \
     -destination 'generic/platform=macOS' -derivedDataPath .build/docc)
   ```

   Output: `Packages/VietnameseEngine/.build/docc/Build/Products/Debug/VietnameseEngine.doccarchive` (ignored by git), which Xcode opens. Checked on 2026-11-13 with Xcode 27.2 on macOS 27.2: about 16 seconds, no warnings.
2. **Scope: the `VietnameseEngine` library**, the stable public API of spec/01-engine.md section 12.2. `VietnameseEngineData` and `VietnameseEngineTesting` are added (one `-scheme` each) when their API is offered to integrators.
3. **Nightly artifact.** The nightly workflow builds the archive on the macOS runner and uploads it as the artifact `engine-api-docc` (30 days), so a broken doc build shows up within a day and integrators can download a current archive. The job is `engine-docc` in `.github/workflows/nightly.yml` ("Engine API docs (DocC, QA-R66)").
4. **Not published on the website** (Pa, 2026-11-13). The website serves end users in Vietnamese and English; the API documentation is English only and for integrators. A static DocC site also embeds the DocC web renderer (`swift-docc-render`, Apache-2.0), whose files would then need an entry in `THIRD_PARTY_NOTICES.md` section 5. If Pa decides to publish, transform the archive with `xcrun docc process-archive transform-for-static-hosting <archive> --output-path <dir> --hosting-base-path engine-api`, serve it under `/en/engine-api/`, and add that notices entry in the same change.

## Consequences

- QA-R66 is met by a documented command and a downloadable nightly archive.
- No runtime or build dependency is added; Linux contributors cannot build the documentation (DocC through `xcodebuild` needs macOS), which is acceptable because the engine's Linux CI covers build and tests.
- Publishing remains a one-step change with a known command when Pa wants it.
