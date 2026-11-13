# 0307. Settings file layout

- Status: accepted, 2026-11-13
- Requirements: PRD-R6, PRD-R21-R23, PRD-R26, PRD-R32, PRD-R72, PLT-R390-R393, PLT-R541, PLT-R903,
  PLT-R1001-R1012, QA-R41
- Context: PLT-R1001 fixes four files in `~/Library/Application Support/<folder>/`. Defaults must live in code
  so users who never touched a setting get future fixes (PRD-R6, PLT-R1004). The display name is temporary and
  may become non-ASCII.

## Decision

- **Folder.** `Brand.storageFolderName`: the display name if it is pure ASCII, otherwise the slug
  (PLT-R903). With the temporary name this is `Kal Key`. The choice becomes permanent at the first public
  release: before that release, `AppStorageFolderName` is added to Info.plist with the then-current value and
  the runtime rule is replaced by that constant (release checklist item). Logs use the same folder name under
  `~/Library/Logs/`.
- **Files** (each `{"schemaVersion": 1, "writtenBy": "<app version>", ...}`, 0600, directory 0700):
  - `settings.json`: `settings` (explicit choices only; absent key = unset, JSON `null` = explicitly none for
    optional values such as the restore hotkey), `englishRestoreLists` (`keepAsTyped`, `keepVietnamese`),
    `optedInRules`, `onboarding`. Open at login (D17) is not stored: `SMAppService.mainApp` is the truth.
  - `app-modes.json`: `globalMode` and `apps` (most recently used first) with `bundle`, optional explicit
    `rule` (`remember`, `alwaysEnglish`, `alwaysVietnamese`, `ignore`) and remembered `mode`. At most 1,000
    remembered entries; entries with an explicit rule are never evicted. "Ignore" is applied as a user
    override with strategy `passThrough` by the resolver (PLT-R390) but stored here, next to the other
    per-app rules.
  - `rule-overrides.json`: `overrides` of `{createdAt, rule}` where `rule` is raw 5.4 rule JSON with an id
    prefixed `user.` (kept raw so unknown keys survive).
  - `macros.json`: `macros` of `{id, trigger, expansion, adaptCase, enabled}`.
- **Unknown keys** survive rewrites because each document keeps its raw JSON object and overlays known keys
  (PLT-R1002). Migrations are pure functions over that object (PLT-R1005), with backups
  `backups/<file>.v<N>.<timestamp>.json` (newest 5 kept).
- **Writes** go through the `SettingsStore` actor on the utility serial queue: atomic temp-file + `fsync` +
  `rename`, debounced 1 s (app modes: 5 s, PLT-R392).
- **Outside the folder** (user defaults domain of the bundle ID): the crash-loop launch guard (PLT-R1009),
  the per-install redaction salt (PLT-R902), the last-granted signing digest (PLT-R720), window frames and
  disclosure states, Sparkle's own keys. None of these are user choices that belong in an export.
- **Export** (`<slug>-settings-YYYYMMDD.json`, PLT-R1010) uses the brand-neutral marker
  `"kind": "settings-export"` so exports survive a rename.

## Consequences

- The Homebrew `zap` stanza and the uninstall page list: the Application Support folder, the Logs folder,
  `~/Library/Preferences/<bundle id>.plist`, `~/Library/Caches/<bundle id>/`, and Sparkle's
  `~/Library/Caches/<bundle id>/org.sparkle-project.Sparkle/` (PLT-R1012; exact paths owned by the release
  scripts track).

## Amendment 2026-11-13: moving folders after a rename (design review finding 19)

The product name is temporary and the folder is derived from it, so a rename before the public release would
leave alpha testers (Pa and about ten people) without their settings and macros. Decision:

- `Config/Brand.xcconfig` gains `APP_LEGACY_STORAGE_FOLDER_NAMES` (semicolon-separated, newest first), copied
  into Info.plist as `AppLegacyStorageFolderNames` and read by `Brand.legacyStorageFolderNames`.
  `scripts/rename-app.sh` (release scripts track) appends the old `Brand.folderName(displayName:slug:)` value
  there on every rename (request recorded in the platform report).
- At launch, before `SettingsStore.load`, `LegacyStorageMigrator.migrate` (SettingsStore, W1-B) renames
  `<base>/<legacy>` to `<base>/<current>` for `~/Library/Application Support` and `~/Library/Logs` when the
  current folder does not exist. It never merges or deletes; if both exist, the current one wins and a notice
  is logged.
- A rename also changes the bundle ID, which TCC treats as a new app: testers must grant Accessibility again
  (onboarding shows screen 2), and the user defaults domain (launch guard, redaction salt, window frames) starts
  empty, which is harmless. Whether Sparkle can update across a bundle-ID change is VERIFY before a rename
  ships to testers; if not, testers reinstall from the DMG once.
- Rejected alternative: use the slug as the folder name from day one. It deviates from PLT-R903 ("folder =
  app name unless non-ASCII") for every user to solve a one-time alpha problem.

