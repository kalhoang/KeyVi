# 0601. Static site generator, data contracts and hosting assumptions

- Status: accepted, 2026-11-13
- Scope: `site/` (PRD-R73 to PRD-R75, PRD-R59, PRD-R71, QA-R19)

## Decision

1. **Zero-dependency generator.** `node site/build.mjs` (Node 22+, ES modules, no npm packages, no `package.json`
   needed) renders `site/dist`. Rationale: nothing to audit or update (PLT-R910 supply-chain stance), the site
   is about 30 pages, and a template engine would add more surface than it saves. No dependency was judged
   essential, so none was added. Options: `--out`, `--data-dir`, `--today`, `--strict`.
2. **Brand values only from `scripts/brand.env`** (display name, slug, bundle ID, host), read at build time.
   Copy uses `{{AppName}}`, `{{slug}}`, `{{host}}`, `{{bundleId}}` tokens; `site/test.mjs` fails if a source file
   contains the literal brand values, so `scripts/rename-app.sh` never has to touch `site/`. Non-brand settings
   (GitHub repository URL, Sponsors URL, Homebrew tap, support and security email) live in `site/config.json`
   with obvious placeholders (`OWNER`, `.invalid`).
3. **Release gate.** Every unverified claim renders a visible `VERIFY` badge (spec convention). `node site/build.mjs
   --strict` fails while any badge or placeholder config value remains; the deploy workflow should use it for
   the first public release. A normal build only warns.
4. **URLs.** Pages are written as `<path>/index.html` and linked with a trailing slash (`/tai-ve/`), so any static
   host works without rewrites; the spec's `/tai-ve` resolves by the host's standard redirect. Vietnamese at `/`,
   English at `/en/` with English slugs: `download`, `compatibility`, `changelog`, `privacy`, `support`,
   `donate`, `support/migrate-from/<app>`. Migration pages: `xkey`, `openkey`, `evkey`, `go-nhanh`, `phtv`,
   `macos-co-san` (en: `built-in-macos`), plus `tep-van-ban` (en: `plain-text-file`) holding the TAB/CSV templates
   and the settings export format (PRD-R69, PRD-R72). `/appcast.xml` is copied from `site/static/appcast.xml`
   (brand tokens filled), never renamed.
5. **Privacy by construction (PRD-R74).** One local stylesheet, system font stack, no third-party anything, no
   cookies or storage, no inline script or style, a meta CSP plus `static/_headers` for hosts that read it.
   JavaScript is limited to `assets/matrix.js` (matrix filters) and the pages work without it. Website analytics:
   none (ADR 0001 item 18); `/rieng-tu` states it. `site/test.mjs` enforces the rules.
6. **Donation (PRD-R56 to PRD-R60).** `/ung-ho` carries the PRD-R59 block with placeholder QR images and VERIFY
   badges. The only other entry points are one quiet footer link and the single line under the changelog. No
   Polar, no Buy Me a Coffee (tested). The placeholder QR images in `site/static/assets/qr/` must be replaced by
   Pa with real bundled assets.

## Data contracts (what other tracks must write)

- `site/data/releases.json`, written by `scripts/publish-release`: schema in `site/schema/releases.schema.json`
  (`releases[]` with version, build, channel `stable|beta`, date `YYYY-MM-DD`, `dmgUrl` https, `sha256`,
  `minimumSystemVersion`, `notes{vi,en}`). The reader also accepts a bare array and the aliases listed in the
  schema; invalid entries are skipped with a build warning. When the file is absent the site shows "chưa có bản
  phát hành" and no download button. The latest stable and the latest beta newer than it are shown; everything
  else goes to the archive table.
- `compat/matrix.json` (QA-R17), read tolerantly: a top-level array or `{entries|apps|rows|items: [...]}`; per
  entry `displayName|name`, `bundleId`, `category`, `tier`, `status`, `note` (string or `{vi,en}`),
  `lastVerified` (`YYYY-MM-DD`), `appVersion`, `macOSVersion`. Status accepts the four PRD-R35 values by key
  (`works`, `notes`, `unverified`, `limitation`) plus common aliases and the Vietnamese labels; unknown values
  become `unverified`. Entries with no date or older than 120 days display as `Chưa kiểm tra` (QA-R19) with the old
  date shown. If the compatibility track chooses other field names, change `normalizeMatrixEntry` in
  `site/lib/data.mjs` only. When the file is absent, `site/fixtures/matrix.json` (all rows unverified) is used and the
  page says it is sample data.
