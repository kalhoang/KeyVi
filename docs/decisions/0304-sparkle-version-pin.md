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
  (from `Config/Sparkle.xcconfig`, filled once Pa generates the key on his Mac), `SUEnableAutomaticChecks`,
  `SUScheduledCheckInterval = 86400`, `SUAllowsAutomaticUpdates`, `SUAutomaticallyUpdate`,
  `SUEnableSystemProfiling = NO` (PRD-R55), `SUVerifyUpdateBeforeExtraction = YES` (PLT-R1102; VERIFY the key
  is honoured by 2.10.1, otherwise remove it).
- The wrapper (`App/Sources/Updater`) uses `SPUStandardUpdaterController` with an `SPUUpdaterDelegate` that
  returns `["beta"]` from `allowedChannels(for:)` only when the user opted in (PLT-R1101, PRD-R53), applies
  settings D19-D21 to `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates` at launch and on
  change, and implements `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` so an automatic
  relaunch happens only after 60 s without a key press and with secure input off (PLT-R1105).
- Upgrades of the pin are decision-record changes with the release notes reviewed for installer and
  signature changes; Dependabot proposes them (QA-R24).

## Consequences

- No Sparkle XPC services are needed (the app is not sandboxed); the installer runs only during installs
  (PLT-R201).
- Before the first public build Pa must generate the EdDSA key pair and fill `SPARKLE_PUBLIC_ED_KEY`
  (manual step, listed in docs/architecture/traceability.md).
