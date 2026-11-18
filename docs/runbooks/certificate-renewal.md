# Runbook: Developer ID certificate renewal

Owner: the maintainer (the Apple Developer account holder). Specification: PLT-R750, PLT-R751, QA-R30 step 3, QA-R31.

Every user-facing build is signed with Pa's Developer ID Application certificate (individual team), with hardened runtime and a secure timestamp, notarized and stapled. The Team ID is in `Config/Signing.xcconfig` and must never change. The bundle ID and Team ID must never change either, because macOS permission grants (TCC) follow the app's designated requirement: bundle identifier plus the Team ID anchor, not the certificate serial number.

Consequence: renewing a certificate within the same team keeps the designated requirement the same, so users keep their permissions. A new Apple Developer team would not.

## Calendar

| Item | Typical lifetime | Reminder |
|---|---|---|
| Developer ID Application certificate | 5 years (VERIFY the expiry shown in the Apple Developer portal) | 60 days before expiry |
| Apple Development certificate (debug and test builds) | 1 year | 30 days before expiry |
| App Store Connect API key (for `notarytool`) | Does not expire by itself; can be revoked | Review yearly |
| Apple Developer Program membership | 1 year | 60 days before expiry |

Already notarized and stapled releases stay valid after the certificate expires, because the signature carries a secure timestamp. An expired certificate only blocks **new** builds.

## Renew the Developer ID Application certificate

Only the Account Holder can create Developer ID certificates.

1. On the Mac that holds the private key, open Keychain Access, then Certificate Assistant, then "Request a Certificate From a Certificate Authority...". Save the request to disk (use your Apple ID email, leave the CA email empty).
2. Sign in to the Apple Developer portal, go to Certificates, create a **Developer ID Application** certificate (not Installer), and upload the request. Download the `.cer` file.
3. Double-click the `.cer` file to install it in the **login** keychain. Confirm it appears with its private key (a disclosure triangle shows the key underneath).
4. Check the identity is visible to the toolchain:

   ```sh
   security find-identity -v -p codesigning
   ```

   The new "Developer ID Application: <Name> (<TEAM ID>)" line must show, and the Team ID must equal `DEVELOPMENT_TEAM` in `Config/Signing.xcconfig`.
5. Build and verify a test release; the designated requirement must be unchanged from the previous release:

   ```sh
   codesign -d -r- "{{AppName}}.app"
   ```

   Compare the output with the previous release's. Any difference in bundle ID or Team ID is a hard failure (QA-R30 step 3, `scripts/verify-release.sh`).
6. If CI ever signs releases (not the case: QA-R31 keeps signing on Pa's Mac, [0005](../decisions/0005-pa-decisions-2026-11-13.md) Q9): export the certificate with its private key as a `.p12` from Keychain Access with a strong password, store it only as a secret of the GitHub environment `release` (together with the password), then delete the exported `.p12` from disk. The workflow imports it into a temporary keychain and deletes that keychain at the end of the job (QA-R31). Remove the old certificate secret.
7. Make a small beta release with the new certificate and run the upgrade test ([release](release.md) section 5) from the previous stable to confirm permissions persist.
8. Revoke nothing yet. After a successful public release signed with the new certificate, the old one can be left to expire or revoked in the portal.

## Renew the Apple Development certificate

For dev builds with bundle ID suffix `.dev` (PLT-R751). Create it from Xcode (Settings, Accounts, Manage Certificates) or the portal. The self-hosted runner's test build uses a **stable** signing identity so that its permission grant survives rebuilds: after changing the identity, re-grant permissions on the runner ([self-hosted runner](self-hosted-runner.md) section 4).

## If a certificate is revoked or the private key is lost

1. Create a new Developer ID Application certificate as above (a lost private key means you need a new certificate from a new request).
2. Notarization of builds signed with a revoked certificate will fail; fix the certificate first.
3. Already installed apps keep running. Whether Gatekeeper still accepts an old DMG depends on the revocation reason; if in doubt, publish a new signed build and tell users (pinned issue, [rollback](rollback.md) section 2).
4. If the key was stolen, treat it as a security incident (SECURITY.md).

## Checks

- [ ] `security find-identity -v -p codesigning` lists the new identity.
- [ ] `codesign -d -r-` output unchanged from the previous release.
- [ ] `spctl --assess --type execute` and `stapler validate` pass on a build signed with the new certificate.
- [ ] Calendar reminders created for the new expiry date.