- `CHANGELOG.md` (Keep a Changelog) is rendered on both language pages; an optional `CHANGELOG.vi.md` is used for the
  Vietnamese page when present. Fallback: `site/fixtures/CHANGELOG.md`.
- `site/static/appcast.xml`: initial valid empty Sparkle feed; `scripts/publish-release` rewrites it.
- `site/fixtures/populated/` is a fake-data set used only by `site/test.mjs` and manual previews
  (`node site/build.mjs --data-dir site/fixtures/populated --out /tmp/preview`); it is never used by a normal build.

## Content decisions

- Migration pages (PRD-R71) describe only what a user sees in the other app's own window, in generic wording, every
  step marked VERIFY, with screenshot placeholders; nothing is taken from any other input method's code (CLR-R1,
  CLR-R5). Screenshots must be added after a real check.
- Vietnamese copy is standard and neutral, addressed to "bạn" (PRD-R62); the drafts of spec/03-product.md (onboarding
  welcome, conflict notice, built-in source advice, donation thank-you) are reused verbatim.
- Minimum macOS shown is the release's `minimumSystemVersion`, or "15 Sequoia" with a VERIFY badge until Pa confirms
  (ADR 0001 item 6).

## Consequences

The output works on any static host; `static/_headers` holds the headers in the Cloudflare Pages and Netlify
format, and [ADR 0602](0602-site-hosting-kalera-swarm.md) turns the same file into the nginx configuration of the
container that serves the site on the Kalera Docker Swarm.

Amendment, final review (2026-11-13):

- `site.yml` runs `node site/test.mjs` and then the build, on pull requests and on `main`. The build is strict
  (`--strict`) when the repository variable `SITE_STRICT` is `true`. The deployed image is built by
  `.github/workflows/site-image.yml` on the branch `prod` only (ADR 0602), strict unless `SITE_STRICT` is
  `false`; a non-strict build is a preview and always sends `X-Robots-Tag: noindex` (Pa, 2026-11-13: deploy a
  preview with `SITE_STRICT=false` and `noindex` until the first public release).
- `site/config.json` has a `banner` object (the QA-R38 and QA-R54 notice): when `enabled`, every page shows its
  `vi` or `en` text and an optional HTTPS `link` at the top, as escaped text with no script. The rollback and
  absence runbooks switch it on and off.
- `site/config.json` has an `analytics` object (Pa, 2026-11-13, Q7 and its evening follow-up):
  `{ "provider": "umami", "scriptUrl": "https://<host>/script.js", "websiteId": "<uuid>" }`. Missing, or all three
  values empty, means no analytics script at all; a valid object adds the self-hosted Umami tracker tag to the
  website pages (never in the app, never on release-notes pages), and the build adds exactly its origin to the CSP.
  This replaces "Website analytics: none" of decision 5 and ADR 0001 item 18 for builds that configure it;
  `/rieng-tu` describes whichever state the build has. The first version of this amendment used PostHog Cloud; it
  was replaced by Umami the same day (ADR 0602 decision 7).

Amendment, website redesign (2026-11-17, [design](../superpowers/specs/2026-11-16-website-redesign-design.md)):

- The generator now ships two more first-party scripts and one vendored library, each on specific pages only:
  `home.js` with the vendored anime.js 4.5.0 ([ADR 0603](0603-website-motion-library.md)) on the two home pages and
  `copy.js` on the two donate pages, beside the existing `matrix.js` of the compatibility pages. A page lists them in
  `page.scripts` (classic scripts with `defer`, fingerprinted) and its extra stylesheets in `page.styles`; the CSP stays
  as it is, with no inline script and no style attribute.
- The build reads `site/demo/frames.json`, which `site-demo-frames` in `Packages/VietnameseEngine` writes from the
  engine and which is committed, so the build still needs Node only; a malformed file stops the build.
