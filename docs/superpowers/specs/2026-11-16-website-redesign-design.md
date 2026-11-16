# Website redesign: design

Date: 16/11/2026. Product owner: Pa. Status: draft for the product owner's approval.
Scope: the static site in `site/` (Vietnamese at `/`, English at `/en/`), PRD-R73 to PRD-R75 of `spec/03-product.md`.

## 1. Intent

The product owner wants the website redone so that it looks modern and polished, shows every feature of
{{AppName}}, and gets one message across to anyone who lands on it:

> With {{AppName}} you do not have to keep switching between English and Vietnamese.

Vietnamese Mac users write English words all day inside Vietnamese text (online, file, deadline, email, meeting).
With other input methods they either toggle the input mode many times a day or fight wrong diacritics. The site
must make the fix obvious within a few seconds, before any reading: the visitor sees a message being typed in
one go, English words staying English, Vietnamese words getting their marks, and the mode indicator never
changing.

Motion is part of the brief: the product owner asked to use anime.js and to exploit what it can do, with
terminal3.io as the reference for the level of polish (a dark hero where many threads converge into the logo
and leave as one line, floating cards, scroll-revealed sections, a hub diagram, a dark proof band).

## 2. Audience (decided by the product owner)

Vietnamese people who use a Mac in general: office workers, students, anyone who chats, mails and takes notes.
Not developers first. Developers are served by one feature card and the compatibility section, not by the hero.
Consequences: everyday examples (chat, email, notes) instead of terminal commands; a light, friendly look by
default; plain words; no jargon.

## 3. Goals, non-goals, anti-goals

Goals
- The message of section 1 is understood from the hero alone, without reading the paragraph.
- Every v1.0 feature a general user cares about appears on the home page with a concrete example (section 7.3).
- Every demo is true: what the page shows being typed is what the shipped engine produces for those keys.
- Same quality in Vietnamese and English, on a phone, in dark mode and with reduced motion.
- The rest of the site (download, compatibility, changelog, privacy, support with the migration pages, donate,
  404) gets the same visual system.

Non-goals
- New pages, a blog, a newsletter, search.
- Screenshots or the migration screenshots of PRD-R71 (they come with the release work).
- Release preparation, the appcast, deployment changes (the "Site image" workflow stays as it is).

Anti-goals (a result that does any of these fails even if it looks good)
- Any request to a third party, any cookie, tracker or font CDN (PRD-R74). Umami stays the only exception,
  as configured today.
- A demo that is drawn by hand and can drift from the engine, or a claim the current build does not keep.
- Comparing {{AppName}} with other Vietnamese input methods, or claims about them, anywhere on the site. The
  support page and the migration pages of PRD-R71 name the source apps only to explain how to export from them and
  stop them from launching *(integrator's call, from the builder check: those pages are a MUST and cannot work
  without the names)*.
- Copying terminal3.io's code, assets, logo orb or layout one to one. Only the idea of the thread motif is taken.
- Scroll hijacking, motion that cannot be paused, or motion for people who asked macOS for reduced motion.
- A dark "tech" look as the default.

## 4. Constraints

- Build: `node site/build.mjs`, Node 22, no npm dependencies (`site/build.mjs` header). Pages are rendered by
  `site/lib/pages/*.mjs`, the shell by `site/lib/layout.mjs`, copy lives in `site/content/{vi,en}/*.mjs`.
  Assets are fingerprinted by `site/lib/fingerprint.mjs` (a `?v=hash` query on the URL; `/assets/*` is served
  as immutable for a year). Tests: `node site/test.mjs` (48 tests today), run by the `Site` workflow and by the
  integrator's local gate (`Kal-Key-wt/tools/verify-all.sh`, outside the repository). Deployment: `deploy/site` (nginx image, headers generated from `site/static/_headers`).
