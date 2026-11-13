# 0503. Release pipeline, build numbers and repository settings

- Status: accepted, 2026-11-13
- Requirements: QA-R25, QA-R26, QA-R28, QA-R30, QA-R31, QA-R32, QA-R13, PLT-R750, PLT-R1103, PLT-R1104

## Decisions

1. **Developer ID signing and notarisation run in CI** inside the GitHub environment `release`
   (open decision 14 keeps both options; `scripts/build-release.sh`, `make-dmg.sh`, `notarize.sh` and
   `verify-release.sh` also work on Pa's Mac with a keychain identity and `NOTARY_KEYCHAIN_PROFILE`).
   **EdDSA signing never runs in CI** (QA-R32): `release.yml` stops at a draft GitHub Release and Pa runs
   `scripts/publish-release` locally.

2. **Two notarisations per release.** The app is zipped and notarised first and the ticket is stapled to
   the app; then the DMG is built from the stapled app, signed, notarised and stapled. This keeps the copy
   a user drags out of the DMG stapled (Gatekeeper works offline on first launch) and makes the update
   archive (a zip of the stapled app) self-contained. It costs a few minutes more than QA-R30's single
   pass and satisfies every step of it.

3. **Designated requirement check.** `verify-release.sh` compares the app's designated requirement with
   the expected default requirement for `APP_BUNDLE_ID_RELEASE` and the team in `Config/Signing.xcconfig`,
   and with the previous release's requirement, read from the `designated-requirement.txt` asset that
   every draft release carries. Any difference fails the job (QA-R30 step 3).

4. **Build numbers derive from the version** (`scripts/build-number.sh`):
   `MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + (beta N or 99)`. Example: `0.1.0-beta.1` is 10001,
   `0.1.0` is 10099, `1.4.1` is 1040199. No stored counter, reproducible on CI and on Pa's Mac, and the
   order matches SemVer, so a stable hotfix of an older minor (built while a beta of the next minor is
   out) gets a lower build number than that beta. Sparkle then does not offer the hotfix to beta users,
   which is what QA-R28 wants ("Beta users also receive stable releases that are newer than the latest
   beta"). Within one channel the number always increases (QA-R26). Limits: MINOR and PATCH at most 99,
   beta 1 to 98. The appcast helper rejects a duplicate build and a build lower than the newest build of
   the same channel.

5. **Release gates** in `release.yml`: tag commit on `main` or `release/x.y`; no `unimplemented(` call left
   in `Packages/AppCore/Sources` or `App/Sources` (`scripts/check-unimplemented.sh`, the definition in
   `AppModel` excluded; `ci.yml` only reports the count); the full `ci.yml` suite
   (reusable workflow); the latest `integration.yml` run on the commit green (waits for a running one,
   `scripts/require-integration-green.sh`); rules `reviewBy` not more than 30 days overdue (PLT-R506);
   for stable releases, Tier 1 compatibility rows verified within 90 days (section 13.8).

6. **Artefacts of a draft release:** `<slug>-<version>.dmg`, `<slug>-<version>.zip` (Sparkle update
   archive, unsigned by EdDSA), `SHA256SUMS`, `designated-requirement.txt`, `build-info.json` (Xcode, Swift,
   macOS, commit), the notarisation logs, and GitHub build provenance attestations for the DMG and zip.
   `scripts/publish-release --from-github` verifies the sums and attestations before signing.

## Repository settings Pa must apply (not done by this track)

- Environment `release`: required reviewer Pa; deployment rule "selected tags" `v*`; secrets
  `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`,
  `ASC_API_ISSUER_ID` stored in the environment only. The App Store Connect key needs the Developer role.
- Tag ruleset: only Pa may create or delete `v*` tags.
- Branch protection on `main` (QA-R25): required checks from `ci.yml` (`Engine on Linux`, `Scripts and
  workflows`, `Architecture contracts in sync`, `macOS lint, tests and coverage`, `macOS universal Debug
  build (unsigned)`, and `DCO sign-off on engine commits (external pull requests)`, which reports
  "skipped", and therefore passes, on pull requests that do not come from a fork; ADR 0401), linear
  history, signed commits, no force push.
- Self-hosted runner (QA-R13): register the integration Mac with labels `self-hosted, macOS, ARM64,
  tcc-granted` in a runner group limited to this repository and to the workflow `integration.yml`; in
  Actions settings require approval for all outside collaborators and keep "Run workflows from fork pull
  requests" off for private forks.
- Environment `site` (optional) and repository variable `SITE_DEPLOY_TARGET` once hosting is chosen.

## Consequences

- A release takes two manual actions by Pa: approving the `release` environment, then running
  `scripts/publish-release` on his Mac. A compromised GitHub account can at most create a draft release;
  it cannot ship an auto-update.
- Changing the build number scheme later must keep numbers increasing; record it in a new decision.
