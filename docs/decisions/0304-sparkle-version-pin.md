# 0304. Sparkle version pin

- Status: accepted, 2026-11-13
- Requirements: PLT-R104, PLT-R1101-R1110, PRD-R50-R55, QA-R24, QA-R32-R35
- Context: Sparkle 2 is the only third-party runtime dependency and must be pinned exactly. As of
  2026-11-13 the latest release is 2.10.1 (2026-10-25); 2.10.0 raised Sparkle's own minimum to macOS 12 and
  dropped CocoaPods; 2.10.1 fixes an update being installed prematurely when the app sits in an NFC-encoded
  path, which matters if the final product name contains Vietnamese letters (open decision 1).

## Decision

- Pin Sparkle **2.10.1** with `exactVersion` in `project.yml`, revision
  `ab7d71291238df6e0492143b120c9b696a35f603` recorded in `Config/Package.resolved`.
- Info.plist: `SUFeedURL = https://$(APP_SITE_HOST)/appcast.xml`, `SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`
  (from `Config/Sparkle.xcconfig`, filled once Pa generates the key on Pa's Mac), `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval = 86400`, `SUAllowsAutomaticUpdates`, `SUAutomaticallyUpdate`,
  `SUEnableSystemProfiling = NO` (PRD-R55), `SUVerifyUpdateBeforeExtraction = YES` (PLT-R1102; read
  by 2.10.1 in SPUUpdater.m and Autoupdate/AppInstaller.m).
- The wrapper (`App/Sources/Updater`) uses `SPUUpdater` with a subclass of `SPUStandardUserDriver` that only
  replaces the error alert (PRD-R43), and an `SPUUpdaterDelegate` that
  returns `["beta"]` from `allowedChannels(for:)` only when the user opted in (PLT-R1101, PRD-R53), applies
  settings D19-D21 to `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates` at launch and on
  change, and implements `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`: it takes over and
  installs at once only when no key was pressed for 60 s, secure input is off and the item is not critical;
  otherwise it returns false, because returning true stalls Sparkle's update cycle (no manual or scheduled
  checks, no critical-update window) until the handler runs, and Sparkle then installs at quit without
  relaunching (PLT-R1105, PRD-R54).
- Upgrades of the pin are decision-record changes with the release notes reviewed for installer and
  signature changes; Dependabot proposes them (QA-R24).

## Consequences

- No Sparkle XPC services are needed (the app is not sandboxed); the installer runs only during installs
  (PLT-R201).
- Before the first public build Pa must generate the EdDSA key pair and fill `SPARKLE_PUBLIC_ED_KEY`
  (manual step, listed in docs/architecture/traceability.md).

## Release notes language (amendment 2026-11-13, design review finding 15)

Sparkle picks an appcast item's `sparkle:releaseNotesLink xml:lang` by the macOS language, not by the app's
interface language (D18), so a Mac running in English with the app in Vietnamese would show English notes. To
satisfy PRD-R51 regardless of locale, each release publishes ONE bilingual release-notes page (Vietnamese
first, then English, each short, led by user-visible fixes by app name) and the appcast item links only that
page, without `xml:lang` variants. Request to the release scripts track (`scripts/publish-release`, appcast
generation): emit the single bilingual `releaseNotesLink`.

## Runbook note: filling `SPARKLE_PUBLIC_ED_KEY`

`SUPublicEDKey` in `App/Info.plist` is `$(SPARKLE_PUBLIC_ED_KEY)` from `Config/Sparkle.xcconfig`, empty in the
skeleton. Before the first build that is given to anyone, Pa runs Sparkle's `generate_keys` (from the Sparkle
2.10.1 distribution, `bin/generate_keys`) on Pa's Mac. It stores the private key in the login Keychain and prints
the public key; Pa pastes the public key as the value of `SPARKLE_PUBLIC_ED_KEY`, commits that one line, and
keeps an offline backup of the private key (`generate_keys -x <file>`, then store the file offline). The private
key never enters the repository, CI or any other tool session (QA-R32, QA-R33). The project docs track links this
note from its release runbook; a Release build with an empty key must fail `scripts/verify-release.sh`
(request to the release scripts track).