- Content Security Policy (`site/static/_headers`, meta CSP in `site/lib/layout.mjs`): `script-src 'self'`,
  `style-src 'self'` plus one hash, `img-src 'self' data:`. No inline script, no inline `style` attribute in the
  generated HTML. Styles set from JavaScript through the CSSOM (`element.style`) are allowed; markup strings with
  `style="..."` injected through `innerHTML` are not.
- Brand (CLAUDE.md "Name"): the display name, slug and host come only from `scripts/brand.env` /
  `Config/Brand.xcconfig`; `scripts/rename-app.sh` must keep working. The trademark sign
  (`APP_TRADEMARK_SIGN`, `{{AppNameTM}}`) applies to the website's page titles and prose once the site is redone
  (spec/03-product.md, the paragraph "Name and trademark sign"); never in buttons, navigation, URLs or identifiers.
  The site has no `{{AppNameTM}}` support yet.
- Copy: standard, neutral Vietnamese addressed to "bạn" (PRD-R62); `file`, never `tệp` (same paragraph as the
  trademark rule); English copy for `/en/`. Drafts in the spec are reused verbatim (PRD-R40, PRD-R59).
- PRD-R73 home page content: a one-sentence value statement, the typing demo (today "a 20-second screen
  recording"), a download button with version and minimum macOS, the `brew install --cask {{app-slug}}` line,
  three proof points (no telemetry, free, open-source engine), a link to compatibility.
- Donation entry points are limited by PRD-R57; the `/ung-ho` page takes the in-app copy of PRD-R59 when the
  site is redone (that paragraph says so).
- Licences: anime.js 4.5.0 is MIT (copyright 2026 Julian Garnier). Vendored with its licence text, listed in
  `THIRD_PARTY_NOTICES.md`; the SPDX lint must accept it. New first-party files carry their SPDX header
  (GPL-3.0-or-later for `site/`, MPL-2.0 for anything inside `Packages/VietnameseEngine`).
- Accessibility: WCAG 2.2 AA contrast; moving content that lasts more than 5 seconds has a pause control
  (WCAG 2.2.2); everything reachable by keyboard; `prefers-reduced-motion` honoured.

## 5. Approaches

1. **Extend the existing generator (picked).** New home sections in `site/lib/pages/home.mjs` and the content
   files, a new design system in `site/static/assets/`, anime.js vendored as one file, one first-party script for
   the motion, and a small engine-driven generator for the demo data. Keeps the CSP, the tests, the brand
   machinery, both languages and the deployment as they are.
2. **Move to a framework (Astro, Vite).** Nicer components and bundling, but the build, the tests, the header
   generation, the fingerprinting and the deployment would all be redone, and a privacy-first site would gain
   hundreds of transitive packages. Rejected.
3. **A hand-written landing page outside the generator.** Fast to start, but it duplicates the shell, both
   languages and the brand placeholders, and breaks `scripts/rename-app.sh` and the tests. Rejected.

The integrator chose approach 1 with the product owner's agreement ("Ok", 16/11/2026).

## 6. Decided with the product owner (16/11/2026)

- Audience: general Vietnamese Mac users (section 2).
- Hero: direction B, "inside the Mac": headline and download on the left, on the right a Mac-style window with a
  chat in which a message types itself key by key; under the window the keys just pressed; small tags pop up for
  English words kept as typed ("online: giữ nguyên"); the menu bar icon of {{AppName}} stays on Vietnamese for the
  whole sentence. Directions A (dark flow scene) and C (giant typography) were shown and not picked; A's thread
  motif moves to section 4.
- Home page structure, top to bottom, as section 7.3 lists it (the page map shown in the browser).
- anime.js for the motion; terminal3.io as the polish reference.
- The typing demo replaces PRD-R73's 20-second screen recording entirely; the page keeps no slot for a video
  (17/11/2026).

Reference mockups (local only, not in the repository, not to be copied as code):
`/Volumes/Data/Projects-2026/Kal-Key-wt/site-design/.superpowers/brainstorm/10602-1794834666/content/`
(`hero-directions.html` for B, `page-map.html` for the structure).

## 7. Design

Items marked *(integrator's call)* were not decided by the product owner; they can be changed at review.

### 7.1 Visual system *(integrator's call)*

- Colours from the logo (`site/static/favicon.svg`, derived from Pa's artwork): ink `#141619`, paper `#F1F0EC` /
  `#FAF8F4`, brand green `#0EA674` (a lighter green such as `#3DDC97` on dark surfaces). One accent only; English
  words in demos use a soft green highlight, never a second brand colour. Dark mode follows
  `prefers-color-scheme` with the same tokens inverted; the proof band (section 5 of the page) is dark in both.
- Type: the system font stack (SF Pro on a Mac, which is the audience's machine; no web font to download, in line
  with the privacy promise). Large, tight headlines (weight 700 to 800, negative tracking), body 16 to 18 px.
  Monospace (`ui-monospace`) only for keys the user presses.
- Shapes: 10 to 16 px radii, soft long shadows for the Mac window and cards, generous whitespace, a 1120 px
  content width.
- Design tokens as CSS custom properties in one file; components (button, card, window, tag, keycap, section
  header) as small CSS blocks; the old `style.css` is replaced, not patched.
- Logo: the KV mark with the green dot, as an inline SVG symbol reused by the header, the hero menu bar and the
  hub in section 4.

### 7.2 Motion system

- anime.js 4.5.0 vendored as one file (`dist/bundles/anime.esm.min.js`, about 41 KB gzipped), loaded as a module
  only on pages that animate. *(integrator's call: one file instead of the modular tree, because the modular tree
  imports its files by relative path without the `?v=hash` query, so an update could mix cached and new modules
  under the one-year immutable cache.)*
- Tools used: timelines and timers for the typing demos, `stagger` for reveals, `onScroll` (or an
  IntersectionObserver) to start a section's motion when it enters the viewport, `createDrawable` and
  `createMotionPath` for the threads of section 4, springs or `outBack` easing for the small tags.
  `splitText` and `scrambleText` only if they pass the CSP check (no injected `style` attributes).
- Rules: motion explains, it does not decorate; nothing moves before the content is readable; durations 200 to
  600 ms for UI, typing at a human pace (about 80 to 110 ms per key with small variations); loops pause when
  off-screen and when the tab is hidden; the hero has a visible pause and play control; no parallax, no scroll
  hijacking.
- Reduced motion: no autoplay. Each demo shows its final state (the finished sentence, the keys line, the tags)
  as static content; the threads are drawn, nothing travels.
- No JavaScript: the generated HTML already contains each demo's final state, so the page is complete without it.

### 7.3 Home page sections

1. **Hero (direction B).** Value statement as the h1 (draft: "Gõ tiếng Việt lẫn tiếng Anh, không cần chuyển."),
   one-sentence lede, download button with version and minimum macOS (the current `downloadBlock` logic and its
   no-release state), the brew line, a line with "macOS 12 trở lên · Apple silicon và Intel · Miễn phí, mã nguồn
   mở". On the right the Mac-style window: a generic chat (no third-party app look or logo), a previous message
   from the other person, the input field where the demo types, the keys strip below the window, the "giữ
   nguyên" tags for English words, then the finished message sent as a bubble. Several sentences rotate
   (chat, email, note) *(integrator's call)*; the first one is
   `Chieeuf nay hojp online, nhows guwir file slide truwowcs deadline nha` giving
   "Chiều nay họp online, nhớ gửi file slide trước deadline nha". This replaces PRD-R73's 20-second screen
   recording (decided by the product owner on 17/11/2026, section 6): crisp at any size, in both languages,
   always in step with the engine, nothing to re-record per release. The other sentences live in
   `site/demo/script.json`; a sentence whose last word is English ends with a boundary (the note ends with a
   period), because the last word is only decided, and restored, when a boundary commits it.
2. **"Một câu, hai thứ tiếng": three core behaviours,** each a small demo that plays when it scrolls into view:
   English words stay as typed even when the word ends with a comma, a period or Return, and in a chat app Return
   is delivered after the correction (P0-3, ENG-R910); typing the next word fixes the previous one (D29,
   ENG-R828; the example must start with Vietnamese words, `cais nayf tricky as hell`, because `as` alone is
   already restored at its own commit, PRD-R79); Escape right after a word gives back the keys as typed
   (`Vieetj`, "Việt", Escape, "Vieetj"; D8, PRD-R18).
3. **"Gõ theo cách của bạn": a grid of six cards** (generated or static as section 7.4 says): tone and modifier keys work anywhere in the word, nothing to
   switch on (`vietej`, `tieengs`, `dangd`; ENG-R107, section 3.2 of the spec); slang onsets (`dzô`, `dzậy`,
   `hẹo`; P0-2, ENG-R316); Telex or VNI, traditional or modern tone placement (`hòa` / `hoà`; D1, D2); macros
   (user-defined text expansion with import and export, PRD-R2; example `dc` gives "được" as a user's own
   macro); keyboard layouts (QWERTY, QWERTZ, AZERTY, Dvorak, Colemak; PRD-R2); per-app language memory and
   rules (PRD-R2). Engine cards show their keys and result and, on hover or focus, the keys turn into the result; the static
   cards (layouts, macros, per-app) use a small illustration instead.
4. **"Chạy trong app bạn dùng hằng ngày".** The {{AppName}} mark in the middle, threads drawing out to the
   categories of `compat/matrix.json` (browsers, chat, office, notes, launchers such as Spotlight, terminals and
   code editors), small dots travelling along the threads *(the thread motif, integrator's call)*. Data comes from
   the matrix at build time; while entries are `notVerified` (all 95 today) the section shows categories and app
   names without any "verified" wording or date, and shows dates once entries are verified. Link to
   `/tuong-thich`. A card underneath: when macOS blocks every input method because of a password field (Secure
   Input), {{AppName}} names the app that holds it and how to turn it off, and types again from the first key
   after it is released (P0-1, PLT-R395 to PLT-R398D). On phones the hub becomes a simple list.
5. **"Ba điều bạn có thể kiểm chứng" (PRD-R73).** Dark band: no data collection (only the update check uses the
   network), free with no locked feature, open source (engine MPL-2.0, app GPL-3.0-or-later) with links to the
   privacy page and the repository. The current copy in `site/content/vi/pages.mjs` is the starting point.
6. **"Cài trong một phút".** Three steps (open the DMG and drag to Applications; open {{AppName}} and grant the one
   permission, with the macOS 12 to 26 and macOS 27 names as the download page states them; try the practice
   field), the brew line again.
7. **Closing call and footer.** The value statement once more, the download button, one quiet line linking to
   `/ung-ho` *(integrator's call; the footer link exists already)*. Footer: privacy, changelog, repository,
   appcast, donate, language.

Header *(integrator's call)*: the KV mark and name, links to features (anchor on the home page), compatibility,
support, a "Tải về" button, the language switch. Privacy and changelog move to the footer.

### 7.4 Demo data from the engine

- Source file: the demo script, per language and per demo: the keys, the typing method, the settings that matter
  (D29 on, Escape restore on, general context), and what each demo highlights.
- Generator: a small executable in `Packages/VietnameseEngine` (MPL-2.0, beside `lexicon-builder`) that types
  each script through the real engine and writes the frames: after every key, the visible text, the word being
  composed, whether a word was kept as typed or revised, and the Escape result. It never invents output.
- The generated JSON is committed in `site/`, so the site build and the deployment image need Node only.
  A check mode fails when the committed file differs from what the current engine produces; it runs in
  `tools/verify-all.sh` and CI next to the other checks.
- If the engine does not produce what a sentence was meant to show, the sentence changes, never the frames.
- What is generated *(integrator's call, from the builder check)*: every demo whose text the engine decides, that
  is the hero sentences, the three behaviours of page section 2 (English kept at a comma, a period and Return;
  the revision; Escape) and the keys and results on the cards of section 3 that are engine behaviour (tone keys
  anywhere, slang onsets, Telex and VNI, tone placement). What the engine does not decide is shown as static
  illustration, never animated as if typed: keyboard layouts (the engine sees characters after layout mapping),
  macros, per-app memory and rules, the menu bar icon, Return delivered after the correction, Secure Input. Each
  of those statements cites the requirement whose tests prove it (PRD-R2, P0-1, P0-3, ENG-R910). No second
  generator in AppCore.
- Which engine is the truth: the engine of the commit the site is built from. The live site is built from the
  `prod` branch, so it shows the engine of `prod`; before the first release it describes the coming 1.0. Any engine
  change that alters a demo's output must regenerate the file in the same commit.
- Where the check runs: the "Generated engine sources and corpus files match their generators" step of the
  `engine-linux` job in `.github/workflows/ci.yml` (Swift on Linux; the engine is standard library only), and the
  integrator's local gate. The `Site` workflow stays Node only. While `ci.yml` is switched off by hand
  (`docs/runbooks/site-deploy.md`), the local gate is the guard.

### 7.5 Other pages

Download, compatibility, changelog, privacy, support and the migration pages, donate and 404 take the new
header, footer, tokens and components; their content stays, apart from the trademark sign and `/ung-ho`, which
takes the in-app donation copy of PRD-R59 verbatim with the bank details, the copy buttons where the site can
offer them without inline script, the share text and the VietQR image (the same artwork as
`App/Resources/Donation.xcassets/DonationVietQR.imageset`), and no other payment method.

### 7.6 English pages

Same structure and demos (the demos still type Vietnamese; captions and copy in English). The English page
explains what "keeping English words" means to a reader who may not type Vietnamese.

### 7.7 Accessibility

The demo window is `aria-hidden` while it animates and the finished sentence is available as text; the pause
control is a real button with a label in each language; headings in order; focus styles visible; contrast AA in
light and dark; touch targets at least 44 px.

### 7.8 Performance

No layout shift (the demo areas reserve their size), no render-blocking script, home page JavaScript under
60 KB gzipped including anime.js, largest contentful paint under 2.5 s on a mid-range phone over 4G, images (the
QR code, any icons) as SVG or small PNG.

### 7.9 Verification

- `node site/test.mjs` extended: PRD-R73 items present on `/` and `/en/`; no inline `style` attribute or inline
  script in any generated page; the demo JSON is valid and every demo's final text appears in the static HTML;
  `{{AppNameTM}}` handled; no third-party URL outside the analytics allowance.
- The generator's check mode (section 7.4).
- A browser pass with the production CSP applied (no violation in the console) at 1440, 1024 and 390 px, light
  and dark, with reduced motion, with JavaScript off; screenshots attached to the review.
- `tools/verify-all.sh` green.

### 7.10 Spec and documentation

PRD-R73 (the demo instead of the screen recording, and the motion and
reduced-motion rules), a row in `docs/decisions/0005-pa-decisions-2026-11-13.md` under "Decisions of 16/11/2026"
(audience, hero B, page structure, and the demo replacing the video on 17/11/2026), `THIRD_PARTY_NOTICES.md` (anime.js), the site's README or runbook if it
documents the build, and the traceability files where requirements move.

## 8. Left to the builder

File names and module layout, CSS architecture inside the token and component rule, the exact animation curves
and timings, the rotating sentences after the first (each one checked through the generator), how the generator
drives the engine, the hub geometry, breakpoints, and the order of work (home page first, then the other pages).
