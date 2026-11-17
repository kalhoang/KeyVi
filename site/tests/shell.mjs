// SPDX-License-Identifier: GPL-3.0-or-later
// Page shell, design tokens and styles, headers, analytics, fingerprinting, strict mode, brand and tone rules.
import assert from "node:assert/strict";
import { readFile, readdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { build } from "../build.mjs";
import { analyticsCspAdditions, analyticsScriptTag, loadAnalyticsHosts, parseAnalytics } from "../lib/analytics.mjs";
import { loadBrand } from "../lib/brand.mjs";
import { adaptHeaders, extendCsp, headersForPath, parseHeaders, serializeHeaders } from "../lib/headers.mjs";
import { changelogHeadingId } from "../lib/pages/simple.mjs";
import { LANGS, ROUTES, routePath } from "../lib/routes.mjs";
import { modernToneWords, siteToneOffenders, toneOffendersInFiles } from "../lib/tone.mjs";
import { SITE_DIR, ROOT_DIR, walk, attrs, isReleaseNotesPage, sha256Base64, contrast, thirdPartyOrigins, cspOf, assertFingerprinted } from "./helpers.mjs";
import { checkSite } from "./site.mjs";

/** Checks of what every page shares and of the build options. */
export async function runShellChecks(check, fixtures) {
  const { tmp, shipped, fallback, fallbackPages, populated, pop, read } = fixtures;

  await check("shell: no inline style attribute or style element on any page (design 4)", () => {
    const problems = [];
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      for (const [file, html] of pages) {
        const page = file.slice(dist.length + 1);
        if (/\sstyle\s*=/i.test(html)) problems.push(`${page}: style attribute`);
        // The release-notes rule (PLT-R906): that page inlines its stylesheet, allowed by its CSP hash (checked above).
        if (!isReleaseNotesPage(page) && /<style/i.test(html)) problems.push(`${page}: style element`);
      }
    }
    assert.deepEqual(problems, []);
  });

  await check("shell: header links features, compatibility, support, download and the other language; footer links privacy, changelog, repository, appcast, donate", async () => {
    const part = (html, tag) => html.match(new RegExp(`<${tag} class="site-${tag}"[\\s\\S]*?</${tag}>`))?.[0] ?? "";
    const links = (html) => attrs(html, "href").filter((href) => !href.startsWith("#"));
    const features = { vi: "/#tinh-nang", en: "/en/#features" };
    for (const [label, html, lang, other] of [["vi home", read("index.html"), "vi", "/en/"], ["en home", read("en", "index.html"), "en", "/"], ["vi support", read("ho-tro", "index.html"), "vi", "/en/support/"]]) {
      const header = part(html, "header");
      assert.deepEqual(links(header), [routePath("home", lang), features[lang], routePath("compat", lang), routePath("support", lang), routePath("download", lang), other], `${label}: header links in order`);
      assert.match(header, /<a class="btn" href="[^"]+"[^>]*>[^<]+<\/a>/, `${label}: the download link is a button`);
      assert.match(header, /<svg class="mark"[^>]*><use href="#mark"><\/use><\/svg>/, `${label}: the mark beside the name`);
      assert.deepEqual(links(part(html, "footer")), [routePath("privacy", lang), routePath("changelog", lang), shipped.githubRepo, "/appcast.xml", routePath("donate", lang), other], `${label}: footer links in order`);
    }
    // Review Focus 4: without a stable release the header shows the disabled state, never a download button.
    const header = part(fallbackPages.get(join(fallback, "index.html")), "header");
    assert.ok(!header.includes(`href="${routePath("download", "vi")}"`), "no download link in the header without a release");
    assert.match(header, /<span class="btn btn-disabled" aria-disabled="true">Chưa có bản phát hành<\/span>/);
    // The mark is the KV of site/static/favicon.svg (Pa's artwork, CLR-R7): the same shapes, attributes only.
    const favicon = await readFile(join(SITE_DIR, "static", "favicon.svg"), "utf8");
    const symbol = read("index.html").match(/<symbol id="mark"[\s\S]*?<\/symbol>/)?.[0] ?? "";
    for (const points of attrs(favicon, "points")) assert.ok(symbol.includes(`points="${points}"`), `symbol polygon ${points}`);
    assert.match(symbol, /<circle cx="15\.6" cy="4\.3" r="1\.9"/);
  });

  await check("shell: the trademark sign is in titles and prose, never in buttons, navigation or URLs (spec 03 Name and trademark sign)", async () => {
    const brand = await loadBrand(join(ROOT_DIR, "scripts", "brand.env"));
    const env = await readFile(join(ROOT_DIR, "scripts", "brand.env"), "utf8");
    const sign = env.match(/^APP_TRADEMARK_SIGN="([^"]*)"$/m)?.[1] ?? "";
    const signs = new RegExp(`[™®]${sign ? `|${sign}` : ""}`);
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      const named = `${brand.name}${sign}`;
      assert.ok(pages.get(join(dist, "index.html")).match(/<title>([^<]*)<\/title>/)[1].includes(named), `${dist}: home title carries the sign`);
      for (const [file, html] of pages) {
        const page = file.slice(dist.length + 1);
        // Every page title carries the sign: the home pages open with it, the others end with the " · " suffix.
        const title = html.match(/<title>([^<]*)<\/title>/)?.[1];
        assert.ok(title !== undefined, `${page}: has a <title>`);
        const home = page === "index.html" || page === join("en", "index.html");
        assert.ok(home ? title.startsWith(named) : title.endsWith(` · ${named}`), `${page}: title "${title}" carries the sign`);
        assert.equal(html.match(/<meta property="og:title" content="([^"]*)">/)?.[1], title, `${page}: og:title matches the title`);
        // The ui.descriptions are prose ({{AppNameTM}}), so they carry the sign too; the migration guides take their
        // description from the guide intro, which names the product with the sign (plan Task 7).
        assert.ok((html.match(/<meta name="description" content="([^"]*)">/)?.[1] ?? "").includes(named), `${page}: description carries the sign`);
        assert.ok(!html.includes("{{AppNameTM}}"), `${page}: unfilled {{AppNameTM}}`);
        for (const href of attrs(html, "href")) assert.ok(!signs.test(href), `${page}: sign in a URL ${href}`);
        for (const [, nav] of html.matchAll(/<nav\b[^>]*>([\s\S]*?)<\/nav>/g)) assert.ok(!signs.test(nav), `${page}: sign in navigation`);
        for (const [, , text] of html.matchAll(/<(a|p|span|button)\b[^>]*class="(?:[^"]*\s)?btn(?:\s[^"]*)?"[^>]*>([\s\S]*?)<\/\1>/g)) assert.ok(!signs.test(text), `${page}: sign in a button`);
      }
    }
  });

  await check("tokens: text colours meet WCAG AA in light and dark (design 7.7)", async () => {
    const css = await readFile(join(SITE_DIR, "static", "assets", "style.css"), "utf8");
    const block = (text) => Object.fromEntries([...(text ?? "").matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)].map(([, name, value]) => [name, value.trim()]));
    const light = block(css.match(/(?:^|\n):root\s*\{([^}]*)\}/)?.[1]);
    const dark = { ...light, ...block(css.match(/@media \(prefers-color-scheme: dark\)\s*\{\s*:root\s*\{([^}]*)\}/)?.[1]) };
    const resolve = (tokens, name, depth = 0) => {
      const value = tokens[name];
      const ref = value?.match(/^var\((--[\w-]+)\)$/);
      return ref && depth < 5 ? resolve(tokens, ref[1], depth + 1) : value;
    };
    // Text on its background: body, muted and link text on both surfaces, the tag, the button, the dark band.
    const pairs = [["--ink", "--paper"], ["--muted", "--paper"], ["--muted", "--paper-2"], ["--green-text", "--paper"], ["--green-text", "--paper-2"],
      ["--green-text", "--green-soft"], ["--muted", "--green-soft"], ["--on-green", "--green"], ["--on-night", "--night"], ["--on-night-muted", "--night"], ["--green-on-dark", "--night"]];
    const problems = [];
    for (const [scheme, tokens] of [["light", light], ["dark", dark]]) {
      for (const [text, background] of pairs) {
        const [a, b] = [resolve(tokens, text), resolve(tokens, background)];
        if (!/^#[0-9a-f]{6}$/i.test(a ?? "") || !/^#[0-9a-f]{6}$/i.test(b ?? "")) { problems.push(`${scheme}: ${text} or ${background} is not a #rrggbb value`); continue; }
        const ratio = contrast(a, b);
        if (ratio < 4.5) problems.push(`${scheme}: ${text} ${a} on ${background} ${b} is ${ratio.toFixed(2)}:1`);
      }
    }
    assert.deepEqual(problems, []);
  });

  await check("styles: keyboard focus never reshapes an element; print turns the dark band into dark text on white", async () => {
    const css = (await readFile(join(SITE_DIR, "static", "assets", "style.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    // The body of the at-rule that starts at `head`, by brace matching (one level of nesting is enough here).
    const atRule = (head) => {
      const start = css.indexOf(head);
      if (start < 0) return "";
      let depth = 0;
      for (let i = css.indexOf("{", start); i < css.length; i += 1) {
        if (css[i] === "{") depth += 1;
        if (css[i] === "}" && (depth -= 1) === 0) return css.slice(css.indexOf("{", start) + 1, i);
      }
      return "";
    };
    const rules = (text) => [...text.matchAll(/([^{}@;]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({ selectors: selector.split(",").map((part) => part.trim()), body }));
    const sets = (body, property) => new RegExp(`(?:^|[;{\\s])${property}\\s*:\\s*([^;]+)`).exec(body)?.[1].trim();
    // A select keeps its 10 px corners when focused: a focus rule may draw an outline, never change border-radius.
    for (const { selectors, body } of rules(css)) {
      if (selectors.some((selector) => selector.includes(":focus"))) assert.equal(sets(body, "border-radius"), undefined, `${selectors.join(", ")} sets border-radius`);
    }
    // Every light-on-dark colour of the band is reset in print, where the band has no background.
    const print = rules(atRule("@media print"));
    const printColour = (selector) => print.filter((rule) => rule.selectors.includes(selector)).map((rule) => sets(rule.body, "color")).filter(Boolean).at(-1);
    const banded = rules(css.replace(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, "")).filter(({ selectors, body }) => selectors.some((selector) => selector.startsWith(".band-dark")) && sets(body, "color"));
    assert.ok(banded.length >= 3, "the band rules were found");
    for (const { selectors } of banded) {
      for (const selector of selectors) assert.match(printColour(selector) ?? "", /^(inherit|#000000)$/, `print resets the colour of ${selector}`);
    }
  });

  await check("populated: language switch and hreflang alternates point at the sibling page", () => {
    const html = read("tai-ve", "index.html");
    assert.match(html, /hreflang="en" href="https:\/\/[^"]+\/en\/download\/"/);
    assert.match(html, /<a class="lang-switch" href="\/en\/download\/"/);
    assert.match(read("en", "download", "index.html"), /<a class="lang-switch" href="\/tai-ve\/"/);
  });

  await check("changelog heading ids: releases and betas get v<version>, other headings keep their slug", () => {
    assert.equal(changelogHeadingId(2, "[1.2.0] - 2026-12-01"), "v1.2.0");
    assert.equal(changelogHeadingId(2, "[1.3.0-beta.2] - 2026-12-05"), "v1.3.0-beta.2");
    assert.equal(changelogHeadingId(2, "v2.0.0"), "v2.0.0");
    assert.equal(changelogHeadingId(2, "[Unreleased]"), undefined);
    assert.equal(changelogHeadingId(3, "[1.2.0] - 2026-12-01"), undefined);
  });

  await check("fallback: pages state the macOS 12 Monterey floor and its permission path (Q6, ADR 0315, PRD-R40)", () => {
    const page = (...p) => fallbackPages.get(join(fallback, ...p));
    assert.match(page("tai-ve", "index.html"), /macOS 12 Monterey trở lên/);
    assert.match(page("en", "download", "index.html"), /macOS 12 Monterey or later/);
    for (const html of fallbackPages.values()) assert.ok(!/Sonoma|macOS 15 Sequoia/.test(html), "no stale macOS 15 floor");
    const vi = page("ho-tro", "index.html");
    const en = page("en", "support", "index.html");
    assert.ok(vi.includes("Tùy chọn Hệ thống &gt; Bảo mật &amp; Quyền riêng tư &gt; Quyền riêng tư &gt; <strong>Trợ năng</strong>"), "vi macOS 12 path");
    assert.ok(en.includes("System Preferences &gt; Security &amp; Privacy &gt; Privacy &gt; <strong>Accessibility</strong>"), "en macOS 12 path");
    assert.match(vi, /macOS 12 Monterey trở lên/);
    assert.match(en, /macOS 12 Monterey or later/);
    assert.match(page("rieng-tu", "index.html"), /Trợ năng \(macOS 12 tới 26\)/);
    assert.match(page("en", "privacy", "index.html"), /Accessibility \(macOS 12 to 26\)/);
  });

  await check("fallback: changelog fills {{AppName}} from brand.env", () => {
    const en = fallbackPages.get(join(fallback, "en", "changelog", "index.html"));
    assert.ok(!en.includes("{{AppName}}"));
  });

  await check("site notice: on every page in both languages when enabled, nowhere when off (QA-R38, QA-R54)", async () => {
    for (const html of [...fallbackPages.values(), ...pop.values()]) assert.ok(!html.includes("site-notice"), "no notice by default");
    const configPath = join(tmp, "notice-config.json");
    const base = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
    const notice = { enabled: true, vi: "Bản 1.2.0 làm mất chữ trong Terminal, hãy cập nhật lên 1.2.1.", en: "Version 1.2.0 drops letters in Terminal; update to 1.2.1.", link: "https://github.com/OWNER/REPO/issues/42" };
    await writeFile(configPath, JSON.stringify({ ...base, banner: notice }));
    const out = join(tmp, "notice");
    await build({ outDir: out, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath });
    const files = (await walk(out)).filter((f) => f.endsWith(".html") && !isReleaseNotesPage(f.slice(out.length + 1)));
    assert.ok(files.length >= ROUTES.length * LANGS.length);
    for (const file of files) {
      const html = await readFile(file, "utf8");
      const lang = file.slice(out.length + 1).startsWith("en/") ? "en" : "vi";
      const aside = html.match(/<aside class="site-notice"[\s\S]*?<\/aside>/)?.[0] ?? "";
      assert.ok(aside.includes(notice[lang].replace("&", "&amp;")), `${file}: ${lang} notice text`);
      assert.ok(aside.includes(`href="${notice.link}"`), `${file}: link to the pinned issue`);
      assert.ok(html.indexOf("site-notice") < html.indexOf('<main id="main"'), `${file}: at the top of the page`);
      assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), `${file}: no inline script (PRD-R74)`);
    }
    await writeFile(configPath, JSON.stringify({ ...base, banner: { enabled: true, vi: "", en: "x", link: "" } }));
    await assert.rejects(() => build({ outDir: join(tmp, "notice-bad"), today: "2026-11-13", configPath }), /banner/);
    await writeFile(configPath, JSON.stringify({ ...base, banner: { ...notice, link: "javascript:alert(1)" } }));
    await assert.rejects(() => build({ outDir: join(tmp, "notice-bad"), today: "2026-11-13", configPath }), /https/);
  });

  await check("release-notes stylesheet is allowed by static/_headers (PLT-R906)", async () => {
    const css = await readFile(join(SITE_DIR, "static", "assets", "release-notes.css"), "utf8");
    const headers = await readFile(join(SITE_DIR, "static", "_headers"), "utf8");
    const policies = headers.split("\n").filter((line) => line.trim().startsWith("Content-Security-Policy:"));
    assert.ok(policies.length >= 2, "site-wide and release-notes policies");
    for (const policy of policies) assert.ok(policy.includes(`'sha256-${sha256Base64(css)}'`), `add 'sha256-${sha256Base64(css)}' to style-src in every CSP of static/_headers`);
  });

  await check("static/_headers: CSP, HSTS, frame, referrer, permissions and caching rules (ADR 0602)", async () => {
    const rules = parseHeaders(await readFile(join(SITE_DIR, "static", "_headers"), "utf8"));
    const header = (path, name) => headersForPath(rules, path).filter(([n]) => n === name).map(([, v]) => v);
    const site = cspOf(rules, "/")[0] ?? "";
    for (const directive of ["default-src 'self'", "script-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "base-uri 'none'"]) assert.ok(site.includes(directive), directive);
    assert.match(header("/", "Strict-Transport-Security")[0] ?? "", /^max-age=(\d+)/);
    assert.ok(Number(header("/", "Strict-Transport-Security")[0].match(/max-age=(\d+)/)[1]) >= 31536000, "HSTS for at least a year");
    assert.deepEqual(header("/", "X-Frame-Options"), ["DENY"]);
    assert.deepEqual(header("/", "X-Content-Type-Options"), ["nosniff"]);
    assert.deepEqual(header("/", "Referrer-Policy"), ["no-referrer"]);
    assert.match(header("/", "Permissions-Policy")[0] ?? "", /camera=\(\)/);
    assert.deepEqual(header("/appcast.xml", "Cache-Control"), ["public, max-age=300"]);
    assert.deepEqual(header("/appcast.xml", "Content-Type"), ["application/rss+xml; charset=utf-8"]);
    for (const path of ["/assets/style.css", "/download/app-1.0.0.dmg"]) assert.deepEqual(header(path, "Cache-Control"), ["public, max-age=31536000, immutable"], path);
    assert.deepEqual(header("/tai-ve/", "Cache-Control"), [], "pages are not cached for a year");
    const notes = cspOf(rules, "/release-notes/1.0.0/");
    assert.equal(notes.length, 2, "release-notes pages get the site policy plus their own (both apply)");
    assert.match(notes[1], /^default-src 'none';/);
    assert.ok(!/script-src/.test(notes[1]), "no script on a release-notes page");
  });

  await check("_headers parser: round trip, every matching block applies, unsupported input is refused", () => {
    const text = "# c\n/*\n  A: 1\n  B: x; y\n\n/assets/*\n  C: 2\n\n/a.xml\n  D: 3\n";
    const rules = parseHeaders(text);
    assert.deepEqual(parseHeaders(serializeHeaders(rules)), rules);
    assert.deepEqual(headersForPath(rules, "/assets/x.css"), [["A", "1"], ["B", "x; y"], ["C", "2"]]);
    assert.deepEqual(headersForPath(rules, "/a.xml"), [["A", "1"], ["B", "x; y"], ["D", "3"]]);
    assert.deepEqual(headersForPath(rules, "/assets"), [["A", "1"], ["B", "x; y"]], "a prefix rule needs the slash");
    for (const bad of ["/*.css\n  A: 1\n", "/:splat\n  A: 1\n", "  A: 1\n", "/*\n  A 1\n", "/*\n  A: 1\n/*\n  B: 2\n", "/*\n  A:\n"]) {
      assert.throws(() => parseHeaders(bad), /_headers line/, JSON.stringify(bad));
    }
    assert.equal(extendCsp("default-src 'self'; script-src 'self'", { "script-src": ["https://a.test"], "connect-src": ["https://b.test"] }),
      "default-src 'self'; script-src 'self' https://a.test; connect-src 'self' https://b.test");
    const adapted = adaptHeaders(parseHeaders("/*\n  Content-Security-Policy: script-src 'self'\n/r/*\n  Content-Security-Policy: default-src 'none'\n"), { cspAdditions: { "script-src": ["https://a.test"] }, noindex: true });
    assert.deepEqual(adapted[0].headers, [["Content-Security-Policy", "script-src 'self' https://a.test"], ["X-Robots-Tag", "noindex"]]);
    assert.deepEqual(adapted[1].headers, [["Content-Security-Policy", "default-src 'none'"]], "the release-notes policy is never widened");
  });

  await check("analytics off: no tag, no third-party origin in pages, CSP or dist/_headers (Q7)", async () => {
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      assert.deepEqual((await readdir(join(dist, "assets"))).filter((name) => name.startsWith("analytics")), [], `${dist}: no analytics file`);
      for (const [file, html] of pages) {
        assert.ok(!/data-website-id|umami|posthog/i.test(html.replace(/<main[\s\S]*<\/main>/, "")), `${file}: analytics markup without a config`);
        assert.deepEqual([...thirdPartyOrigins(html)], [], `${file}: third-party origin`);
      }
      const headers = await readFile(join(dist, "_headers"), "utf8");
      assert.ok(!/https?:\/\//i.test(headers.replace(/^#.*$/gm, "")), "dist/_headers names no other host");
      assert.ok(!/X-Robots-Tag/.test(headers), "no noindex unless asked");
    }
    // An analytics object whose three values are empty means no analytics too.
    const configPath = join(tmp, "analytics-empty.json");
    await writeFile(configPath, JSON.stringify({ ...shipped, analytics: { provider: "", scriptUrl: "", websiteId: "" } }));
    const out = join(tmp, "analytics-empty");
    await build({ outDir: out, today: "2026-11-13", configPath });
    const home = await readFile(join(out, "index.html"), "utf8");
    assert.deepEqual([...thirdPartyOrigins(home)], []);
    assert.match(await readFile(join(out, "rieng-tu", "index.html"), "utf8"), /Phân tích truy cập: không có/);
  });

  await check("analytics on (site/config.json): the Umami tag on every website page, only its origin, never on release notes", async () => {
    // Pa, 2026-11-13 (Q7 follow-up): self-hosted Umami 3.5.0 at stats.kal.vn; the website id is public.
    assert.deepEqual(shipped.analytics, { provider: "umami", scriptUrl: "https://stats.kal.vn/script.js", websiteId: "42572ae2-f406-4ed3-ba33-8324a046d7c9" });
    const brand = await loadBrand(join(ROOT_DIR, "scripts", "brand.env"));
    const origin = "https://stats.kal.vn";
    const tag = `<script defer src="${origin}/script.js" data-website-id="42572ae2-f406-4ed3-ba33-8324a046d7c9" data-domains="${brand.host}" data-do-not-track="true"></script>`;
    const out = join(tmp, "analytics");
    await build({ outDir: out, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated") });
    const files = (await walk(out)).filter((f) => f.endsWith(".html"));
    assert.ok(files.length >= ROUTES.length * LANGS.length + 1, "every route in both languages and the 404 page");
    for (const file of files) {
      const html = await readFile(file, "utf8");
      if (isReleaseNotesPage(file.slice(out.length + 1))) { assert.ok(!html.includes("data-website-id"), `${file}: analytics on a release-notes page`); continue; }
      assert.equal(html.split(tag).length - 1, 1, `${file}: exactly one analytics tag`);
      assert.ok(html.indexOf(tag) < html.indexOf("</head>"), `${file}: in the head`);
      assert.deepEqual([...thirdPartyOrigins(html)], [origin], `${file}: only the Umami origin`);
      assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), `${file}: no inline script (PRD-R74)`);
      const meta = attrs(html, "content").find((value) => /default-src/.test(value)).replace(/&#39;/g, "'");
      assert.match(meta, new RegExp(`script-src 'self' ${origin.replace(/\./g, "\\.")};`), `${file}: meta CSP script-src`);
      assert.match(meta, new RegExp(`connect-src 'self' ${origin.replace(/\./g, "\\.")}$`), `${file}: meta CSP connect-src`);
    }
    assert.deepEqual((await readdir(join(out, "assets"))).filter((name) => name.startsWith("analytics")), [], "no local loader: the tag loads Umami's script");
    await checkSite(check, "analytics", out, { allowedScriptTag: tag });
    const rules = parseHeaders(await readFile(join(out, "_headers"), "utf8"));
    const site = cspOf(rules, "/tai-ve/")[0];
    assert.match(site, new RegExp(`script-src 'self' ${origin.replace(/\./g, "\\.")}(;|$)`));
    assert.match(site, new RegExp(`connect-src 'self' ${origin.replace(/\./g, "\\.")}(;|$)`));
    assert.deepEqual([...new Set(site.match(/https:\/\/[^\s;']+/g))], [origin], "the CSP names no other host");
    const notes = cspOf(rules, "/release-notes/1.0.0/");
    assert.ok(notes.some((policy) => /^default-src 'none'/.test(policy) && !/script-src|stats\./.test(policy)), "the release-notes policy allows no script");
    const privacyVi = await readFile(join(out, "rieng-tu", "index.html"), "utf8");
    const privacyEn = await readFile(join(out, "en", "privacy", "index.html"), "utf8");
    for (const needle of ["Umami", "tự vận hành", "không dùng cookie", "không lưu gì trong trình duyệt", "không thu thập dữ liệu cá nhân", "địa chỉ IP không được lưu", "Do Not Track", "lượt xem trang", "tiêu đề trang", `<code>${origin}</code>`]) assert.ok(privacyVi.includes(needle), `vi privacy: ${needle}`);
    for (const needle of ["Umami", "self-hosted", "no cookies", "nothing is stored in your browser", "no personal data", "IP address is not stored", "Do Not Track", "page views", "the page title", `<code>${origin}</code>`]) assert.ok(privacyEn.includes(needle), `en privacy: ${needle}`);
    assert.ok(!/PostHog/.test(privacyVi + privacyEn), "PostHog is gone");
    assert.ok(!/Phân tích truy cập: không có/.test(privacyVi) && !/Visitor analytics: none/.test(privacyEn), "the privacy page states what ships");
  });

  await check("analytics config is validated (provider, https URL on an allowed host, UUID shape, no stray keys)", async () => {
    const configPath = join(tmp, "analytics-bad.json");
    const good = shipped.analytics;
    for (const [analytics, message] of [
      [{ ...good, provider: "posthog" }, /provider/],
      [{ ...good, provider: 42 }, /provider/],
      [{ ...good, scriptUrl: "http://stats.kal.vn/script.js" }, /https/],
      [{ ...good, scriptUrl: "https://tracker.example/script.js" }, /allowed host/],
      [{ ...good, scriptUrl: "https://stats.kal.vn.evil.example/script.js" }, /allowed host/],
      [{ ...good, scriptUrl: "https://user@stats.kal.vn/script.js" }, /scriptUrl/],
      [{ ...good, scriptUrl: "https://stats.kal.vn:8443/script.js" }, /scriptUrl/],
      [{ ...good, scriptUrl: 'https://stats.kal.vn/script.js"><script>alert(1)</script>' }, /scriptUrl/],
      [{ ...good, scriptUrl: "https://stats.kal.vn/script.js?x=1" }, /scriptUrl/],
      [{ ...good, scriptUrl: "not a url" }, /scriptUrl/],
      [{ ...good, websiteId: "not-a-uuid" }, /websiteId/],
      [{ ...good, websiteId: '42572ae2-f406-4ed3-ba33-8324a046d7c9" onload="x' }, /websiteId/],
      [{ websiteId: good.websiteId }, /together/],
      [{ ...good, scriptUrl: "" }, /together/],
      [{ ...good, posthogKey: "phc_x" }, /posthogKey/],
      ["on", /analytics must be an object/],
      [[], /analytics must be an object/],
    ]) {
      await writeFile(configPath, JSON.stringify({ ...shipped, analytics }));
      await assert.rejects(() => build({ outDir: join(tmp, "analytics-bad"), today: "2026-11-13", configPath }), message, JSON.stringify(analytics));
    }
  });

  await check("analytics hosts come from the site: lines of scripts/url-hosts.allow (QA-R60, ADR 0602)", async () => {
    assert.deepEqual(await loadAnalyticsHosts(join(ROOT_DIR, "scripts", "url-hosts.allow")), ["stats.kal.vn"]);
    const allow = join(tmp, "hosts.allow");
    await writeFile(allow, "# comment\nwww.apple.com\n*.example.org\nsite: one.example.vn  # trailing comment\nsite: TWO.example.vn\n");
    assert.deepEqual(await loadAnalyticsHosts(allow), ["one.example.vn", "two.example.vn"], "app hosts never count");
    await writeFile(allow, "site: a b\n");
    await assert.rejects(() => loadAnalyticsHosts(allow), /site:/);
    assert.throws(() => parseAnalytics(shipped.analytics, []), /allowed host/, "no site: line, no analytics");
    const parsed = parseAnalytics(shipped.analytics, ["stats.kal.vn"]);
    assert.equal(parsed.origin, "https://stats.kal.vn");
    assert.ok(Object.isFrozen(parsed));
    assert.deepEqual(analyticsCspAdditions(parsed), { "script-src": ["https://stats.kal.vn"], "connect-src": ["https://stats.kal.vn"] });
    assert.deepEqual(analyticsCspAdditions(parseAnalytics(undefined, [])), {});
    assert.equal(analyticsScriptTag(parseAnalytics(null, []), "example.vn"), "");
    assert.throws(() => analyticsScriptTag(parsed, 'x" onload="y'), /domain/);
  });

  await check("every /assets/ reference carries the content hash of its file (immutable /assets/* caching)", async () => {
    const rules = parseHeaders(await readFile(join(SITE_DIR, "static", "_headers"), "utf8"));
    assert.ok(headersForPath(rules, "/assets/x.js").some(([name, value]) => name === "Cache-Control" && /immutable/.test(value)),
      "this check exists because /assets/* is cached for a year");
    await assertFingerprinted(populated);
  });

  await check("noindex preview: X-Robots-Tag on every response only when asked (Pa, 2026-11-13)", async () => {
    const out = join(tmp, "noindex");
    await build({ outDir: out, today: "2026-11-13", noindex: true });
    const rules = parseHeaders(await readFile(join(out, "_headers"), "utf8"));
    for (const path of ["/", "/appcast.xml", "/assets/style.css", "/release-notes/1.0.0/"]) {
      assert.deepEqual(headersForPath(rules, path).filter(([name]) => name === "X-Robots-Tag"), [["X-Robots-Tag", "noindex"]], path);
    }
  });

  await check("strict mode refuses to ship VERIFY markers and placeholder config", async () => {
    await assert.rejects(() => build({ outDir: join(tmp, "strict"), today: "2026-12-10", strict: true }), /--strict/);
  });

  await check("brand name is never hard-coded in site sources (CLAUDE.md)", async () => {
    const brand = await loadBrand(join(ROOT_DIR, "scripts", "brand.env"));
    // Release records written by scripts/publish-release name the product on purpose; they are data, not
    // sources, and a rename is refused once they exist (PLT-R750).
    const published = [join(SITE_DIR, "data") + "/", join(SITE_DIR, "static", "appcast.xml"), join(SITE_DIR, "static", "release-notes") + "/"];
    const files = (await walk(SITE_DIR)).filter((f) => !f.includes(`${SITE_DIR}/dist`) && /\.(mjs|js|css|json|xml|svg|md|txt)$/.test(f) && !f.endsWith("_headers") && !published.some((p) => f.startsWith(p)));
    const offenders = [];
    for (const file of files) {
      const text = await readFile(file, "utf8");
      if (text.includes(brand.name) || text.includes(brand.host) || text.includes(brand.bundleId)) offenders.push(file.slice(SITE_DIR.length + 1));
    }
    assert.deepEqual(offenders, []);
  });

  await check("tone placement: the check flags modern placement only; site sources and the matrix pass (Q13)", async () => {
    assert.deepEqual(modernToneWords("hoá Xoá khoẻ tuỳ thuỷ huỷ hòa xóa tùy hoàn xoắn khuyết ngoài khuỷu quý quỳ"), ["hoá", "Xoá", "khoẻ", "tuỳ", "thuỷ", "huỷ"]);
    assert.deepEqual(siteToneOffenders("<em>hoà</em> <em>xoá</em> hoà"), ["xoá", "hoà"], "only the setting's examples, only in <em>");
    // site/demo/ is engine input and output (site-demo-frames): the modern placement there is the setting's example.
    const files = (await walk(SITE_DIR)).filter((f) => !f.includes(`${SITE_DIR}/dist`) && !f.startsWith(`${SITE_DIR}/demo/`) && /\.(mjs|json|md|txt|html|xml)$/.test(f) && !/\/(test|lib\/tone)\.mjs$/.test(f) && !f.startsWith(`${SITE_DIR}/tests/`));
    const offenders = await toneOffendersInFiles([...files, join(ROOT_DIR, "compat", "matrix.json")], (f) => f.slice(ROOT_DIR.length + 1));
    assert.deepEqual(offenders, []);
  });
}
