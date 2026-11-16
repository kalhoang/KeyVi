# 0603. Website motion library: anime.js 4.5.0, vendored

- Status: accepted, 2026-11-17
- Scope: `site/` (PRD-R73, PRD-R74, QA-R24); the website redesign of 16/11/2026
  (`docs/superpowers/specs/2026-11-16-website-redesign-design.md` section 7.2)
- Context: the product owner asked for anime.js for the motion of the redesigned home page (the typing demos, the
  section reveals, the threads of the compatibility section). QA-R24 requires a decision record for every
  dependency, and [ADR 0601](0601-static-site-generator.md) keeps the generator free of npm packages.

## Decision

1. **anime.js 4.5.0, one file.** The website ships `site/static/assets/vendor/anime.umd.min.js`, byte-exact
   `dist/bundles/anime.umd.min.js` of the npm tarball `animejs-4.5.0.tgz`, with the package's `LICENSE.md` beside
   it as `site/static/assets/vendor/anime.LICENSE.txt`. Its SHA-256 and the verbatim licence text are recorded in
   `THIRD_PARTY_NOTICES.md` section 5; `site/test.mjs` fails when the file and the recorded hash differ.
2. **Loaded as a classic deferred script, only where something moves.** A page that animates lists
   `/assets/vendor/anime.umd.min.js` before its own script in `page.scripts`; the layout writes each one as
   `<script src="..." defer>`, so the global `anime` exists when the page script runs, in document order. Pages
   without motion load nothing.
3. **Why the UMD bundle and not the ES module bundle.** A module would `import` other files by URLs that
   `fingerprintAssets` (`site/lib/fingerprint.mjs`) never rewrites, so those URLs would carry no `?v=<hash>`.
   `/assets/*` is cached for a year as `immutable`, and an update could then mix a cached file with a new one.
   The UMD bundle is a single file referenced by one fingerprinted `<script src>`, which keeps the cache rule safe.
   It also needs no `type="module"`, so the CSP (`script-src 'self'`) and the tests stay as they are. The design
   first named `dist/bundles/anime.esm.min.js`; this record replaces that choice (builder's call).
4. **Why no npm.** The generator has no dependencies and no `package.json` (ADR 0601 decision 1). One vendored file,
   checked by its hash, is easier to audit than a package tree, and the site build and the deployment image stay
   Node only.
5. **SPDX.** A vendored file keeps its own header, so `scripts/check-spdx.sh` excludes `site/static/assets/vendor/`
   (and only that folder); the licence is recorded in `THIRD_PARTY_NOTICES.md` instead. First-party website files
   keep their `GPL-3.0-or-later` header.

## Forbidden APIs under the CSP

The production CSP allows `style-src 'self'` plus one hash: a `style="..."` attribute that arrives through markup is
dropped silently. Styles set through the CSSOM (`element.style`) are allowed. anime.js animates through the CSSOM
and the Web Animations API, but a few parts write markup strings. These are not used on the website:

- `splitText`, `split` and the `TextSplitter` class (also reachable as `text.splitText`, `text.split` and
  `text.TextSplitter`): they rebuild the element through `innerHTML`, with templates that can carry style
  attributes;
- `scrambleText` (also `text.scrambleText`);
- the `debug` option of `onScroll` (`ScrollObserver`): it draws its markers through `innerHTML`;
- any other API or option that writes `innerHTML`, or a markup string, into the page.

First-party scripts never write `innerHTML`, `outerHTML`, `insertAdjacentHTML` or a `style` attribute either;
`site/test.mjs` checks their source. The APIs the website uses: `animate`, `createTimeline`, `createTimer`,
`stagger`, `onScroll` (without `debug`), `svg.createDrawable`, `svg.createMotionPath`, `utils`, and the spring
and `outBack` easings.

## Update procedure

1. In a new empty temporary folder: `npm pack animejs@<version>`, then `tar -xzf` the tarball. Nothing in that
   folder is executed.
2. Check the tarball against the registry: `npm view animejs@<version> dist.integrity` must equal the SHA-512 of
   the downloaded file.
3. Copy `package/dist/bundles/anime.umd.min.js` and `package/LICENSE.md` over the two files in
   `site/static/assets/vendor/` (the licence as `anime.LICENSE.txt`), unchanged.
4. Compute `shasum -a 256 site/static/assets/vendor/anime.umd.min.js` and update the anime.js entry of
   `THIRD_PARTY_NOTICES.md`: heading, version, SHA-256, integrity value, copyright line, the licence text compared
   byte for byte, and the date of the comparison. Update the version in the first line check of `site/test.mjs`.
5. Read the release notes for API changes and for new code paths that write markup or style attributes, then run
   `node site/test.mjs` (hash, size budget, forbidden APIs) and the browser pass under the production CSP.
6. Amend this record with the new version and the date. A version change is a decision-record change (QA-R24).

## Consequences

- The home page JavaScript budget (60 KB gzipped, design 7.8) includes this file: about 40 KB gzipped at level 9
  for 4.5.0, which leaves room for the first-party motion script.
- The privacy rules do not change: the file is served from the site itself, makes no request and stores nothing
  (PRD-R74).
- Without JavaScript, or with reduced motion, the pages show the final state of every demo, so the library is an
  enhancement and never a requirement.
