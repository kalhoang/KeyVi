# Runbook: notarization setup

Owner: the maintainer. Specification: QA-R30 steps 5 and 6, QA-R31, PLT-R750. No secret ever goes into the repository, an issue, a log or a chat.

Notarization uses `notarytool` with an **App Store Connect API key**, not an app-specific password (QA-R30 step 5).

## 1. Create the API key

1. Sign in to App Store Connect with the Account Holder or Admin account of Pa's individual developer team.
2. Go to Users and Access, Integrations, Team Keys, and create a key. Name it after its purpose, for example `notarization`. Give it the lowest role that allows notarization (the Developer role has been enough for `notarytool`; VERIFY against the current Apple documentation).
3. Note three values: the **Key ID**, the **Issuer ID** (shown on the same page) and the downloadable `AuthKey_<KEYID>.p8` file. The `.p8` can be downloaded **once**. Store it in the password manager immediately, with the Key ID and Issuer ID.

## 2. Store a `notarytool` keychain profile (local signing on Pa's Mac)

```sh
xcrun notarytool store-credentials "<profile-name>" \
  --key /secure/path/AuthKey_<KEYID>.p8 \
  --key-id "<KEYID>" \
  --issuer "<ISSUER-ID>"
```

- The profile is saved in the login keychain; no secret is written to a file in the repository.
- Name the profile `<slug>-notary`, with the slug from `scripts/brand.env` (for example `source scripts/brand.env; echo "$APP_SLUG-notary"`). `scripts/notarize.sh` uses that profile by default; to use another name, set `NOTARY_KEYCHAIN_PROFILE=<profile-name>` when you run it. `scripts/notarize.sh <file> --dry-run` prints which credential source it would use without contacting Apple.
- After storing, delete the plain `.p8` from any working directory. Keep the password-manager copy.
- Check the profile works without submitting anything:

  ```sh
  xcrun notarytool history --keychain-profile "<profile-name>"
  ```

## 3. CI (only if Developer ID signing and notarization run in CI)

Signing and notarisation run on Pa's Mac (QA-R31; [0005](../decisions/0005-pa-decisions-2026-11-13.md) Q9 closed open decision 14 on 2026-11-13). This section applies only if that decision ever changes; the scripts still support both.

1. In the repository, Settings, Environments, `release`: required reviewer is Pa; deployment restricted to tags on protected branches (QA-R31).
2. Add environment secrets (not repository secrets): `ASC_API_KEY_P8_BASE64` (the base64 of the `.p8` file, `base64 -i AuthKey_<KEYID>.p8 | pbcopy`), `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, plus `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD` for the signing certificate ([certificate renewal](certificate-renewal.md) step 6). These are the names `release.yml` and `scripts/ci-signing.sh` read ([ADR 0503](../decisions/0503-release-pipeline.md)).
3. `scripts/ci-signing.sh setup` decodes the `.p8` into a temporary file and exports its path as `ASC_API_KEY_PATH`; `scripts/notarize.sh` then runs `notarytool submit ... --key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" --wait`. `scripts/ci-signing.sh cleanup` deletes the file and the temporary keychain at the end of the job, even when it fails.
4. Never print the secrets: no `set -x`, no `env`, no echo of the values.

Never put the Sparkle EdDSA key in CI (QA-R32).

## 4. Running a notarization by hand

```sh
xcrun notarytool submit "{{AppName}}.dmg" --keychain-profile "<profile-name>" --wait
xcrun notarytool log "<submission-id>" --keychain-profile "<profile-name>"   # if the status is not Accepted
xcrun stapler staple "{{AppName}}.dmg"
xcrun stapler validate "{{AppName}}.dmg"
spctl --assess --type open --context context:primary-signature --verbose "{{AppName}}.dmg"
```

Staple the app inside the DMG as well as the DMG (QA-R30 step 6). The pipeline fails on any issue in the notarization log, even when the status is Accepted with warnings.

## 5. Common failures

| Symptom | Likely cause | Action |
|---|---|---|
| `Invalid` with "not signed with a valid Developer ID certificate" | Wrong identity (Apple Development instead of Developer ID Application) | Check `security find-identity -v -p codesigning`; rebuild with the release identity |
| "The signature does not include a secure timestamp" | Missing `--timestamp` | Use the build script; it signs with the secure timestamp |
| "The executable does not have the hardened runtime enabled" | Hardened runtime off | Hardened runtime is mandatory with no exceptions (PLT-R908) |
| Unauthorized or 401 | Wrong Key ID, Issuer ID or a revoked key | Recreate the key; update the keychain profile and CI secrets |
| Agreement error | Apple Developer agreement not accepted | Accept it in the developer portal as the Account Holder |
| Long waits | Apple queue | Wait; the job has a timeout; resubmit only after the old submission is final |

## 6. Rotation

Rotate the API key yearly or when anyone who had access leaves: create a new key, store a new profile, update the CI secrets, revoke the old key. Nothing in the repository changes.
