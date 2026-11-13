# Runbook: release

Owner: the maintainer (Pa). Specification: QA-R26 to QA-R37, QA-R40 to QA-R42, PLT-R1101 to PLT-R1110, [spec/04-quality-release.md](../../spec/04-quality-release.md) section 3.

This runbook takes a release from "main is green" to "appcast published and verified". No step is undocumented; if you had to improvise, fix this file in the same change (spec acceptance, section 9).

Brand values (`{{AppName}}`, `{{app-slug}}`, site host, bundle ID) come from `scripts/brand.env`. In the commands below, load them first:

```sh
source scripts/brand.env   # APP_DISPLAY_NAME, APP_SLUG, APP_BUNDLE_ID_RELEASE, APP_SITE_HOST
```

Related runbooks: [rollback](rollback.md), [appcast pull](appcast-pull.md), [key rotation](key-rotation.md), [certificate renewal](certificate-renewal.md), [notarization setup](notarization-setup.md), [self-hosted runner](self-hosted-runner.md).

## 0. One-time prerequisites

Do these once; the sections linked from each line explain how.

- [ ] Developer ID Application certificate in the login keychain ([certificate renewal](certificate-renewal.md)).
- [ ] `notarytool` credentials (App Store Connect API key) ([notarization setup](notarization-setup.md)).
- [ ] Sparkle EdDSA key in the login keychain, with two offline encrypted backups (QA-R32, [key rotation](key-rotation.md)). The public key (`SUPublicEDKey`) and the feed URL are fixed in the app from the first public build (QA-R33).
- [ ] `SPARKLE_PUBLIC_ED_KEY` filled in `Config/Sparkle.xcconfig` with the public key printed by `generate_keys`, as described in the [EdDSA key note of ADR 0304](../decisions/0304-sparkle-version-pin.md#runbook-note-filling-sparkle_public_ed_key). `scripts/verify-release.sh` and `scripts/publish-release` refuse a build whose `SUPublicEDKey` is empty.
- [ ] GitHub environment `release` exists, requires Pa as reviewer, is restricted to tags on protected branches (QA-R31).
- [ ] Self-hosted integration runner registered and healthy ([self-hosted runner](self-hosted-runner.md)).
- [ ] Homebrew tap repository exists (template: `packaging/homebrew/Casks/cask.rb.template`).
- [ ] Rollback rehearsed once on the beta channel before public beta (QA-R39, [rollback](rollback.md) section 5).

## 1. Decide the version and build number

1. Semantic Versioning for `CFBundleShortVersionString` (QA-R26): MAJOR for breaking changes to the settings format or minimum macOS, MINOR for features, PATCH for fixes. Betas: `X.Y.Z-beta.N`.
2. `CFBundleVersion` is a single integer that increases with every build published to any channel, including betas and rollbacks. Sparkle compares this value, not the short version. It is derived from the version, never chosen by hand: `scripts/build-number.sh X.Y.Z` prints it (`MAJOR * 1000000 + MINOR * 10000 + PATCH * 100 + beta N or 99`, [ADR 0503](../decisions/0503-release-pipeline.md) decision 4; for example `0.1.0-beta.1` is 10001 and `0.1.0` is 10099). A rollback ships as a new, higher version.
3. A stable release must have been on beta for at least 72 hours with no new P0 or P1 regression, except a hotfix for a P0 (QA-R29).

## 2. Pre-flight checklist (QA-R30 step 1, section 3.7)

All must be true on the commit you will tag. Record the evidence (links) in the release PR or the release issue.

- [ ] `ci.yml` green on the commit: lint, build, engine corpus on macOS and Linux, app logic tests, coverage, property tests, 60 s fuzz, benchmark compare.
- [ ] Latest `integration.yml` run on this exact commit is green on the newest macOS release available (QA-R12, QA-R23).
- [ ] Latest `nightly.yml` is green within the last 24 hours (fuzz with sanitizers, dependency audit) (spec/02-platform.md sections 13.4 and 13.8).
- [ ] **P0 tests pass** (PRD-R0). A build that fails any P0 test is not released, not even as a private alpha.
- [ ] Tier 1 compatibility script done for this release candidate: [compat/SCRIPT.md](../../compat/SCRIPT.md), results in `compat/matrix.json`. Tier 1 rows are at most 90 days old (QA-R19).
- [ ] Upgrade test passed (section 5 below).
- [ ] Network egress test green: only the allowed host (spec/02-platform.md section 13.7).
- [ ] No compatibility rule is past `reviewBy` by more than 30 days (spec/02-platform.md section 13.8).
- [ ] Provenance review done for the first public release and for 1.0, and a report exists for this release (CLR-R13, [provenance](../provenance/README.md)).
- [ ] `THIRD_PARTY_NOTICES.md` complete (CLR-R6, CLR-R7).
- [ ] `CHANGELOG.md` section written in user-visible language with app names, plus Vietnamese and English release notes.
- [ ] No open P0 issue. No unresolved `update-regression` issue.

## 3. Prepare the release commit

1. Move the `Unreleased` entries of `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD`; leave an empty `Unreleased` section.
2. Write the release notes in both languages: the English section in `CHANGELOG.md` and the Vietnamese section, same heading, in `CHANGELOG.vi.md`. Five lines maximum visible, led by user-visible fixes listed by app name (PRD-R51); `scripts/publish-release` adds the link to the changelog page and warns above five lines. Do not write a donation line into the notes: the release-notes page is shown in the in-app update window, and the website changelog page already ends with the single plain donation line (PRD-R57).
3. Nothing to commit for the version itself: the tag (`vX.Y.Z`) is the version, and `release.yml` passes it and its build number to `scripts/build-release.sh <version> <build>`, which sets `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
4. Merge through a pull request into `main` (branch protection: required checks, linear history, signed commits, no force-push; QA-R25). Patch releases of an older minor come from a `release/x.y` branch.

## 4. Tag and build

Tags are signed and created on the commit you pre-flighted:

```sh
git switch main && git pull --ff-only
git tag -s "vX.Y.Z" -m "X.Y.Z"          # beta: vX.Y.Z-beta.N
git push origin "vX.Y.Z"
```

Pushing a `v*` tag starts `release.yml` (GitHub-hosted macOS, environment `release`). It performs, in order (QA-R30):

1. Re-runs the full `ci.yml` suite on the tagged commit and requires the latest `integration.yml` run on that commit to be green. No test gate means no release.
2. Builds a universal Release archive: hardened runtime, no `get-task-allow`, no unnecessary entitlements, signed with the Developer ID Application certificate.
3. Verifies the signature (`codesign --verify --deep --strict`) and that the designated requirement equals the previous release's (bundle ID and Team ID unchanged). A changed designated requirement makes macOS ask for permissions again: hard failure.
4. Creates the DMG (app plus Applications link, background, signed).
5. Notarizes with `notarytool` using the App Store Connect API key and waits; fails on any issue in the log.
6. Staples the ticket to the app and the DMG; validates with `stapler validate` and `spctl --assess`.
7. Produces SHA-256 checksums and a build provenance attestation (GitHub artifact attestations).
8. Uploads the notarized DMG and update archive as a **draft** GitHub Release.

The job waits for your manual approval of the `release` environment (QA-R31). Approve only after confirming the tag and commit. Certificates are imported into a temporary keychain that the job deletes at the end.

**Doing the same locally** (when signing runs on Pa's Mac instead of CI, open decision 14; the scripts support both). Same order as `release.yml`: the app is notarised and stapled before the DMG is made from it ([ADR 0503](../decisions/0503-release-pipeline.md) decision 2). The Developer ID identity is read from the login keychain; notarisation uses the keychain profile `<slug>-notary` ([notarization setup](notarization-setup.md) section 2):

```sh
source scripts/brand.env
version=X.Y.Z                                   # beta: X.Y.Z-beta.N
build="$(scripts/build-number.sh "$version")"
out="dist/$APP_SLUG-$version"
app="$(scripts/build-release.sh "$version" "$build" | tail -n1)"   # universal, signed, build-info.json
gh release download "v<previous version>" --pattern designated-requirement.txt --dir .build/previous   # skip for the first release
scripts/verify-release.sh --app "$app" --pre-notarization --write-dr "$out/designated-requirement.txt" \
  --previous-dr .build/previous/designated-requirement.txt      # leave out --previous-dr for the first release
scripts/notarize.sh "$app" --log-dir "$out"                     # zip, submit, wait, staple the app
dmg="$(scripts/make-dmg.sh "$app" --out "$out/$APP_SLUG-$version.dmg" | tail -n1)"
scripts/notarize.sh "$dmg" --log-dir "$out"                     # submit, wait, staple the DMG
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$APP_SLUG-$version.zip"   # Sparkle update archive
scripts/verify-release.sh --app "$app" --dmg "$dmg" --previous-dr .build/previous/designated-requirement.txt
(cd "$out" && shasum -a 256 "$APP_SLUG-$version.dmg" "$APP_SLUG-$version.zip" > SHA256SUMS)
```

Inputs and environment of each script are in its header comment. In short: no script needs an environment variable on Pa's Mac; `scripts/notarize.sh` uses `NOTARY_KEYCHAIN_PROFILE` when set (otherwise `<slug>-notary`) and, in CI, `ASC_API_KEY_PATH`, `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`; `scripts/publish-release` uses `SPARKLE_SIGN_UPDATE` when set. Builds made this way carry no GitHub attestation, so publish them with `scripts/publish-release X.Y.Z --skip-attestation`.

## 5. Release candidate checks on the built DMG

Run these on the notarized artefact, not on a debug build.

1. **Fresh install** on macOS 15, 26 and 27 (spec/02-platform.md section 13.5): Gatekeeper passes without a warning; launching from the mounted DMG triggers the move-to-Applications offer and never a permission request.
2. **Upgrade test** (QA-R40, PLT-R1108), on the self-hosted runner or a clean VM:
   1. Install the previous stable from its DMG and grant permissions.
   2. Change at least 10 settings, add per-app rules and 50 macros.
   3. Update through Sparkle (a local appcast pointing at the candidate) to the release candidate.
   4. Verify: settings, rules, per-app memory and macros are identical (byte-identical apart from migrations); permissions are still granted with no new prompt; the tap is active within 2 seconds of relaunch; typing works in the test host within 5 seconds with no user action.
3. **Channel switch**: beta to stable and back.
4. **Tier 1 compatibility script** on the candidate (section 2).
5. **First-launch self-check** (QA-R42): permission state, tap creation; on failure the targeted permission screen shows, not a silent failure.

Any settings loss or permission loss after an update blocks the release (PRD-R52).

## 6. Verify the artefact

```sh
scripts/verify-release.sh --app "$app" --dmg "$dmg" --previous-dr designated-requirement.txt   # previous release's asset
```

`release.yml` runs it twice (before notarisation with `--pre-notarization`, and after stapling). It checks the signature, the Developer ID identity and timestamp, the hardened runtime, empty entitlements, the bundle ID, the universal binary, the designated requirement (expected and unchanged against the previous release), the Sparkle public key, the URL host allowlist and, after notarisation, `stapler validate` and `spctl --assess` for the app and the DMG. The manual equivalents, for a second look:

```sh
codesign --verify --deep --strict --verbose=2 "{{AppName}}.app"
codesign -d -r- "{{AppName}}.app"        # designated requirement: same bundle ID and Team ID as the previous release
codesign -d --entitlements - "{{AppName}}.app"   # no entitlements
spctl --assess --type execute --verbose "{{AppName}}.app"
xcrun stapler validate "{{AppName}}.dmg"
shasum -a 256 "{{AppName}}.dmg"          # must equal the checksum file from the workflow
```

Also confirm the hardened runtime flag is present (`codesign -dv` shows `flags=0x10000(runtime)`), the minimum system version is 15.0, and the app contains only allowed URL hosts (appcast host, site host, GitHub, mail link; QA-R60).

## 7. Publish (on Pa's Mac)

The Sparkle EdDSA private key is never in CI (QA-R32, PLT-R1103). The final step runs locally with the key in the login keychain.

1. Download the draft release's DMG and update archive, or use the locally built ones.
2. **Dry run first**, and read the diff:

   ```sh
   scripts/publish-release X.Y.Z --dry-run            # beta: scripts/publish-release X.Y.Z-beta.N --beta --dry-run
   ```

3. Publish for real:

   ```sh
   scripts/publish-release X.Y.Z                      # beta: add --beta
   ```

   The script, in one pass (QA-R32, QA-R34, QA-R36, QA-R37):
   - signs the update archive with Sparkle's `sign_update` (EdDSA);
   - adds the appcast item to `site/static/appcast.xml` with `sparkle:version` (build integer), `sparkle:shortVersionString`, `sparkle:minimumSystemVersion`, the EdDSA signature and length, one link to the bilingual release-notes page (no `xml:lang` variants, because Sparkle would pick them by the macOS language instead of the app's language; [ADR 0304](../decisions/0304-sparkle-version-pin.md#release-notes-language-amendment-2026-11-13-design-review-finding-15)), and `sparkle:channel="beta"` for betas. Stable releases use phased rollout (`sparkle:phasedRolloutInterval`, for example 24 hours per group; a P0 hotfix may skip it). `sparkle:criticalUpdate` only for security or data-loss fixes (PRD-R54);
   - writes the release-notes page `site/static/release-notes/X.Y.Z/index.html` (Vietnamese first, then English, each with a link to the changelog page; no donation line because the update window shows it, PRD-R57). It needs Vietnamese notes: a `## [X.Y.Z]` section in `CHANGELOG.vi.md`, or `--notes-vi FILE`;
   - writes `site/data/releases.json` (version, build, channel, date, DMG URL, SHA-256, minimum system version, notes in Vietnamese and English), which feeds the download page and changelog;
   - bumps the Homebrew cask in the tap (`auto_updates true`, `depends_on macos: ">= :sequoia"`, `zap` paths per PLT-R1012). Betas do not change the cask.

   The appcast, the website and the cask are updated by this one script so they never disagree.
4. Review `git diff` in the repository (appcast, release-notes page, releases.json), commit and push through a pull request to `main` (`site.yml` builds and deploys the website and appcast when `site/` changes).
5. Un-draft the GitHub Release (mark betas as pre-release).

The appcast URL is one stable address, `https://{{app-slug}}.kal.vn/appcast.xml`. It never moves (PRD-R73, PRD-R75).

## 8. Verify after publishing

- [ ] `curl -sSf https://$APP_SITE_HOST/appcast.xml | xmllint --noout -` passes, and the new item is present with the right channel.
- [ ] The DMG URL in `site/data/releases.json` downloads, and its SHA-256 equals the value on the download page.
- [ ] On a machine with the previous version: "Check for Updates..." offers the new build (manual checks get it immediately even with phased rollout).
- [ ] `brew update && brew install --cask OWNER/tap/{{app-slug}}` works in a fresh shell for a stable release (tap owner: VERIFY).
- [ ] Download page, changelog page and appcast show the same version and date.

## 9. After the release

1. For each fixed issue: label `fixed-in-beta` (with the beta version) or `fixed-in-release` (with the version) and ask the reporter to confirm (QA-R46). Do not close issues because a fix merged.
2. Post a pinned announcement for notable changes.
3. Watch for 24 hours. If a P0 appears: pull the appcast item first, within 1 hour of confirmation ([appcast pull](appcast-pull.md)), then follow [rollback](rollback.md).
4. Keep the signed update archives of the last 3 releases (PLT-R1107) and keep every DMG downloadable from the archive page (QA-R38).
5. First public release and 1.0: record the stage transition and its exit-criteria evidence as an ADR in `docs/decisions/` (PRD-R4).
