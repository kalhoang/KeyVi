# Runbook: rollback

Owner: the maintainer. Specification: QA-R38, QA-R39, PLT-R1107, spec/02-platform.md section 13.5.

Sparkle does not downgrade. A bad release is handled by (1) stopping further automatic installs, then (2) shipping a new, higher build that contains the last good code. Users who already installed the bad build get the fixed build as a normal update.

## When to use

Use this runbook for a confirmed P0: the user cannot type, text is lost or duplicated across apps, the machine freezes, a security problem exists, or settings are lost on update. For anything less, ship a normal fix.

## 1. First action: stop the bleeding (within 1 hour of confirmation)

Remove the bad item from the appcast. Step by step: [appcast pull](appcast-pull.md). This stops further automatic installs within one check interval (checks are daily, D19). If the release used phased rollout, only part of the users already have it, which is the point of phasing.

Also, immediately:

- Set the website download page and `site/data/releases.json` back to the previous good stable DMG, so the download button does not offer the bad build.
- Mark the GitHub Release for the bad version as a draft or pre-release, with a note.
- Revert the Homebrew cask to the previous good version in the tap.

## 2. Tell users (same day)

1. Publish a **pinned issue** describing the symptom, the affected versions and the workaround, in Vietnamese and English.
2. <a id="website-banner"></a>Enable the **website banner**: in `site/config.json` set `"banner": { "enabled": true, "vi": "<Vietnamese text>", "en": "<English text>", "link": "https://github.com/<owner>/<repo>/issues/<n>" }` (plain text only; the link must be HTTPS), commit to `main`, then deploy it by moving `prod` to that commit ([site deploy](site-deploy.md) section 6). Every page then shows the notice at the top. Set `enabled` back to `false` when the incident is closed, and deploy again.
3. If Pa is unavailable for more than a week, follow QA-R54: banner plus pinned issue with the expected return date; P0 handling during absence is limited to pulling the appcast item.

Response targets for P0 (QA-R52): first response within 24 hours; appcast pull or workaround within 24 hours of confirmation; fix or rollback release within 72 hours.

## 3. Ship the rollback as a new, higher version

Rule: the new build number must be higher than every build ever published (`CFBundleVersion` is monotonic across all channels). Nothing is bumped by hand: the tag is the version, and `release.yml` derives the build number from it with `scripts/build-number.sh` ([release](release.md) section 1, QA-R26). A higher version therefore always gives a higher build: `scripts/build-number.sh 1.4.1` prints `1040199`, and `scripts/build-number.sh 1.4.0` prints `1040099`.

Example (bad release 1.4.0, last good 1.3.2, so the rollback is 1.4.1 built from the 1.3.2 code):

```sh
git fetch --tags
git switch -c release/1.4 v1.3.2
# add the CHANGELOG.md and CHANGELOG.vi.md sections for 1.4.1: "Reverted to the 1.3.2 behaviour because of <symptom>."
git commit -m "chore: roll back to 1.3.2 code as 1.4.1"
git tag -s v1.4.1 -m "1.4.1 (rollback of 1.4.0)"
git push origin release/1.4 v1.4.1
```

The branch is named `release/<major>.<minor>` of the new version (here `release/1.4`), never with the patch number: `release.yml` accepts a tag only on `origin/main` or `origin/release/x.y` and fails at its first gate otherwise (QA-R25). If `release/1.4` already exists, check it out and bring the 1.3.2 code onto it with a new commit (for example `git revert` of the 1.4.0 changes) instead of creating it; never force-push a release branch.

Then follow [release](release.md) sections 4 to 8 for `v1.4.1`, without the tag commands of section 4: the tag pushed above already started `release.yml`. Pre-flight still applies, including the upgrade test. A P0 hotfix may skip phased rollout and the 72-hour beta wait (QA-R29, QA-R35) with `scripts/publish-release X.Y.Z --p0-hotfix`, but never the test gate (QA-R30).

If a clean forward fix is faster and safe, ship the fix as the new version instead; the rollback build is the fallback, not a requirement.

Settings compatibility: the settings schema is backward-readable for one MINOR version, and unknown newer fields are preserved, not dropped (PLT-R1002, PLT-R1007). Check that the rollback build can read settings written by the bad build; if it cannot, state this in the pinned issue.

## 4. Keep the old versions reachable

Every previous DMG stays downloadable from the archive page so a user can reinstall manually; reinstalling an older version must keep settings (QA-R38 step 4). Do not delete release assets.

## 5. Rehearsal (QA-R39)

The rollback must be rehearsed once on the beta channel before the public beta. Procedure (spec/02-platform.md section 13.5):

1. Publish beta `0.9.0-beta.1` (or the current beta N) through [release](release.md).
2. Install it on a test Mac and confirm the update arrives.
3. Publish a deliberately bad beta N+1 (for example, a build flagged only in its release notes as a drill; do not ship real breakage).
4. Pull the N+1 item from the appcast ([appcast pull](appcast-pull.md)) and time each step.
5. Publish N+2 built from the N source (section 3): for example, tag `v0.9.0-beta.3` on a `release/0.9` branch created from the `v0.9.0-beta.1` tag; its higher beta number gives it a higher build number.
6. Confirm the client on N+1 moves to N+2 and that settings are intact.
7. Record the drill below and fix this runbook for anything that was unclear.

| Date | Channel | From, bad, fixed | Time to pull (min) | Time to fixed build (min) | Problems found | By |
|---|---|---|---|---|---|---|
| (not yet rehearsed) | | | | | | |

## 6. After the incident

- Add a failing test for the cause first (QA-R3), then fix it on `main`.
- Label the issues `update-regression` where settings or permissions were lost, and `reopened` where applicable.
- Write a short post-mortem in `docs/decisions/` if the incident changes a process.
