# Runbook: Sparkle EdDSA key rotation

Owner: the maintainer. Specification: QA-R32, QA-R33, PLT-R1102, PLT-R1103.

The Sparkle EdDSA (ed25519) private key signs every update archive. Its public half (`SUPublicEDKey` in `Info.plist`) and the feed URL are fixed in the app from the first public build (QA-R33). The private key lives only in the login keychain on Pa's Mac, with an offline encrypted backup in two places, and is never stored in CI (QA-R32).

Everything here that depends on Sparkle's tools or behaviour is marked VERIFY: check it against the documentation of the Sparkle version pinned in `Package.resolved` before you rely on it, and write the confirmed command lines into this file.

## When to rotate

- Planned: on a schedule Pa chooses (for example yearly), or when the Mac holding the key is replaced.
- Unplanned: the key may have been exposed (stolen laptop, leaked backup, suspicious signature). Treat this as a security incident (SECURITY.md).

## Key custody (baseline)

| Item | Where | Notes |
|---|---|---|
| Private key | Login keychain on Pa's Mac | Never in the repository, never in CI, never printed |
| Backup 1 | Offline encrypted (for example an encrypted disk image on an offline drive) | Passphrase in a password manager |
| Backup 2 | A second, physically separate location | Test restoring once per year |
| Public key | `SUPublicEDKey` in the app's `Info.plist` and in the appcast tooling | Public information |

Do not export the private key into a shell history, a chat, a ticket or a screenshot. Use Sparkle's key tool to export to a file only for the purpose of making the encrypted backups, and delete the plain file immediately.

## Planned rotation (the old key is still safe)

QA-R33: key rotation requires a release signed with the old key that ships the new key.

1. **Generate the new key pair** on Pa's Mac with Sparkle's `generate_keys` tool, stored under a distinct keychain account so it does not overwrite the old key (VERIFY the account option of the pinned Sparkle version). Record the new public key.
2. **Back up the new private key** to the same two offline places before using it.
3. **Release R1**: a normal release ([release](release.md)) whose `Info.plist` contains the **new** `SUPublicEDKey`, while the update archive is signed with the **old** private key. Installed apps verify R1 with the old public key they already have, then run R1 and trust the new key from then on. VERIFY with a test: a build with the old key updating to a build with the new key, through a local appcast, on a clean machine. Also VERIFY that Sparkle's Apple code-signature continuity check is satisfied (it requires the Developer ID Team ID to be unchanged; see [certificate renewal](certificate-renewal.md)).
4. **Wait for adoption.** Use the aggregated appcast request counts (no per-user identifiers, PRD-R76) and the share of installs that updated. Keep signing releases with the old key only until R1 has reached nearly everyone; users who skipped R1 may need a manual install (use `sparkle:minimumAutoupdateVersion` to force this with an explanation, PLT-R1109).
5. **Release R2 onward**: sign with the new key. Update `scripts/publish-release` configuration to use the new key account (VERIFY where it reads the account name).
6. **Retire the old key** after a long overlap. Keep its encrypted backup for rebuilding old archives, but remove it from the login keychain, and record the date in `docs/decisions/`.

Write an ADR for every rotation: date, reason, old and new public key fingerprints (public values only), and the release numbers R1 and R2.

## Unplanned rotation (the old key may be compromised)

An attacker with the old private key can sign an update that installed apps will accept. Act in this order:

1. **Stop updates**: pull every appcast item or replace the feed with a minimal valid feed that has no items ([appcast pull](appcast-pull.md)). Publish a pinned issue and the website banner.
2. **Generate a new key** (steps 1 and 2 above) on a clean machine if possible.
3. **Ship a release that carries the new key.** Because the old key cannot be trusted, this release should be accepted through a path the attacker does not control. Sparkle can accept an update whose EdDSA key changed when the Apple code-signing identity (same Team ID) is unchanged and valid (VERIFY this behaviour and the exact conditions in the Sparkle documentation for the pinned version). If Sparkle will not accept it, users must install manually from the DMG on the website: set `sparkle:criticalUpdate` where appropriate and explain the manual step clearly.
4. Write a security advisory (SECURITY.md process). Review how the key was exposed and fix that.
5. Re-verify every published archive's signature against the new key where the process allows, and re-sign the archives of the last 3 releases only if they are still offered.

## Checks

- [ ] `SUPublicEDKey` in the built app equals the public key of the key in the keychain (print the public key with the Sparkle key tool and compare).
- [ ] A signed test archive verifies with Sparkle's `sign_update --verify` or an equivalent check (VERIFY the option name).
- [ ] Both offline backups restore into a fresh keychain on a test Mac, and the restored key produces the same public key.
