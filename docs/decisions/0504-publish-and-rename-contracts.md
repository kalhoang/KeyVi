# 0504. Publishing (appcast, releases.json, Homebrew) and renaming

- Status: accepted, 2026-11-13
- Requirements: QA-R32 to QA-R37, PLT-R1101, PLT-R1102, PLT-R1106, PLT-R1109, PLT-R1110, PLT-R1012,
  PLT-R903, PRD-R73

## `scripts/publish-release` outputs

- **Appcast** `site/static/appcast.xml`, published at `https://<site host>/appcast.xml` (one stable URL;
  betas are items with `sparkle:channel` `beta`). Each new item, newest first, carries `title`, `pubDate`,
  `sparkle:version` (build), `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` (from the app's
  `LSMinimumSystemVersion`), optional `sparkle:minimumAutoupdateVersion`, two
  `sparkle:releaseNotesLink` elements with `xml:lang` `vi` and `en`, `sparkle:phasedRolloutInterval`
  86400 for stable (skipped with `--no-phasing` for P0 hotfixes), `sparkle:criticalUpdate` only with
  `--critical`, and an `enclosure` with URL, length and `sparkle:edSignature`. All URLs must be HTTPS.
- **Release-notes links**: `https://<site host>/nhat-ky-thay-doi/#v<version>` and
  `https://<site host>/en/changelog/#v<version>` (routes of the site track). The site's changelog page
  gives each release heading the id `v<version>`.
- **`site/data/releases.json`**: `{"schemaVersion": 1, "releases": [...]}`, newest first; each entry has
  `version`, `build`, `channel` (`stable` or `beta`), `date` (UTC, `YYYY-MM-DD`), `dmgUrl`, `sha256` (of
  the DMG), `size`, `minimumSystemVersion`, `notes` `{vi, en}` (from `CHANGELOG.vi.md` and `CHANGELOG.md`
  sections `## [<version>]`, or `--notes-vi` / `--notes-en` files).
- **Archive URLs**: `https://<site host>/download/<slug>-<version>.zip|.dmg` by default (archive hosting
  on the site host only, decision 0001 item 15); `--github-release` uses the GitHub Release asset URLs and
  publishes the draft release.
- **Homebrew cask**: rendered from `packaging/homebrew/Casks/cask.rb.template` for stable releases only,
  into `dist/homebrew/Casks/<slug>.rb` and, with `--tap-dir`, into Pa's tap checkout (`--tap-commit`
  commits, never pushes). Placeholders: `{{app-slug}}`, `{{AppName}}`, `{{version}}`, `{{sha256}}`,
  `{{dmg-url}}`, `{{site-host}}`, `{{desc}}`, `{{zap-paths}}`.
- **Sparkle tools**: `sign_update` comes from `SPARKLE_SIGN_UPDATE`, the resolved SwiftPM artifacts
  (`.build/artifacts/sparkle/Sparkle/bin/` or Xcode DerivedData `SourcePackages/artifacts/...`), or a
  download of `Sparkle-2.10.1.tar.xz` verified by SHA-256. The private key stays in the login keychain.
- **Dry run is the default**: files are written inside a temporary copy and printed; EdDSA signing is
  skipped unless `--sign-in-dry-run`; nothing is uploaded or committed.

## Zap paths

`scripts/zap-paths.txt` lists every storage path (Appendix A plus the per-bundle folders macOS creates)
with the tokens `{{storage-folder}}` and `{{bundle-id}}`. The storage folder follows PLT-R903: the display
name, or the slug when the display name contains non-ASCII characters (`APP_STORAGE_FOLDER` in
`scripts/lib/common.sh`). Render with
`python3 -I scripts/lib/publish_helpers.py render-zap --zap scripts/zap-paths.txt --folder <folder>
--bundle-id <id>` (used by the cask; the docs and site tracks can use it for the uninstall page).

## Rename contract (`scripts/rename-app.sh`)

- Sources of truth: `Config/Brand.xcconfig` and `scripts/brand.env` (five values: display name, slug,
  release and dev bundle IDs `vn.kal.<slug>` and `vn.kal.<slug>.dev`, site host `<slug>.kal.vn`).
- Templates keep placeholders (`{{AppName}}`, `{{app-slug}}`, `{{storage-folder}}`, `{{bundle-id}}`,
  ...) and are rendered at build or publish time; the script never touches them.
- Static text that must show the name (README, docs, site copy) may contain the literal brand values:
  the script rewrites every literal occurrence of the old display name, bundle IDs, site host and the slug
  as a whole word in tracked text files, except `spec/` (imported specification) and `docs/decisions/`
  (historical records). The dry run lists every changed line; `--apply` writes.
- After a public release (any entry in `site/data/releases.json`) the script refuses unless
  `--after-release`: the bundle ID, folder names and feed URL are permanent (PLT-R750, PLT-R903, QA-R33).

## Consequences

- The site, the appcast and the cask change in one command, so the download page, changelog and feed
  cannot disagree (QA-R37); deploying the site stays a separate step until hosting is chosen.
- Homebrew livecheck uses the Sparkle strategy on the appcast; VERIFY that beta-channel items are ignored
  by the strategy before submitting to the official homebrew-cask repository.
