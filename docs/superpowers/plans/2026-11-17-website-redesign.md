# Website redesign implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the static site in `site/` so that it shows the message "with {{AppName}} you do not have to keep
switching between English and Vietnamese". The home page gets seven sections, a typing hero and demos generated from
the real engine; every page shares a new visual system; motion uses anime.js.

**Architecture:**
- **Demo data:** an engine-side executable (`site-demo-frames`) types each scripted sentence through the real engine
  and writes `site/demo/frames.json`. That file is committed, and a check mode keeps it in step with the engine.
- **Pages:** the existing Node generator renders the seven home sections, with each demo's final state already in the
  HTML.
- **Motion:** `home.js`, a classic deferred script, animates the frames with the vendored anime.js 4.5.0 UMD bundle.
- **Unchanged:** CSP, brand machinery, both languages and the deployment.

**Tech Stack:** Swift 6 (engine package, Swift Testing); Node 22 with no npm dependencies (generator, `site/test.mjs`
harness); vanilla JS (ES2020); CSS custom properties; anime.js 4.5.0 (vendored; anime.js 4.5.0 is MIT).

**Spec:** `docs/superpowers/specs/2026-11-16-website-redesign-design.md` (approved by the product owner on
17/11/2026, including every integrator's call). Read it before any task; section numbers below refer to it.

## Global Constraints

- **Toolchain and licences:**
  - `node site/build.mjs` and `node site/test.mjs` run on Node 22 with no npm dependency (design 4).
  - New files in `site/` start with `SPDX-License-Identifier: GPL-3.0-or-later`; new files in
    `Packages/VietnameseEngine` start with `MPL-2.0`.
  - No file may carry the third-party SPDX identifier that `test_no_file_still_carries_the_mit_identifier` forbids
    (`scripts/tests/test_licences_and_wording.py`).
- **CSP** (design 4):
  - `script-src 'self'`, `style-src 'self'` plus the existing hash, `img-src 'self' data:`.
  - No inline `<script>` (data blocks included), no `style="..."` attribute and no `<style>` element in generated
    HTML.
  - JavaScript may set styles only through the CSSOM (`el.style.x = ...`), never through markup strings.
- **Caching:** every `/assets/` URL in HTML carries `?v=<hash>` (`site/lib/fingerprint.mjs`). No CSS `@import` and no
  JS `import` of another asset: those URLs would not be fingerprinted.
- **Brand:**
  - Display name, slug and host come only from `scripts/brand.env`. Never write the product name literally in
    `site/` code, CSS, JS or docs; use tokens (`{{AppName}}`, `{{AppNameTM}}`, `{{host}}`, `{{slug}}`).
  - JS globals and CSS class names are brand-neutral.
  - `{{AppNameTM}}` goes only in page titles and prose; never in buttons, navigation, URLs or identifiers
    (spec/03-product.md "Name and trademark sign").
- **Copy:**
  - Standard, neutral Vietnamese addressed to "bạn" (PRD-R62).
  - `file`, never `tệp`, except an exact quote of a macOS pane.
  - Traditional tone placement everywhere. The modern examples `hoà`, `thuỷ`, `khoẻ` appear only inside `<em>`
    (`site/lib/tone.mjs`).
  - No em dash or en dash in any copy, comment or commit message.
- **Privacy** (PRD-R74): no third-party request, cookie, web font or CDN; Umami stays the only allowance, as
  configured today.
- **Demos** (design 7.4): every demo the engine decides comes from `site/demo/frames.json`. When the engine does not
  produce what a sentence was meant to show, change the sentence, never the frames. Static illustrations (layouts,
  macros, per-app memory, menu bar icon, Return after the correction, Secure Input) are never animated as if typed.
- **Motion** (design 7.2):
  - UI durations 200 to 600 ms; typing 80 to 110 ms per key; no parallax, no scroll hijacking.
  - Loops pause off-screen and when the tab is hidden.
  - The hero has a pause and play button.
  - `prefers-reduced-motion: reduce` means no autoplay and final states shown.
- **Budgets** (design 7.7, 7.8):
  - Home page JavaScript at most 60 KB gzipped, anime.js included.
  - WCAG 2.2 AA contrast in light and dark; touch targets at least 44 px; no layout shift.
- **Process:**
  - Tests first (QA-R3).
  - English Conventional Commits with no AI attribution and no Co-authored-by.
  - History is never rewritten (CLR-R12).

## Review Focus

1. **First-party JavaScript that writes markup or style attributes.** The production CSP blocks it silently: tags or
   keys vanish, and only a console warning shows. Test in Task 6 (and Task 7 for `copy.js`).
2. **Brand green used as text colour.** `#0EA674` on `#FAF8F4` is about 3:1, which fails AA for body text. The tokens
   need a darker text green in light mode and the lighter green in dark mode. Test in Task 3.
3. **JavaScript off, or reduced motion on.** A visitor must still see every finished sentence, the keys line and the
   tags. Tests in Task 5 (static final states) and Task 6 (`shouldAnimate`).
4. **The no-release state.** Every place that shows a download button (hero, closing section, header) must show the
   disabled "no release yet" state when `releases.json` has no stable entry. Test in Task 5 with
   `site/fixtures/empty`.
5. **A 390 px phone.** The Mac window, the keys strip and the hub must not overflow horizontally, and the hub becomes a
   list. No Node test can see this, so it is checked in the browser pass of Task 9.

---

### Task 1: Engine demo frames generator

**Files:**
- Create:
  - `Packages/VietnameseEngine/Sources/site-demo-frames/main.swift` (exits with `SiteDemoFrames.run`)
  - `Packages/VietnameseEngine/Sources/site-demo-frames/DemoScript.swift`
  - `Packages/VietnameseEngine/Sources/site-demo-frames/FrameRecorder.swift`
  - `Packages/VietnameseEngine/Sources/site-demo-frames/SiteDemoFrames.swift`
  - `Packages/VietnameseEngine/Tests/SiteDemoFramesTests/SiteDemoFramesTests.swift`
  - `site/demo/script.json`
  - `site/demo/frames.json` (generated, committed)
- Modify:
  - `Packages/VietnameseEngine/Package.swift`:
    - executable target `site-demo-frames` with dependencies `VietnameseEngine`, `VietnameseEngineData` and
      `VietnameseEngineTesting`
    - test target `SiteDemoFramesTests` with dependencies `site-demo-frames`, `VietnameseEngine`,
      `VietnameseEngineData` and `VietnameseEngineTesting`
    - no new product
  - `.github/workflows/ci.yml`:
    - "Generated engine sources and corpus files match their generators" step: add
      `swift run --package-path "$ENGINE" site-demo-frames --check`
    - coverage step `--exclude`: add `site-demo-frames` to the alternation, next to `lexicon-builder` and
      `engine-benchmark`
  - `Packages/VietnameseEngine/README.md` (or the engine's tool list, if one exists): one line naming the tool.

**Interfaces:**
- **Consumes:**
  - `EngineDriver(engine:)`, `driver.send(_:)`, `driver.field.string`, `driver.state.activeRawKeys` and
    `driver.state.activeDisplay` (VietnameseEngineTesting)
  - `Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))` (VietnameseEngineData)
  - `resources.english.contains(_:)` and `resources.techAlways.contains(_:)`
- **Produces:**
  - **CLI:** `swift run --package-path Packages/VietnameseEngine site-demo-frames [--check] [--script PATH] [--out PATH]`,
    run from the repository root.
    - Defaults: `site/demo/script.json` and `site/demo/frames.json`.
    - Exit codes: 0 on success; 1 when a demo's output differs from its `expect`, or in `--check` mode when the
      committed file differs; 2 on a usage error.
  - **Swift entry points:**
    - `enum SiteDemoFrames { static func run(arguments: [String], currentDirectory: URL) -> Int32 }`
    - `struct DemoScript: Decodable`
    - `struct FrameRecorder { func record(_ demo: DemoScript.Demo) throws -> RecordedDemo }`
    - `func renderFramesFile(_ demos: [RecordedDemo]) -> Data`, deterministic: sorted keys, pretty printed, `/` not
      escaped, trailing newline.
  - **`site/demo/script.json` schema:**
    ```json
    { "schemaVersion": 1,
      "demos": [ { "id": "hero-chat", "method": "telex", "toneStyle": "traditional",
                   "keys": "Chieeuf nay hojp online, nhows guwir file slide truwowcs deadline nha",
                   "expect": "Chiều nay họp online, nhớ gửi file slide trước deadline nha" } ] }
    ```
    - `method` is `telex` or `vni`; `toneStyle` is `traditional` or `modern`.
    - Every demo runs with `EngineConfiguration(appContext: .general, autoRestore: true, lookaheadRevision: true)` and
      no macros (D29 on, Escape restore on, general context).
    - Key notation inside `keys`: `⏎` is Return (`KeyInput("\n")`), `⎋` is Escape (sends `.restoreToggle`), `⌫` is
      Backspace; every other character is `.key(KeyInput(c))`.
  - **`site/demo/frames.json` schema** (Tasks 5 and 6 read it):
    ```json
    { "schemaVersion": 1, "generator": "site-demo-frames",
      "demos": { "<id>": { "keys": "…", "method": "telex", "toneStyle": "traditional", "text": "<final field text>",
        "frames": [ { "key": "C", "text": "C" },
                    { "key": " ", "text": "Chiều ", "commit": { "raw": "Chieeuf", "text": "Chiều",
                      "outcome": "kept", "rule": "notEnglish", "english": false } },
                    { "key": " ", "text": "…", "commit": { … }, "revision": true },
                    { "key": "⎋", "text": "Vieetj", "toggle": true } ] } } }
    ```
    - `text` is the whole simulated field after the key.
    - `commit` is present when the output carried a `CommitDecision`:
      - `raw` is the token's raw keys before the boundary.
      - `text` is what the token became.
      - `outcome` is `kept`, `restored` or `macro`.
      - `rule` is the `CommitRule` case name.
      - `english` is `text == raw && (outcome == "restored" || english.contains(raw.lowercased()) || techAlways.contains(raw.lowercased()))`.
    - `revision: true` when `output.revision != nil`.
    - `toggle: true` for `⎋`.
    - Absent keys are omitted, never written as null.

- [ ] **Step 1: Write the failing tests** in `SiteDemoFramesTests.swift` (Swift Testing, `@testable import site_demo_frames`):
  - `heroSentenceTypesAsScripted`: record `hero-chat`, then
    `#expect(demo.text == "Chiều nay họp online, nhớ gửi file slide trước deadline nha")`, and the commits of
    `online`, `file`, `slide` and `deadline` have `english == true`.
  - `escapeGivesBackTheKeys`: keys `Vieetj⎋`. The frame before `⎋` has text `"Việt"`; the last frame has text
    `"Vieetj"` and `toggle == true`.
  - `nextWordRevisesThePreviousOne`: keys `cais nayf tricky as hell `. At least one frame has `revision == true`; the
    final text is `"cái này tricky as hell "`.
  - `framesFileIsDeterministic`: `renderFramesFile` twice on the same input gives identical bytes ending in `"\n"`.
  - `expectMismatchFails`: a demo whose `expect` differs returns exit code 1 from `run`, and the message names the
    demo id.
  - `checkModeDetectsStaleFile`: write a frames file, change one byte, then
    `run(["--check", "--script", s, "--out", o])` returns 1. The untouched file returns 0.
  - `unknownKeyNotationIsAUsageError`: an unknown argument returns 2.
- [ ] **Step 2: Run the tests and see them fail.**
  Run: `swift test --package-path Packages/VietnameseEngine --scratch-path .build-demo --filter SiteDemoFramesTests`.
  Expected: compile errors for the missing target.
- [ ] **Step 3: Implement `DemoScript`, `FrameRecorder`, `renderFramesFile` and `SiteDemoFrames.run`.** Load the
  resources once per run. Use one `Engine` per configuration and a fresh `EngineDriver` per demo. Read `raw` from
  `state.activeRawKeys` before sending a boundary key. Foundation is allowed in this executable, never in
  `VietnameseEngine`.
- [ ] **Step 4: Write `site/demo/script.json`** with these demos. The last three hero drafts are proposals: if the
  engine disagrees, rewrite the sentence (design 8).

  | id | method / style | keys | expect |
  |---|---|---|---|
  | `hero-chat` | telex / traditional | `Chieeuf nay hojp online, nhows guwir file slide truwowcs deadline nha` | `Chiều nay họp online, nhớ gửi file slide trước deadline nha` |
  | `hero-email` | telex / traditional | `Anh gwir laij email cho team truwowcs meeting nhes` | `Anh gửi lại email cho team trước meeting nhé` |
  | `hero-note` | telex / traditional | `Nhows mua router wifi mowis, check laij password` | `Nhớ mua router wifi mới, check lại password` |
  | `behaviour-punctuation` | telex / traditional | `Minhf check email, review slide.⏎` | `Mình check email, review slide.\n` |
  | `behaviour-revision` | telex / traditional | `cais nayf tricky as hell ` | `cái này tricky as hell ` |
  | `behaviour-escape` | telex / traditional | `Vieetj⎋` | `Vieetj` |
  | `card-anywhere` | telex / traditional | `vietj tieengs dangd` | `việt tiếng đang` |
  | `card-slang` | telex / traditional | `dzoo dzaajy heoj` | `dzô dzậy hẹo` |
  | `card-telex` | telex / traditional | `vieetj` | `việt` |
  | `card-vni` | vni / traditional | `vie65t` | `việt` |
  | `card-traditional` | telex / traditional | `hoaf` | `hòa` |
  | `card-modern` | telex / modern | `hoaf` | `hoà` |

- [ ] **Step 5: Generate the file and run the tests.**
  Run: `swift run --package-path Packages/VietnameseEngine --scratch-path .build-demo site-demo-frames && swift test --package-path Packages/VietnameseEngine --scratch-path .build-demo --filter SiteDemoFramesTests`.
  Expected: `site/demo/frames.json` written; all tests pass. Then run `site-demo-frames --check`: exit 0.
- [ ] **Step 6: Run the whole engine suite** (the new test target must not disturb the others).
  Run: `swift test --package-path Packages/VietnameseEngine --scratch-path .build-demo`.
  Expected: same pass count as `main` plus the new tests; known issues unchanged.
- [ ] **Step 7: Commit:** `feat(engine): generate the website demo frames from the engine`.

### Task 2: Vendor anime.js 4.5.0 with its decision record

**Files:**
- Create:
  - `site/static/assets/vendor/anime.umd.min.js`: byte-exact `dist/bundles/anime.umd.min.js` from the npm tarball
    `animejs-4.5.0.tgz`, obtained with `npm pack animejs@4.5.0` into an empty temporary folder. Do not run it there.
  - `site/static/assets/vendor/anime.LICENSE.txt`: the package's licence text, verbatim.
  - `docs/decisions/0603-website-motion-library.md` (QA-R24, a dependency needs a decision record):
    - status accepted, date 17/11/2026
    - **decision:** anime.js 4.5.0, vendored as its UMD bundle and loaded with `defer` on pages that animate
    - **why UMD and not the ESM bundle:** a module would import other files by URLs that `fingerprintAssets` does not
      rewrite, which breaks the immutable cache; the UMD bundle is one fingerprinted `<script src>`.
    - **why no npm:** the generator has no dependencies.
    - the update procedure: new tarball, compare SHA-256, update the notices
    - the forbidden APIs (`splitText`, `scrambleText`, anything writing `innerHTML`) under the CSP
- Modify:
  - `scripts/check-spdx.sh` `EXCLUDED`: add `^site/static/assets/vendor/`.
    - `EXCLUDED` must stay exactly two `r"..."` lines: `test_licences_and_wording.py` parses them.
    - Add the matching case to the lint's self-test, if `scripts/tests` has one for `EXCLUDED`.
  - `THIRD_PARTY_NOTICES.md` section 5 "Website": replace the placeholder sentence with an anime.js 4.5.0 entry. Same
    shape as the Sparkle entry: project URL `https://animejs.com`, file path, version, the SHA-256 of the vendored
    file, the licence line written as "anime.js 4.5.0 is MIT" (the wording test's allowed pattern) with the
    copyright line, the verbatim licence text, and the date it was compared.
  - `docs/superpowers/specs/2026-11-16-website-redesign-design.md` 7.2: the vendored file is
    `dist/bundles/anime.umd.min.js`, loaded as a classic deferred script (builder's call, ADR 0603).

**Interfaces:**
- **Produces:** the global `anime` (anime.js 4 API: `anime.animate`, `anime.createTimeline`, `anime.stagger`,
  `anime.svg.createDrawable`, `anime.svg.createMotionPath`, `anime.onScroll`, `anime.utils`), available to scripts
  that run after `/assets/vendor/anime.umd.min.js`.

- [ ] **Step 1: Write the failing test** in `site/test.mjs`: check
  `"vendor: anime.js 4.5.0 is vendored byte-exact with its licence (ADR 0603)"`.
  - The vendored file starts with `/**\n * Anime.js - UMD minified bundle\n * @version v4.5.0`.
  - Its SHA-256 equals the value written in `THIRD_PARTY_NOTICES.md` (parse the hex string from the anime.js entry).
  - `anime.LICENSE.txt` exists and contains `Julian Garnier`.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: that check FAILS (file missing).
- [ ] **Step 3: Vendor the files, write the notice entry, the ADR and the SPDX exclusion.**
- [ ] **Step 4: Run** `node site/test.mjs && scripts/check-spdx.sh && scripts/tests/run.sh`. Expected: all pass,
  `check-spdx` reports 0 problems, the scripts self-test passes.
- [ ] **Step 5: Commit:** `build(site): vendor anime.js 4.5.0 for the website motion`.

### Task 3: Visual system, page shell and the trademark token

**Files:**
- Modify:
  - `site/static/assets/style.css`:
    - replaced, not patched: tokens, base, shell, the components (button, card, window, tag, keycap, section header)
      and the inner pages
    - stays under 800 lines
    - `release-notes.css` is untouched
  - `site/lib/layout.mjs`:
    - new header, footer, inline SVG symbol `#mark`, `page.styles`, theme colours
  - `site/lib/brand.mjs`:
    - read the optional `APP_TRADEMARK_SIGN` as `trademarkSign` (default `""`)
  - `site/lib/context.mjs`:
    - `tokensFor` adds `AppNameTM: brand.name + brand.trademarkSign`
  - `site/content/{vi,en}/ui.mjs`:
    - `nav.features`, `nav.downloadCta`, `footer.language`
    - titles and descriptions use `{{AppNameTM}}` where they name the product
  - `site/test.mjs`
- Create:
  - `site/static/assets/home.css`: home sections only, linked from home pages through `page.styles`. Task 5 fills it;
    this task creates it with the section scaffolding.

**Interfaces:**
- **Produces:**
  - `renderDocument(ctx, page)` accepts `page.styles?: string[]` (extra stylesheets, fingerprinted) and keeps
    `page.scripts?: string[]` (classic `defer`, in order).
  - **Header:**
    - the mark plus `{{AppName}}` (no sign in the header) linking home
    - nav links in this order: features (`/#tinh-nang`, `/en/#features`), compat, support
    - a "Tải về" / "Download" button to the download route
    - the language switch
  - **Footer:** privacy, changelog, repository, appcast, donate, language switch.
  - **Tokens** (CSS custom properties on `:root`, dark values under `prefers-color-scheme: dark`):
    - surfaces: `--ink #141619`, `--paper #FAF8F4`, `--paper-2 #F1F0EC`
    - green: `--green #0EA674`, `--green-text` (darker, AA on `--paper`), `--green-on-dark #3DDC97`
    - neutrals: `--muted`, `--line`
    - shape: `--radius-s 10px`, `--radius-l 16px`, `--shadow-window`
    - layout: `--content 1120px`
  - Components: `.btn`, `.btn-ghost`, `.card`, `.mac-window`, `.tag`, `.keycap`, `.section-head`, `.band-dark`
    (dark in both schemes).
  - `{{AppNameTM}}` is available to every content string through `f()` and `p()`.

- [ ] **Step 1: Write the failing checks** in `site/test.mjs`:
  - `"shell: no inline style attribute or style element on any page (design 4)"`: every built page fails on
    `/\sstyle\s*=/i` and on `<style`, except the existing release-notes rule.
  - `"shell: header links features, compatibility, support, download and the other language; footer links privacy, changelog, repository, appcast, donate"`:
    check the vi and en home pages and one inner page.
  - `"shell: the trademark sign is in titles and prose, never in buttons, navigation or URLs (spec 03 Name and trademark sign)"`:
    - `<title>` of `/` contains the built name followed by `APP_TRADEMARK_SIGN` from brand.env.
    - No `href=` value contains `™`.
    - No `<nav>` or `class="btn"` element text contains `™`.
    - No page contains the literal `{{AppNameTM}}`.
  - `"tokens: text colours meet WCAG AA in light and dark (design 7.7)"`:
    - Parse `style.css` custom properties for `:root` and the dark block.
    - Assert contrast ≥ 4.5 for `--ink` on `--paper`, `--muted` on `--paper`, `--green-text` on `--paper`, the
      button text on `--green` and the dark equivalents.
    - Write a small `contrast(hexA, hexB)` helper in the test (WCAG relative luminance).
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: the four new checks FAIL.
- [ ] **Step 3: Implement** the brand field, the token, the shell and the stylesheet. The visual system follows
  design 7.1:
  - system font stack
  - headlines weight 700 to 800 with negative tracking
  - body 16 to 18 px
  - `ui-monospace` only for keycaps
  - 44 px touch targets
  - visible focus rings
  - one accent colour

  Inner pages keep their markup classes or get the new component classes, so every existing page renders cleanly.
- [ ] **Step 4: Run** `node site/test.mjs && node site/build.mjs --out /tmp/site-shell`. Expected: all checks pass;
  the build prints its page count with no warning beyond today's.
- [ ] **Step 5: Commit:** `feat(site): new visual system, page shell and trademark token`.

### Task 4: Home page content in both languages

**Files:**
- Modify:
  - `site/content/vi/pages.mjs` and `site/content/en/pages.mjs`: replace `home` with the new structure. Remove
    `demoPlaceholder`, `demoCaption`, `demoAlt`, `typed`, `why`; their substance moves into the sections.
  - `site/test.mjs`.

**Interfaces:**
- **Produces:** `home` objects with these keys, the same in both languages (Task 5 renders them):
  - **Hero and section headings:**
    - `h1`, `lede`, `meta` (the line "macOS 12 trở lên · Apple silicon và Intel · Miễn phí, mã nguồn mở")
    - `hero: { windowTitle, peerName, peerMessage, keepTag, pause, play, keysLabel, sentLabel, menuBarLabel }`.
      `keepTag` uses `{{word}}`: vi `"{{word}}: giữ nguyên"`, en `"{{word}}: kept as typed"`.
    - `behaviours: { heading, intro, items: [{ id, title, body }] }`, with ids `punctuation`, `revision`, `escape`
      matching the `behaviour-*` demos. `punctuation` also has `note`: the static statement that in a chat app
      Return reaches the app after the correction (P0-3, ENG-R910), never animated.
  - **Cards:**
    - `cards: { heading, items: [{ id, title, body, demos?: string[], illustration?: string, req: string }] }`
    - ids in order: `anywhere`, `slang`, `method`, `macros`, `layouts`, `perApp`
    - `demos` holds frames ids: `["card-anywhere"]`, `["card-slang"]`, and for `method`:
      `["card-telex", "card-vni", "card-traditional", "card-modern"]`
    - `illustration` holds static content keys for `macros` (`dc` gives "được", captioned as a macro you define),
      `layouts` (QWERTY, QWERTZ, AZERTY, Dvorak, Colemak) and `perApp` (Terminal: English, Zalo: Vietnamese, from the
      current `why` copy)
    - `req` cites the requirement: ENG-R107, P0-2/ENG-R316, D1/D2, PRD-R2
  - **Apps and Secure Input:** `apps: { heading, intro, categories: { browser, chat, office, notes, launcher, terminal, developer }, link, secureInput: { title, body } }`.
  - **Proof:** `proofHeading` and `proof` as today. Copy updated so that the open-source item names engine MPL-2.0 and
    app GPL-3.0-or-later.
  - **Install:** `install: { heading, steps: [3 strings], brewLabel }`. Step 2 uses the same permission names as
    `download.reqPermission`, including its `{{verifyHtml}}` marker.
  - **Closing:** `closing: { heading, donateLine }`.
  - **Download block:** `downloadBtn`, `downloadSub`, `noReleaseBtn`, `preRelease`, `brewLabel`, `allDownloads` stay
    as they are.
  - **Copy fixed by the design** (vi, with the English equivalent):
    - `h1` = "Gõ tiếng Việt lẫn tiếng Anh, không cần chuyển." (en "Type Vietnamese and English without switching.")
    - section headings "Một câu, hai thứ tiếng", "Gõ theo cách của bạn", "Chạy trong app bạn dùng hằng ngày",
      "Ba điều bạn có thể kiểm chứng", "Cài trong một phút"
    - the en `behaviours.intro` explains, for a reader who may not type Vietnamese, that Vietnamese keyboards turn
      letters into accents and would garble English words, and that {{AppName}} leaves English words as typed
      (design 7.6)

- [ ] **Step 1: Write the failing check**
  `"content: home copy has the same keys in vi and en, uses file not tệp, and has no dash characters"`:
  - Deep key-set equality of `home` between the two languages.
  - No `tệp` in vi `home`.
  - No `—` or `–` in either language.
  - `h1` equals the vi and en values above.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: FAIL.
- [ ] **Step 3: Write the copy.** PRD-R62 tone. Prose that names the product uses `{{AppNameTM}}`; buttons use
  `{{AppName}}`.
- [ ] **Step 4: Run** `node site/test.mjs`. Expected: the new check passes. Home rendering checks may fail until
  Task 5; list which ones in the commit body.
- [ ] **Step 5: Commit:** `feat(site): home page copy for the redesign`.

### Task 5: Home page sections rendered with their final states

**Files:**
- Create:
  - `site/lib/demos.mjs`
  - `site/lib/pages/home/hero.mjs`
  - `site/lib/pages/home/behaviours.mjs`
  - `site/lib/pages/home/cards.mjs`
  - `site/lib/pages/home/apps.mjs`
  - `site/lib/pages/home/proof.mjs`
  - `site/lib/pages/home/install.mjs`
  - `site/lib/pages/home/closing.mjs`
- Modify:
  - `site/lib/pages/home.mjs`: composes the sections, keeps `downloadBlock` exported for hero and closing, and returns
    `styles: ["/assets/home.css"]`.
  - `site/lib/context.mjs`: `ctx.demos`; drop `ctx.demo` (the video list).
  - `site/static/assets/home.css`.
  - `site/test.mjs`: the source tone scan skips `site/demo/*.json`, with a comment: engine input and output; the modern
    placement is the setting's example.

**Interfaces:**
- **Consumes:** `site/demo/frames.json` (Task 1 schema), `home` content (Task 4), components (Task 3).
- **Produces:**
  - **`site/lib/demos.mjs`:**
    - `loadDemos(path) -> { byId: Map<string, Demo> }`. It validates `schemaVersion === 1`, then that every frame has
      a string `key` and a string `text`, and that the last frame's `text === demo.text`. On failure it throws
      ``Error(`site/demo/frames.json: ${id}: ${reason}`)``.
    - `wordsOf(demo) -> Array<{ text: string, english: boolean }>` splits the final text into words and separators,
      marking the words whose commit has `english: true`.
  - **Markup contract for Task 6:**
    - **Hero:**
      - `<div class="mac-window" data-hero data-demo-frames="<JSON of [hero-chat, hero-email, hero-note] demos>">`
      - inside it:
        - `[data-input]` holds the finished first sentence as text
        - `[data-keys]` holds the last keys as `<kbd class="keycap">`
        - `[data-tags]` holds one `<span class="tag">` per English word, from `keepTag`
        - `[data-sent]` is the sent bubble, holding the first sentence
      - a `<button type="button" data-motion-toggle aria-pressed="false">` with the pause label
      - a visually hidden `<p>` with the finished sentence; the window is `aria-hidden="true"`
      - above the window, a static mini menu bar: the mark in its Vietnamese state with `menuBarLabel`, unchanged for
        the whole demo (design 6)
    - **Section 2:** `<section id="tinh-nang">` (en `id="features"`). Each behaviour is a
      `<figure data-demo="behaviour-…" data-demo-frames="<JSON of that demo>">` with the final text already in its
      `[data-input]`.
    - **Section 3 cards:**
      - Engine cards show `<code>keys</code>` and the result: `<span class="out">`, or `<em>` for `card-modern`.
      - Static cards carry `data-static`.
      - Each card ends with its `req` in a `<small>`.
    - **Section 4:**
      - `<div class="hub" data-hub>` with an inline SVG of thread paths (`<path data-thread>`) from the mark to
        category nodes, and a `<ul>` fallback list of categories with up to four app names (tier 1 first) from
        `ctx.data.matrix`
      - while every entry is `notVerified`, no date and no word "kiểm tra"/"verified" in the section
      - the Secure Input card below the hub

- [ ] **Step 1: Write the failing checks** in `site/test.mjs`:
  - `"home: PRD-R73 items on / and /en/"`. Each page has:
    - the h1
    - the download button with version and minimum macOS, or the no-release state, depending on the fixture
    - `brew install --cask`
    - three proof items
    - a link to the compat route
    - no `<video>`
  - `"home: every demo's final text is in the static HTML (design 7.2, no JavaScript)"`. For every demo id used by the
    page, the escaped final text (trimmed, Return removed) occurs outside attributes.
  - `"home: data-demo-frames parses and matches frames.json"`.
  - `"home: tags name exactly the English words of the hero sentence"`. With today's frames, the tags are online, file,
    slide and deadline; build the expected set from frames.json, not by hand.
  - `"home: compat hub shows categories and app names without verified wording while entries are notVerified"`, using
    the fallback data. A second build with `site/fixtures/populated` shows the verified dates.
  - `"home: the no-release state appears in hero and closing with site/fixtures/empty"` (Review Focus 4).
  - `"demos: loadDemos rejects a frames file whose last frame differs from text"`, with a temporary file.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: the new checks FAIL.
- [ ] **Step 3: Implement** `demos.mjs` and the section renderers. `home.css` lays out the sections:
  - hero two columns from 1024 px, one column below
  - the window reserves its height (no layout shift)
  - the hub is visible from 900 px; the list replaces it below
  - the dark band for proof
  - the three install steps
- [ ] **Step 4: Run** `node site/test.mjs`. Expected: all pass. Then `node site/build.mjs --out /tmp/site-home` and
  open `/tmp/site-home/index.html` in a text viewer to confirm the section order of design 7.3.
- [ ] **Step 5: Commit:** `feat(site): home page sections with engine-generated final states`.

### Task 6: Motion script for the home page

**Files:**
- Create: `site/static/assets/home.js`, a classic script in a UMD-style wrapper. It exports `SiteMotion` to `window`
  and to `module.exports` when `module` exists, so `site/test.mjs` can load its pure functions with `createRequire`.
- Modify:
  - `site/lib/pages/home.mjs`: `scripts: ["/assets/vendor/anime.umd.min.js", "/assets/home.js"]` (Task 5 already
    returns the styles).
  - `site/test.mjs`.

**Interfaces:**
- **Consumes:** the markup contract of Task 5 and the global `anime` of Task 2.
- **Produces** (pure, tested):
  - `SiteMotion.schedule(frames, seed) -> number[]`, the delay in ms before each frame:
    - a character takes 80 to 110 ms, with deterministic jitter from `seed`
    - a frame after a `commit` adds 250 to 400 ms
    - `⎋` waits 700 ms before it
    - `⏎` waits 400 ms before it
  - `SiteMotion.keyLabel(key, lang) -> string`: `" "` gives "space"; `"⏎"` gives "return"; `"⎋"` gives "esc"; any
    other key is itself.
  - `SiteMotion.shouldAnimate({ reducedMotion, hidden, visible }) -> boolean`: true only when not reduced, not hidden
    and visible.
  - `SiteMotion.tagsFor(frames) -> string[]`: the `commit.raw` of commits with `english: true`, in order.
- **Behaviour** (DOM, verified in Task 9):
  - **Hero:** types the three hero demos in rotation:
    - the input text follows each frame's `text`
    - the keys strip keeps the last 8 keycaps
    - a tag pops in when an English commit lands (spring or `outBack`, 300 to 500 ms)
    - at the end the message moves into the sent bubble, then the next sentence starts
  - **Pause:** the button toggles `aria-pressed` and its label, and pauses or resumes the timeline. Loops also pause
    when the hero leaves the viewport (IntersectionObserver) and on `visibilitychange`.
  - **Section 2:** each demo plays once when it scrolls into view, with a replay button.
  - **Section 3:** engine cards swap keys to result on hover and focus (CSS transition, no JS needed).
  - **Section 4:** threads draw in with `anime.svg.createDrawable` when the hub enters the viewport. Dots travel with
    `createMotionPath`, under the same pause rules.
  - **Reduced motion:** nothing autoplays, the final states stay, and the threads are drawn statically.

- [ ] **Step 1: Write the failing checks** in `site/test.mjs`:
  - `"motion: schedule is deterministic and inside the timing rules"`. Same seed gives the same delays; character
    delays are in [80, 110]; commit frames are at least 250 ms; `⎋` and `⏎` delays are as specified.
  - `"motion: keyLabel and tagsFor"`, using frames.json `hero-chat`.
  - `"motion: shouldAnimate is false under reduced motion, hidden tab or off-screen"` (Review Focus 3).
  - `"motion: first-party scripts never write markup or style attributes"` (Review Focus 1). For `home.js` (and later
    `copy.js`), assert none of `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`,
    `setAttribute("style"`, `setAttribute('style'`, `cssText`, `eval(`, `new Function`, `splitText`,
    `scrambleText` occurs.
  - `"motion: home page JavaScript is at most 60 KB gzipped (design 7.8)"`. Sum of `zlib.gzipSync(level 9)` sizes of
    every script `src` referenced by `dist/index.html`, at most 61440.
  - `"motion: scripts only on the home pages"`. No `anime.umd.min.js` reference outside `/` and `/en/`.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: the new checks FAIL.
- [ ] **Step 3: Implement `home.js`** with the pure functions first, then the DOM wiring. Create text nodes and
  elements with `textContent` and `createElement`; set styles with `el.style`.
- [ ] **Step 4: Run** `node site/test.mjs`. Expected: all pass.
- [ ] **Step 5: Commit:** `feat(site): animate the home page demos with anime.js`.

### Task 7: Inner pages, donate page copy and copy buttons

**Files:**
- Modify:
  - `site/lib/pages/simple.mjs` (`renderDonate`, the shared page heads)
  - `site/lib/pages/download.mjs`, `site/lib/pages/compat.mjs` and `site/lib/pages/support.mjs`: component classes
    only, no content change
  - `site/content/{vi,en}/pages.mjs` and `support.mjs`:
    - `donate` per PRD-R59
    - `tệp` becomes `file` in vi copy, except exact macOS quotes
    - `{{AppNameTM}}` in titles and prose that name the product
  - `site/test.mjs`
- Create: `site/static/assets/copy.js`, a classic deferred script for `/ung-ho` and `/en/donate/` only:
  - each `<button data-copy="<text>" hidden>` is revealed and copies with `navigator.clipboard.writeText`
  - `<button data-share hidden>` is revealed only when `navigator.share` exists

**Interfaces:**
- **Consumes:**
  - the shell (Task 3)
  - PRD-R59 text in `spec/03-product.md` (vi, verbatim, with `{{AppNameTM}}` and `{{AppName}}` as written there)
  - English from `App/Resources/Localization/Support.xcstrings`: keys `support.donate.body`,
    `support.donate.howTo`, `support.donate.accountTitle`, `support.donate.shareTitle`,
    `support.donate.shareText`, `support.donate.copy`, `support.donate.share`
- **Produces:** `donate` content keys: `title`, `body`, `howTo`, `accountTitle`, `bank` (LioBank), `account`
  (688688678), `copy`, `shareTitle`, `shareText` (with `https://{{host}}`), `share`, `qrCaption`, `qrHow`. The holder
  name is never shown; there is no MoMo or other payment method; the sponsors block appears only when `sponsorsUrl`
  is set.

- [ ] **Step 1: Write the failing checks:**
  - `"donate: PRD-R59 copy verbatim in vi, catalog copy in en, bank details, share text, VietQR, nothing else"`:
    - assert the exact vi lines of PRD-R59, `LioBank`, `688688678`, the share text with the built host, and the
      `/assets/qr/vietqr.png` image
    - no `MoMo`
    - no holder name
  - `"donate: copy and share buttons are hidden without JavaScript and copy.js loads only there"`.
  - `"copy: vi pages say file, never tệp"`. Strip `href` values and the exact quotes allowed by PRD-R64, then search
    every vi page.
  - Extend the Task 6 forbidden-API check to `copy.js`.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** the donate page (two columns: copy left, QR right; one column on phones), the copy wording
  fixes, `copy.js` and the component classes on the other pages.
- [ ] **Step 4: Run** `node site/test.mjs && node site/build.mjs --out /tmp/site-inner`. Expected: all pass.
- [ ] **Step 5: Commit:** `feat(site): restyle the inner pages and give the donate page the in-app copy`.

### Task 8: Spec, decisions and runbook

**Files:**
- Modify:
  - `spec/03-product.md`, PRD-R73 `/` row: replace "20-second screen recording of typing (Telex, English restore,
    per-app switch)" with "typing demo generated from the engine (design of 16/11/2026), which plays without
    autoplay under reduced motion and shows its final state without JavaScript". Add one sentence on the motion rules
    of design 7.2.
  - `docs/decisions/0005-pa-decisions-2026-11-13.md`: a row under "Decisions of 16/11/2026" for the audience, hero B,
    page structure and the demo replacing the video (17/11/2026).
  - `docs/architecture/traceability.md`: PRD-R73 row points at `site/lib/pages/home/`, `site/demo/` and
    `site-demo-frames`.
  - `docs/runbooks/site-deploy.md`: a short "Demo frames" paragraph. After an engine change that alters a demo, run
    `swift run --package-path Packages/VietnameseEngine site-demo-frames` and commit `site/demo/frames.json` in the
    same commit.
  - `docs/decisions/0601-static-site-generator.md`: an amendment line, dated 17/11/2026. The generator now ships two
    first-party scripts and one vendored library on specific pages, and reads `site/demo/frames.json`.

- [ ] **Step 1: Run the doc gates first, to see the baseline:**
  `python3 -I scripts/check-docs.py links && python3 -I scripts/check-docs.py brand && python3 -I docs/architecture/tools/sync_contracts.py --check && scripts/tests/run.sh`.
  Expected: pass on the branch before editing.
- [ ] **Step 2: Edit the documents.** Placeholders only (`{{AppName}}`, `{{app-slug}}`); no literal product name in
  `docs/` or `spec/`.
- [ ] **Step 3: Rerun the same gates.** Expected: all pass. If `sync_contracts.py --check` reports drift, run it
  without `--check` and include the result.
- [ ] **Step 4: Commit:** `docs(site): record the redesigned home page and its demo frames`.

### Task 9: Browser pass under the production CSP

**Files:**
- Create: `site/preview.mjs`, `node site/preview.mjs [--dir site/dist] [--port 4173]`. A static file server on
  `127.0.0.1` that applies `dist/_headers` through `parseHeaders` and `headersForPath` from `site/lib/headers.mjs`,
  so the browser sees the production CSP.
- Modify: `site/test.mjs`.

- [ ] **Step 1: Write the failing check** `"preview: serves the production CSP header for / and immutable caching for /assets/"`.
  Start the server on port 0 in-process (export `startPreview({ dir, port }) -> Promise<{ url, close }>`), fetch `/`
  and one asset, then assert the headers.
- [ ] **Step 2: Run** `node site/test.mjs`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run.** Expected: pass.
- [ ] **Step 5: Browser pass** (Playwright) on `node site/build.mjs && node site/preview.mjs`:
  - **Widths:** 1440, 1024 and 390 px.
  - **Variants:** light and dark (`emulateMedia colorScheme`), reduced motion (`reducedMotion: 'reduce'`) and
    JavaScript disabled.
  - **Pages:** `/`, `/en/`, `/ung-ho/`, `/tuong-thich/`, `/tai-ve/`.
  - **Pass condition:**
    - zero console errors, zero CSP violations
    - no horizontal scroll (`document.documentElement.scrollWidth <= innerWidth`)
    - the hero types and its pause button stops it
    - under reduced motion nothing moves and the final sentences show
    - without JavaScript every final state shows
  - Save screenshots outside the repository and list them in the review.
- [ ] **Step 6: Commit:** `test(site): preview server with production headers for the browser pass`.

## Execution order

**Phase A** has no shared files between its branches:
- Task 1 on its own branch.
- Tasks 2 and 3 in order on the site branch.

**Phase B** merges Task 1 into the site branch, then runs Tasks 4, 5, 6, 7 and 8 in order.

**Phase C:**
- Task 9.
- A whole-branch review.
- The integrator's local gate `Kal-Key-wt/tools/verify-all.sh`. Add `swift run --package-path Packages/VietnameseEngine --scratch-path .build-main site-demo-frames --check` to it.
- Merge to `main` with `--no-ff`.
