# 0504. Publishing (appcast, releases.json, Homebrew) and renaming

- Status: accepted, 2026-11-13
- Requirements: QA-R32 to QA-R37, PLT-R1101, PLT-R1102, PLT-R1106, PLT-R1109, PLT-R1110, PLT-R1012,
  PLT-R903, PRD-R73

## `scripts/publish-release` outputs

- **Appcast** `site/static/appcast.xml`, published at `https://<site host>/appcast.xml` (one stable URL;
  betas are items with `sparkle:channel` `beta`). Each new item, newest first, carries `title`, `pubDate`,
  `sparkle:version` (build), `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` (from the app's
  `LSMinimumSystemVersion`), optional `sparkle:minimumAutoupdateVersion`, one
  `sparkle:releaseNotesLink` without `xml:lang` (amended 2026-11-13, see below),
  `sparkle:phasedRolloutInterval` 86400 for stable (skipped with `--no-phasing` for P0 hotfixes),
  `sparkle:criticalUpdate` only with `--critical`, and an `enclosure` with URL, length and
  `sparkle:edSignature`. All URLs must be HTTPS.
- **Release-notes page** (ADR 0304 amendment): `site/static/release-notes/<version>/index.html`, published
  at `https://<site host>/release-notes/<version>/`, is the one page the appcast item links. It is
  bilingual (Vietnamese first, then English), each half ends with a link to the changelog page
  (`https://<site host>/nhat-ky-thay-doi/#v<version>` and `https://<site host>/en/changelog/#v<version>`;
  the site gives each release heading the id `v<version>`). It has no site navigation and no donation line,
  because Sparkle shows it in the in-app update window (PRD-R57). The helper escapes the notes, fills
  `{{AppName}}`, refuses en and em dashes and unfilled tokens (the site build would reject the page), refuses
  more than five visible lines per language (PRD-R51 is a MUST; `###` headings do not count) and never
  overwrites a published page. `publish-release` runs the same checks (`release-notes-page --check`) before
  it downloads, verifies or signs anything, so bad notes fail before the keychain prompt. With `--apply`, Vietnamese
  notes are required (PRD-R51); a dry run falls back to the English notes with a warning.
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
  skipped unless `--sign-in-dry-run`; nothing is uploaded or committed. `--apply` writes into the same
  temporary copy first and installs the appcast, the page, `releases.json` and the cask into the repository
  only after every step succeeded.
- **Key guard**: the script refuses an update archive whose app has an empty or malformed `SUPublicEDKey`
  (ADR 0304); `scripts/verify-release.sh` applies the same check to every Release build.

## Zap paths

`scripts/zap-paths.txt` lists every storage path (Appendix A plus the per-bundle folders macOS creates)
with the tokens `{{storage-folder}}` and `{{bundle-id}}`. The storage folder follows PLT-R903: the display
name, or the slug when the display name contains non-ASCII characters (`APP_STORAGE_FOLDER` in
`scripts/lib/common.sh`). Render with
`python3 -I scripts/lib/publish_helpers.py render-zap --zap scripts/zap-paths.txt --folder <folder>
--bundle-id <id>` (used by the cask; the docs and site tracks can use it for the uninstall page).

## Rename contract (`scripts/rename-app.sh`)

- Sources of truth: `Config/Brand.xcconfig` and `scripts/brand.env` (five values: display name, slug,
  release and dev bundle IDs `vn.kal.<slug>` and `vn.kal.<slug>.dev`, site host `<slug>.kal.vn`). Since the
  2026-11-13 amendment below both files also carry `APP_SUPPORT_EMAIL`, `APP_REPOSITORY_URL` and
  `APP_LEGACY_STORAGE_FOLDER_NAMES`; `scripts/check-brand-sync.py` (part of `scripts/lint.sh`) fails when
  the two files disagree.
- Templates keep placeholders (`{{AppName}}`, `{{app-slug}}`, `{{storage-folder}}`, `{{bundle-id}}`,
  ...) and are rendered at build or publish time; the script never touches them.
- README, docs and site copy use the placeholders (`{{AppName}}`, `{{app-slug}}`, `<slug>`), never the
  literal brand values: `scripts/check-docs.py brand` (part of `scripts/lint.sh`) fails on a literal display
  name, slug, bundle ID or site host in `docs/` (outside `docs/decisions/`), `README*.md` and
  `CONTRIBUTING.md`, and `site/test.mjs` does the same for the site sources (amended 2026-11-13; this bullet
  first allowed literals there).
- Amended again 2026-11-13, when the name became final (ADR 0400 decision 1 amendment): the front door
  (every root-level Markdown file except `CHANGELOG.md` for now, `.github/pull_request_template.md` and
  `.github/ISSUE_TEMPLATE/*`; `FRONT_DOOR` in `scripts/check-docs.py`) is shown by GitHub or the DMG exactly
  as it is, so it writes the literal display name, slug and site host instead, and `scripts/check-docs.py
  brand` fails on any `{{...}}` placeholder there. The literal rule above now covers `docs/` only. The script
  rewrites the front door like every other tracked text file (next bullet).
- Files outside those scopes may still carry literal values where a placeholder cannot be rendered (for
  example `.github/`, `packaging/`, `compat/` fixtures and issue-form config). The script rewrites every
  literal occurrence of the old display name, bundle IDs, site host and the slug as a whole word in
  tracked text files, except `spec/` (imported specification) and `docs/decisions/` (historical records).
  The dry run lists every changed line; `--apply` writes.
- After a public release (any entry in `site/data/releases.json`) the script refuses unless
  `--after-release`: the bundle ID, folder names and feed URL are permanent (PLT-R750, PLT-R903, QA-R33).

## Amendment 2026-11-13: optional brand values and legacy folders

Follows the platform design review (ADR 0307 amendment, PRD-R47, QA-R51, QA-R60).

- `scripts/brand.env` mirrors the three optional keys of `Config/Brand.xcconfig`. Empty means "not decided
  yet". `APP_REPOSITORY_URL` is a plain URL in `brand.env` (`https://github.com/<owner>/<repo>`) and is
  written `https:/$()/github.com/<owner>/<repo>` in the xcconfig, because `//` starts an xcconfig comment.
  `load_brand` (`scripts/lib/common.sh`) validates the shape of each value when it is set.
- `scripts/rename-app.sh` keeps `APP_SUPPORT_EMAIL` and `APP_REPOSITORY_URL` exactly as they are (a
  repository URL that contains the old slug is not rewritten). It puts the old storage folder name
  (PLT-R903: the display name, or the slug when the display name is not ASCII) first in
  `APP_LEGACY_STORAGE_FOLDER_NAMES`, drops duplicates and drops the new folder name, so renaming back to an
  earlier name never asks the migrator to move a folder onto itself. A display name may not contain `;`,
  the list separator. The script body is one compound command, so rewriting its own file (a usage example
  that equals an old name) cannot derail the running shell.
- `scripts/check-url-hosts.sh` allows the host of `APP_REPOSITORY_URL` (`github.com` while it is empty) and
  the domain of `APP_SUPPORT_EMAIL` (when set) from `brand.env`; neither is listed in
  `scripts/url-hosts.allow` any more.

## Consequences

- The site, the appcast and the cask change in one command, so the download page, changelog and feed
  cannot disagree (QA-R37); deploying the site stays a separate step until hosting is chosen.
- Homebrew livecheck uses the Sparkle strategy on the appcast; VERIFY that beta-channel items are ignored
  by the strategy before submitting to the official homebrew-cask repository.
