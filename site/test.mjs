#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Tiny test script: `node site/test.mjs`. Builds into temp dirs (fallback data and populated fixtures) and checks
// pages, internal links and anchors, language attributes, privacy rules (PRD-R74), appcast and sitemap XML.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { pathToFileURL } from "node:url";
import { build } from "./build.mjs";
import { analyticsCspAdditions, analyticsScriptTag, loadAnalyticsHosts, parseAnalytics } from "./lib/analytics.mjs";
import { loadBrand } from "./lib/brand.mjs";
import { CATEGORIES, STATUSES } from "./lib/data.mjs";
import { loadDemos, wordsOf } from "./lib/demos.mjs";
import { adaptHeaders, extendCsp, headersForPath, parseHeaders, serializeHeaders } from "./lib/headers.mjs";
import { HUB_NODES, HUB_VIEWBOX } from "./lib/pages/home/apps.mjs";
import { changelogHeadingId } from "./lib/pages/simple.mjs";
import { LANGS, ROUTES, outputFile, routePath } from "./lib/routes.mjs";
import { modernToneWords, siteToneOffenders, toneOffendersInFiles } from "./lib/tone.mjs";
import { esc, shortHash } from "./lib/util.mjs";

const SITE_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = resolve(SITE_DIR, "..");
let failures = 0;
let passed = 0;

async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`ok   ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}\n     ${error.message.split("\n").join("\n     ")}`);
  }
}

async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path)));
    else out.push(path);
  }
  return out;
}

/** Minimal well-formedness check: one root, balanced tags, quoted attributes, valid entities. */
export function assertWellFormedXml(text, label) {
  let source = text.replace(/^﻿/, "");
  assert.match(source, /^<\?xml [^>]*\?>/, `${label}: missing XML declaration`);
  source = source.replace(/<\?xml [^>]*\?>/, "").replace(/<!--[\s\S]*?-->/g, "").replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, "");
  assert.ok(!source.includes("--"), `${label}: stray double hyphen`);
  const stack = [];
  let roots = 0;
  const tag = /<(\/?)([A-Za-z_][\w:.-]*)((?:\s+[\w:.-]+\s*=\s*(?:"[^"<]*"|'[^'<]*'))*)\s*(\/?)>/g;
  let cursor = 0;
  for (const match of source.matchAll(tag)) {
    const between = source.slice(cursor, match.index);
    assert.ok(!/[<>]/.test(between), `${label}: unexpected markup near "${between.slice(0, 30)}"`);
    assert.ok(!/&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/.test(between), `${label}: bad entity`);
    if (stack.length === 0 && between.trim() !== "") assert.fail(`${label}: text outside root`);
    cursor = match.index + match[0].length;
    const [, closing, name, , selfClosing] = match;
    if (closing) {
      assert.equal(stack.pop(), name, `${label}: mismatched </${name}>`);
    } else {
      if (stack.length === 0) roots += 1;
      if (!selfClosing) stack.push(name);
    }
  }
  assert.equal(stack.length, 0, `${label}: unclosed <${stack.at(-1)}>`);
  assert.equal(roots, 1, `${label}: expected exactly one root element, found ${roots}`);
  assert.ok(!/[<>]/.test(source.slice(cursor)), `${label}: trailing markup`);
}

const attrs = (html, name) => [...html.matchAll(new RegExp(`\\s${name}="([^"]*)"`, "g"))].map((m) => m[1]);
// Pages written by scripts/publish-release (ADR 0304): one bilingual page per release, opened by Sparkle.
const isReleaseNotesPage = (relPath) => relPath.startsWith("release-notes/");

function resolveInternal(dist, fromFile, href) {
  const [rawPath, fragment = ""] = href.split("#");
  const path = rawPath.split("?")[0];
  if (path === "") return { file: join(dist, fromFile), fragment };
  const absolute = path.startsWith("/") ? path : `/${dirname(fromFile)}/${path}`;
  let file = join(dist, absolute.replace(/\/+/g, "/"));
  if (absolute.endsWith("/")) file = join(file, "index.html");
  return { file, fragment };
}

/** Help pages the app opens: every site path with an anchor in the String Catalogs (for example the PRD-R16
 * hotkey conflict guide) and the SupportLinks topics of InputHost (ShellActions.swift). */
async function appHelpTargets() {
  const targets = [];
  const catalogDir = join(ROOT_DIR, "App", "Resources", "Localization");
  for (const name of (await readdir(catalogDir)).filter((n) => n.endsWith(".xcstrings"))) {
    const catalog = JSON.parse(await readFile(join(catalogDir, name), "utf8"));
    for (const [key, entry] of Object.entries(catalog.strings ?? {})) {
      for (const [lang, localization] of Object.entries(entry.localizations ?? {})) {
        const value = localization.stringUnit?.value ?? "";
        const match = value.match(/^(\/(?:[a-z0-9-]+\/)*)#([a-z0-9-]+)$/);
        if (match) targets.push({ path: match[1], fragment: match[2], source: `${name} ${key} (${lang})` });
      }
    }
  }
  const swift = await readFile(join(ROOT_DIR, "Packages", "AppCore", "Sources", "InputHost", "Integration", "ShellActions.swift"), "utf8");
  const paths = swift.match(/language == \.vietnamese \? "([^"]+)" : "([^"]+)"/);
  assert.ok(paths, "SupportLinks support paths");
  for (const [, topic, language, anchor] of swift.matchAll(/case \(\.(\w+), \.(vietnamese|english)\): anchor = "([^"]+)"/g)) {
    targets.push({ path: `/${language === "vietnamese" ? paths[1] : paths[2]}`, fragment: anchor, source: `SupportLinks.${topic} (${language})` });
  }
  return targets;
}

const sha256Base64 = (text) => createHash("sha256").update(text, "utf8").digest("base64");

/** WCAG 2.2 contrast ratio of two #rrggbb colours (relative luminance of sRGB). */
function contrast(first, second) {
  const luminance = (hex) => {
    const [r, g, b] = [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const [high, low] = [luminance(first), luminance(second)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

/** Origins other than the site itself that a page or header can make the browser contact: resource attributes
 * (script src, stylesheet, preload, icon, img, media) and every CSP source with a scheme and host. */
function thirdPartyOrigins(html) {
  const origins = new Set();
  const add = (url) => { const m = url.match(/^(https?:)?\/\/[^/"'\s]+/i); if (m) origins.add(m[0].startsWith("//") ? `https:${m[0]}` : m[0]); };
  for (const tag of html.match(/<(?:script|img|source|video|audio|iframe|embed)\b[^>]*>/gi) ?? []) for (const src of attrs(tag, "src")) add(src);
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) if (!/rel="(?:alternate|canonical)"/.test(tag)) for (const href of attrs(tag, "href")) add(href);
  for (const policy of attrs(html, "content").filter((value) => /default-src/.test(value))) for (const source of policy.split(/[\s;]+/)) add(source);
  return origins;
}

const cspOf = (rules, path) => headersForPath(rules, path).filter(([name]) => name === "Content-Security-Policy").map(([, value]) => value);

/** `allowedScriptTag`: the one external script a build may carry (the analytics tag of site/config.json, Q7). */
async function checkSite(label, dist, { allowedScriptTag = "" } = {}) {
  const htmlFiles = (await walk(dist)).filter((f) => f.endsWith(".html"));
  const pages = new Map(await Promise.all(htmlFiles.map(async (f) => [f, await readFile(f, "utf8")])));
  const rel = (f) => f.slice(dist.length + 1);

  await check(`${label}: every page exists (vi, en, 404, sitemap, robots, appcast)`, () => {
    const expected = ROUTES.flatMap((r) => LANGS.map((l) => outputFile(r[l]))).concat(["404.html", "sitemap.xml", "robots.txt", "appcast.xml", "favicon.svg", "assets/style.css"]);
    const missing = expected.filter((f) => !existsSync(join(dist, f)));
    assert.deepEqual(missing, []);
    for (const required of ["tai-ve", "tuong-thich", "nhat-ky-thay-doi", "rieng-tu", "ho-tro", "ung-ho"]) assert.ok(existsSync(join(dist, required, "index.html")), required);
    for (const app of ["xkey", "openkey", "evkey", "go-nhanh", "phtv", "macos-co-san"]) assert.ok(existsSync(join(dist, "ho-tro", "chuyen-tu", app, "index.html")), app);
  });

  await check(`${label}: html lang attributes (vi at /, en under /en/)`, () => {
    for (const [file, html] of pages) {
      const expected = rel(file).startsWith("en/") ? "en" : "vi";
      assert.match(html, new RegExp(`<html lang="${expected}">`), rel(file));
      assert.match(html, /<meta charset="utf-8">/, rel(file));
      assert.equal((html.match(/<h1[ >]/g) ?? []).length, 1, `${rel(file)}: exactly one h1`);
    }
  });

  await check(`${label}: internal links, assets and anchors resolve`, async () => {
    const problems = [];
    for (const [file, html] of pages) {
      const refs = [...attrs(html, "href"), ...attrs(html, "src")];
      for (const ref of refs) {
        if (/^(https?:|mailto:|tel:)/i.test(ref)) continue;
        const { file: target, fragment } = resolveInternal(dist, rel(file), ref);
        if (!existsSync(target) || !(await stat(target)).isFile()) { problems.push(`${rel(file)} -> ${ref}`); continue; }
        if (fragment && extname(target) === ".html") {
          const targetHtml = pages.get(target) ?? (await readFile(target, "utf8"));
          if (!targetHtml.includes(`id="${fragment}"`)) problems.push(`${rel(file)} -> ${ref} (no such anchor)`);
        }
      }
      for (const id of [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])) {
        if ((html.match(new RegExp(`\\sid="${id}"`, "g")) ?? []).length > 1) problems.push(`${rel(file)}: duplicate id ${id}`);
      }
    }
    assert.deepEqual(problems, []);
  });

  await check(`${label}: no external scripts, styles, fonts, frames or trackers (PRD-R74)`, async () => {
    const problems = [];
    for (const [file, raw] of pages) {
      const html = allowedScriptTag ? raw.replace(allowedScriptTag, "") : raw;
      if (/<script[^>]+src="(?:https?:)?\/\//i.test(html)) problems.push(`${rel(file)}: external script`);
      if (/<link[^>]+rel="(?:stylesheet|preload|preconnect|prefetch|dns-prefetch)"[^>]+href="(?:https?:)?\/\//i.test(html)) problems.push(`${rel(file)}: external link resource`);
      if (/<(?:iframe|embed|object)\b/i.test(html)) problems.push(`${rel(file)}: embedded content`);
      if (/<img[^>]+src="(?:https?:)?\/\//i.test(html)) problems.push(`${rel(file)}: external image`);
      if (/<script(?![^>]*\bsrc=)[^>]*>/i.test(html)) problems.push(`${rel(file)}: inline script`);
      if (isReleaseNotesPage(rel(file))) {
        // PLT-R906: the page shown in the update window inlines its stylesheet, allowed by hash only.
        for (const [, css] of html.matchAll(/<style>([\s\S]*?)<\/style>/g)) {
          if (!html.includes(`style-src 'sha256-${sha256Base64(css)}'`)) problems.push(`${rel(file)}: inline style not allowed by its CSP hash`);
        }
        if (/<link\b/i.test(html)) problems.push(`${rel(file)}: release-notes page loads a resource`);
      } else if (/<style[\s>]/i.test(html)) problems.push(`${rel(file)}: inline style element`);
      for (const img of html.match(/<img\b[^>]*>/g) ?? []) if (!/\salt="[^"]+"/.test(img)) problems.push(`${rel(file)}: img without alt`);
      if (!/Content-Security-Policy/.test(html)) problems.push(`${rel(file)}: no CSP meta`);
    }
    for (const file of (await walk(dist)).filter((f) => /\.(css|js|svg)$/.test(f))) {
      const text = await readFile(file, "utf8");
      if (/@import|url\(\s*["']?(?:https?:)?\/\//i.test(text)) problems.push(`${rel(file)}: external css reference`);
      if (/\b(?:fetch|XMLHttpRequest|sendBeacon|document\.cookie|localStorage)\b/.test(text)) problems.push(`${rel(file)}: network or storage API`);
    }
    assert.deepEqual(problems, []);
  });

  await check(`${label}: appcast and sitemap are well-formed XML, sitemap URLs exist`, async () => {
    const appcast = await readFile(join(dist, "appcast.xml"), "utf8");
    assertWellFormedXml(appcast, "appcast.xml");
    assert.match(appcast, /<rss[^>]+version="2\.0"/);
    assert.match(appcast, /xmlns:sparkle="http:\/\/www\.andymatuschak\.org\/xml-namespaces\/sparkle"/);
    assert.ok(!appcast.includes("{{"), "appcast tokens filled");
    const sitemap = await readFile(join(dist, "sitemap.xml"), "utf8");
    assertWellFormedXml(sitemap, "sitemap.xml");
    const locs = [...sitemap.matchAll(/<loc>https:\/\/[^/]+(\/[^<]*)<\/loc>/g)].map((m) => m[1]);
    assert.equal(locs.length, ROUTES.length * LANGS.length);
    for (const path of locs) assert.ok(existsSync(join(dist, path, "index.html")), `sitemap: ${path}`);
    assert.match(await readFile(join(dist, "robots.txt"), "utf8"), /Sitemap: https:\/\/[^/]+\/sitemap\.xml/);
  });

  await check(`${label}: prose rules (no dashes, no unfilled tokens, no forbidden donation services)`, () => {
    for (const [file, html] of pages) {
      assert.ok(!/[\u2013\u2014]/.test(html), `${rel(file)}: em or en dash`);
      assert.ok(!html.includes("{{"), `${rel(file)}: unfilled token`);
      assert.ok(!/polar\.sh|buymeacoffee|buy me a coffee/i.test(html), `${rel(file)}: forbidden donation service (PRD-R60)`);
    }
  });

  await check(`${label}: traditional tone placement on every page, examples of the setting aside (decision 0005 Q13)`, () => {
    for (const [file, html] of pages) assert.deepEqual(siteToneOffenders(html), [], `${rel(file)}: modern tone placement`);
  });

  await check(`${label}: donation entry points only where PRD-R57 allows`, () => {
    const allowed = new Set(["ung-ho/index.html", "en/donate/index.html"]);
    for (const [file, html] of pages) {
      if (allowed.has(rel(file))) continue;
      const links = attrs(html, "href").filter((h) => /^(\/ung-ho\/|\/en\/donate\/|https:\/\/[^/]+\/(ung-ho|en\/donate)\/)/.test(h));
      if (isReleaseNotesPage(rel(file))) {
        // Shown in the in-app update window, where PRD-R57 forbids the donation line.
        assert.equal(links.length, 0, `${rel(file)}: donation link on a release-notes page`);
        continue;
      }
      // The footer link on every page; the changelog adds the release-notes line and the home pages the closing line
      // (design 7.3 item 7).
      const home = rel(file) === "index.html" || rel(file) === "en/index.html";
      const ok = rel(file).includes("changelog") || rel(file).includes("nhat-ky") || links.length === (home ? 2 : 1);
      assert.ok(ok, `${rel(file)}: unexpected donation links`);
      assert.ok(!/<[^>]+class="[^"]*popup|modal|banner/.test(html), `${rel(file)}: popup-like element`);
    }
  });

  return pages;
}

/**
 * Every `/assets/...` URL in the built pages names the current content of its file, either as `?v=<hash>` or in the
 * file name (`name.<hash>.js`), so a changed file always gets a new URL despite the year-long immutable caching of
 * `/assets/*` in static/_headers (browsers and Cloudflare never serve a stale copy, and no purge is needed).
 */
async function assertFingerprinted(dist) {
  let seen = 0;
  for (const file of (await walk(dist)).filter((f) => f.endsWith(".html"))) {
    const html = await readFile(file, "utf8");
    for (const [, url] of html.matchAll(/(?:src|href)="(\/assets\/[^"]*)"/g)) {
      const [path, query = ""] = url.split("?", 2);
      const hash = shortHash(await readFile(join(dist, path)));
      assert.ok(query === `v=${hash}` || path.endsWith(`.${hash}.js`), `${file}: ${url} does not carry the content hash ${hash}`);
      seen += 1;
    }
  }
  assert.ok(seen > 0, `${dist}: no /assets/ reference found`);
}

const tmp = await mkdtemp(join(tmpdir(), "site-test-"));
try {
  // The shipped site/config.json enables the Umami analytics (Q7). The fallback and populated builds use the same
  // config without `analytics`, so their privacy checks see a site with no third-party origin at all; the
  // analytics checks below build with the shipped file.
  const shipped = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
  const offConfig = join(tmp, "config-no-analytics.json");
  await writeFile(offConfig, JSON.stringify({ ...shipped, analytics: undefined }));

  // 1. Fallback data (no releases.json, sample matrix fixture).
  const fallback = join(tmp, "fallback");
  const real = existsSync(join(SITE_DIR, "data", "releases.json"));
  const fallbackPages = await (async () => {
    await build({ outDir: fallback, today: "2026-11-13", dataDir: real ? join(SITE_DIR, "fixtures", "empty") : undefined, configPath: offConfig });
    return checkSite("fallback", fallback);
  })();

  await check("fallback: shows 'no release yet' and no invented versions", () => {
    const home = fallbackPages.get(join(fallback, "index.html"));
    const homeEn = fallbackPages.get(join(fallback, "en", "index.html"));
    assert.match(home, /Chưa có bản phát hành/);
    assert.match(homeEn, /No release yet/);
    assert.ok(!/<a class="btn"/.test(home), "no download button without a release");
    const download = fallbackPages.get(join(fallback, "tai-ve", "index.html"));
    assert.match(download, /Chưa có bản phát hành/);
    assert.ok(!/\b\d+\.\d+\.\d+\b/.test(download.replace(/macOS \d+(\.\d+)*/g, "")), "no version numbers on the download page");
  });

  // 2. Populated fixtures: releases, matrix statuses, staleness, changelog.
  const populated = join(tmp, "populated");
  await build({ outDir: populated, today: "2026-12-10", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath: offConfig });
  const pop = await checkSite("populated", populated);
  const read = (...p) => pop.get(join(populated, ...p));

  await check("populated: download page lists stable, beta, archive; unsafe URLs dropped", () => {
    const home = read("index.html");
    assert.match(home, /Tải .* 1\.0\.0/);
    const dl = read("tai-ve", "index.html");
    assert.match(dl, /1\.1\.0-beta\.1/);
    assert.match(dl, /id="archive"/);
    assert.match(dl, /0\.9\.0/);
    assert.match(dl, /a{64}/);
    assert.ok(!/javascript:/i.test(dl) && !/0\.5\.0/.test(dl), "entry with unsafe URL is skipped");
    assert.match(dl, /macOS 15 Sequoia trở lên/);
  });

  await check("populated: the open-source proof point names both licences (ADR 0006)", () => {
    assert.match(read("index.html"), /MPL-2\.0\)[^<]*GPL-3\.0-or-later/);
    assert.match(read("en", "index.html"), /Mozilla Public License 2\.0[^<]*GPL-3\.0-or-later/);
  });

  await check("populated: matrix statuses, 120-day staleness (QA-R19), escaping, filters hook", () => {
    const m = read("tuong-thich", "index.html");
    for (const label of ["Hoạt động tốt", "Hoạt động, có lưu ý", "Chưa kiểm tra", "Hạn chế đã biết"]) assert.ok(m.includes(label), label);
    assert.match(m, /iTerm2[\s\S]*?status-notVerified[\s\S]*?quá 120 ngày/);
    assert.ok(!m.includes("<script>alert"), "matrix notes are escaped");
    assert.match(m, /data-matrix-filters/);
    assert.match(m, /<script src="\/assets\/matrix\.js\?v=[0-9a-f]{10}" defer><\/script>/);
    assert.ok(!/Mystery app[\s\S]{0,200}status-works/.test(m), "unknown status falls back to notVerified");
    assert.match(read("en", "compatibility", "index.html"), /Works with notes/);
  });

  await check("populated: matrix uses the field names of compat/schema/matrix.schema.json", async () => {
    const schema = JSON.parse(await readFile(join(ROOT_DIR, "compat", "schema", "matrix.schema.json"), "utf8"));
    const entry = schema.$defs.entry.properties;
    assert.deepEqual(STATUSES, entry.status.enum, "status values");
    assert.deepEqual(CATEGORIES, entry.category.enum, "category values");
    for (const field of ["displayName", "bundleId", "ruleId", "note", "tier", "lastVerified", "appVersion", "macOS", "issues"]) {
      assert.ok(entry[field], `schema field ${field}`);
    }
    const m = read("tuong-thich", "index.html");
    assert.match(m, /<tr data-status="worksWithNotes" data-rule-id="browser\.chromium\.addressBar">\s*<th scope="row">Chrome/);
    assert.match(m, /Chrome[\s\S]*?<td>26\.1<\/td>/, "macOS column reads macOS");
    assert.match(m, /status-knownLimitation[\s\S]*?<a href="https:\/\/github\.com\/[^"]+\/issues\/3" rel="noopener">#3<\/a>, <a href="[^"]+\/issues\/7"/);
    assert.match(m, /data-category-group="other"[\s\S]*?Mystery app/, "unknown category falls back to other");
    for (const lang of ["vi", "en"]) {
      const ui = (await import(pathToFileURL(join(SITE_DIR, "content", lang, "ui.mjs")).href)).default;
      assert.deepEqual(Object.keys(ui.status), STATUSES, `${lang} status labels`);
      assert.deepEqual(Object.keys(ui.categories).sort(), [...CATEGORIES].sort(), `${lang} category labels`);
    }
  });

  await check("populated: changelog rendered from CHANGELOG.md, release headings have id v<version>", () => {
    const c = read("nhat-ky-thay-doi", "index.html");
    // ADR 0504: release-notes pages link /nhat-ky-thay-doi/#v<version> and /en/changelog/#v<version>.
    assert.match(c, /<h2 id="v1\.0\.0">\[1\.0\.0\] - 2026-12-01<\/h2>/);
    assert.match(c, /<h2 id="v0\.9\.0">/);
    assert.match(read("en", "changelog", "index.html"), /<h2 id="v1\.0\.0">/);
    assert.match(c, /<strong>iTerm2<\/strong>/);
    assert.match(c, /href="\/ung-ho\/"/);
  });

  await check("populated: donate block per PRD-R59 and S8 (bank VietQR only, bank and account number, no holder name)", async () => {
    for (const [lang, path, bankLabel, accountLabel] of [["vi", ["ung-ho", "index.html"], "Ngân hàng", "Số tài khoản"], ["en", ["en", "donate", "index.html"], "Bank", "Account number"]]) {
      const d = read(...path);
      if (lang === "vi") assert.match(d, /miễn phí và sẽ luôn miễn phí\. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp\./);
      assert.match(d, /<img src="\/assets\/qr\/vietqr\.png(?:\?v=[0-9a-f]+)?" width="240" height="240" alt="[^"]+">/, `${lang}: bundled VietQR image`);
      assert.ok(d.includes(`<dt>${bankLabel}</dt><dd>LioBank</dd>`), `${lang}: bank name`);
      assert.ok(d.includes(`<dt>${accountLabel}</dt><dd>688688678</dd>`), `${lang}: account number`);
      assert.ok(!/momo/i.test(d), `${lang}: no MoMo (S8)`);
      assert.ok(!/Tên tài khoản|Chủ tài khoản|Account name|account holder/i.test(d), `${lang}: the holder's name is never shown (S8)`);
      assert.ok(!d.includes('class="verify"'), `${lang}: real details, nothing left to verify`);
      assert.ok(!d.includes("donate-sponsors"), `${lang}: no sponsor card while there is no sponsor page`);
    }
    assert.ok(existsSync(join(populated, "assets", "qr", "vietqr.png")), "QR image shipped");
    assert.ok(!existsSync(join(populated, "assets", "qr", "momo.svg")), "MoMo image removed");
    // An empty sponsorsUrl means no sponsor page: no card, no placeholder, nothing for --strict to refuse (PRD-R59).
    assert.equal(shipped.sponsorsUrl, "", "no GitHub Sponsors page exists yet");
    const emptyConfig = join(tmp, "sponsors-empty.json");
    await writeFile(emptyConfig, JSON.stringify({ ...shipped, sponsorsUrl: "" }));
    const emptyOut = join(tmp, "sponsors-empty");
    const summary = await build({ outDir: emptyOut, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath: emptyConfig });
    assert.ok(!summary.placeholders.includes("sponsorsUrl"), "an empty sponsorsUrl is not a placeholder");
    for (const page of ["ung-ho/index.html", "en/donate/index.html"]) {
      const html = await readFile(join(emptyOut, page), "utf8");
      assert.ok(!html.includes("donate-sponsors") && !/github\.com\/sponsors/.test(html), `${page}: no sponsor card`);
    }
    // A real sponsor page in site/config.json brings the GitHub Sponsors card back (PRD-R57).
    const configPath = join(tmp, "sponsors-config.json");
    const base = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
    await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: "https://github.com/sponsors/example" }));
    const out = join(tmp, "sponsors");
    await build({ outDir: out, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath });
    const sponsored = await readFile(join(out, "ung-ho", "index.html"), "utf8");
    assert.match(sponsored, /id="donate-sponsors"[\s\S]*href="https:\/\/github\.com\/sponsors\/example"/);
    for (const bad of ["javascript:alert(1)", "http://github.com/sponsors/x", 42]) {
      await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: bad }));
      await assert.rejects(() => build({ outDir: join(tmp, "sponsors-bad"), today: "2026-11-13", configPath }), /sponsorsUrl/, String(bad));
    }
    await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: "https://github.com/sponsors/OWNER" }));
    assert.ok((await build({ outDir: join(tmp, "sponsors-placeholder"), today: "2026-11-13", configPath })).placeholders.includes("sponsorsUrl"), "a placeholder is still reported for --strict");
  });

  await check("populated: favicon, touch icon and the header mark come from the app icon (CLR-R7)", async () => {
    for (const file of ["favicon.svg", "favicon.ico", "apple-touch-icon.png", "assets/brand/app-icon-64.png", "assets/brand/app-icon-128.png"]) {
      assert.ok(existsSync(join(populated, file)), `${file} shipped`);
    }
    const favicon = await readFile(join(populated, "favicon.svg"), "utf8");
    assert.match(favicon, /Source: derived from Pa's own artwork/);
    assert.match(read("index.html"), /<link rel="icon" href="\/favicon\.svg" type="image\/svg\+xml">/);
    // The header mark is the KV of favicon.svg as an inline symbol (design 7.1); the shell check compares the shapes.
    assert.match(read("index.html"), /<a class="brand" href="\/"><svg class="mark"[^>]*><use href="#mark"><\/use><\/svg>/, "header mark");
    for (const sheet of ["style.css", "home.css"]) {
      const css = await readFile(join(populated, "assets", sheet), "utf8");
      for (const [, src] of css.matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(populated, src)), `${sheet}: ${src} exists`);
    }
  });

  await check("populated: privacy page covers storage, network, diagnostics, analytics none", () => {
    const p = read("rieng-tu", "index.html");
    for (const id of ["luu-tren-may", "gui-di", "chan-doan", "ban-ghi", "trang-web", "xoa-du-lieu"]) assert.ok(p.includes(`id="${id}"`), id);
    assert.match(p, /Phân tích truy cập: không có/);
    assert.match(read("en", "privacy", "index.html"), /Visitor analytics: none/);
  });

  await check("populated: the iTerm2 Secure Input line is the app's one sentence of Q38 (no VERIFY left)", async () => {
    const line = (html) => html.match(/<li><strong>iTerm2<\/strong>: ([\s\S]*?)<\/li>/)[1];
    assert.equal(line(read("en", "support", "index.html")), "iTerm2 has Secure Keyboard Entry turned on. Turn off <em>iTerm2 &gt; Secure Keyboard Entry</em>, or finish or cancel the password prompt it is waiting for.");
    assert.equal(line(read("ho-tro", "index.html")), "iTerm2 đang bật Nhập bàn phím an toàn. Hãy tắt mục <em>iTerm2 &gt; Secure Keyboard Entry</em>, hoặc nhập xong (hay hủy) lời nhắc mật khẩu đang chờ.");
    // ADR 0400 item 15: the support page and the app's status line (Status.xcstrings) use the same sentence.
    const catalog = JSON.parse(await readFile(join(ROOT_DIR, "App", "Resources", "Localization", "Status.xcstrings"), "utf8"));
    const hint = catalog.strings["secureInputHint.iterm2.secureKeyboardEntry"].localizations;
    const plain = (html) => line(html).replace(/<\/?em>/g, "").replaceAll("&gt;", ">");
    assert.equal(plain(read("en", "support", "index.html")), hint.en.stringUnit.value);
    assert.equal(plain(read("ho-tro", "index.html")), hint.vi.stringUnit.value);
  });

  await check("populated: the FAQ names every app family where Escape restore is off (compat/rules.json, D8)", async () => {
    const rules = JSON.parse(await readFile(join(ROOT_DIR, "compat", "rules.json"), "utf8"));
    const off = rules.rules.filter((rule) => rule.action?.features?.restoreHotkey === false).map((rule) => rule.id).sort();
    // Every rule that turns Escape restore off, with the names the FAQ gives it: app families, never bundle IDs.
    const both = (...names) => ({ en: names, vi: names });
    const families = {
      "terminal.default": { en: ["terminals", "Terminal", "iTerm2"], vi: ["Terminal", "iTerm2"] },
      "editor.vscode.integratedTerminal": { en: ["the terminal inside code editors"], vi: ["cửa sổ dòng lệnh trong trình soạn mã"] },
      "editor.vscodeFamily": both("Visual Studio Code", "VSCodium", "Cursor"),
      "editor.jetbrains": both("JetBrains", "Android Studio"),
      "editor.nativeCodeEditors": both("Xcode", "Nova", "BBEdit"),
      "editor.customTextViews": both("Sublime Text", "Zed", "Emacs", "MacVim"),
      "remote.passThrough": { en: ["remote desktop and virtual machine apps"], vi: ["ứng dụng điều khiển máy từ xa và máy ảo"] },
      "remote.chromeRemoteDesktop.web": both("Chrome Remote Desktop"),
      "games.passThrough": { en: ["games"], vi: ["trò chơi"] },
      "launcher.spotlight": both("Spotlight"),
      "launcher.overlayPanels": both("Raycast", "Alfred"),
    };
    assert.deepEqual(off, Object.keys(families).sort(), "a rule turns Escape restore off or on again: update the FAQ entry and this map");
    const entry = (html) => {
      const found = html.split("<details>").find((chunk) => /<summary>[^]*?Escape[^]*?<\/summary>/.test(chunk));
      assert.ok(found, "no FAQ entry about Escape");
      return found.split("</details>")[0];
    };
    for (const [lang, html] of [["en", read("en", "support", "index.html")], ["vi", read("ho-tro", "index.html")]]) {
      const text = entry(html);
      for (const [id, names] of Object.entries(families)) for (const name of names[lang]) assert.ok(text.includes(name), `${lang}: ${id} needs "${name}"`);
      assert.doesNotMatch(text, /\b(?:com|org|dev|net|tv|io)\.[A-Za-z0-9-]+\.[A-Za-z]/, `${lang}: no bundle IDs`);
    }
  });

  await check("populated: support page has permission (macOS 27 naming), Secure Input, targets", () => {
    const s = read("ho-tro", "index.html");
    assert.match(s, /Điều khiển thiết bị và truy cập dữ liệu/);
    assert.match(s, /iTerm2/);
    assert.match(s, /24 giờ/);
    assert.match(read("en", "support", "index.html"), /Device Control and Data Access/);
  });

  await check("populated: every help anchor the app opens exists (PRD-R16 hotkey guide, SupportLinks topics)", async () => {
    const targets = await appHelpTargets();
    assert.ok(targets.some((t) => t.source.includes("settings.hotkey.conflict.helpPath")), "PRD-R16 help path found");
    assert.ok(targets.filter((t) => t.source.startsWith("SupportLinks")).length >= 8, "SupportLinks topics found");
    const problems = [];
    for (const target of targets) {
      const file = join(populated, target.path, "index.html");
      if (!existsSync(file)) problems.push(`${target.source}: no page ${target.path}`);
      else if (!(await readFile(file, "utf8")).includes(`id="${target.fragment}"`)) problems.push(`${target.source}: no #${target.fragment} on ${target.path}`);
    }
    assert.deepEqual(problems, []);
  });

  await check("populated: the macOS shortcut guide covers every combination the recorder warns about (PRD-R16)", () => {
    const section = (html, id) => html.split(`id="${id}"`)[1]?.split("</section>")[0] ?? "";
    const vi = section(read("ho-tro", "index.html"), "phim-tat-macos");
    const en = section(read("en", "support", "index.html"), "macos-shortcuts");
    for (const [label, html, keyboard, spotlight] of [["vi", vi, "Bàn phím", "Spotlight"], ["en", en, "Keyboard", "Spotlight"]]) {
      assert.ok(html.includes(keyboard) && html.includes(spotlight), `${label}: System Settings path`);
      for (const keys of [["Command", "Space"], ["Control", "Space"], ["Control", "Option", "Space"], ["Control", "Command", "Space"], ["Command", "Tab"], ["Command", "Q"], ["Command", "W"]]) {
        const combo = keys.map((key) => `<kbd>${key}</kbd>`).join(" + ");
        assert.ok(html.includes(combo), `${label}: ${keys.join("+")}`);
      }
    }
  });

  await check("populated: the FAQ explains the pause for non-Latin input sources (D22, PRD-R7)", () => {
    const summaries = (html) => [...html.matchAll(/<summary>([\s\S]*?)<\/summary>/g)].map((m) => m[1]).join("\n");
    assert.match(summaries(read("ho-tro", "index.html")), /tiếng Nhật, Trung hay Hàn/);
    assert.match(summaries(read("en", "support", "index.html")), /Japanese, Chinese or Korean/);
  });

  await check("populated: migration pages promise only the importers that ship (PRD-R69, contracts.md 7.3)", () => {
    // The app imports macros from TSV or CSV, the Text Replacements plist and its own export; importers for other
    // input methods' files come only after their formats are observed in real exports (CLR-R5).
    const external = ["xkey", "openkey", "evkey", "go-nhanh", "phtv"];
    const overpromise = { vi: /nhập được|có thể nhập|nhập gõ tắt và|nhập phần gõ tắt/i, en: /can import|imports (?:the )?macros|imports? (?:its|their) settings/i };
    const template = { vi: 'href="/ho-tro/chuyen-tu/tep-van-ban/"', en: 'href="/en/support/migrate-from/plain-text-file/"' };
    for (const id of external) {
      for (const [lang, html] of [["vi", read("ho-tro", "chuyen-tu", id, "index.html")], ["en", read("en", "support", "migrate-from", id, "index.html")]]) {
        const lede = html.match(/<p class="lede">([\s\S]*?)<\/p>/)[1];
        assert.ok(lede.includes(template[lang]), `${lang} ${id}: the intro points at the plain text template`);
        const text = html.split('<main id="main"')[1].replace(/<[^>]+>/g, " ");
        assert.ok(!overpromise[lang].test(text), `${lang} ${id}: promises an importer that does not exist`);
      }
    }
    const cards = (html) => html.match(/<ul class="cards">[\s\S]*?<\/ul>/)[0];
    assert.ok(!/kiểu gõ|loại trừ|theo ứng dụng/.test(cards(read("ho-tro", "index.html"))), "vi index cards");
    assert.ok(!/typing method|excluded apps|per-app/.test(cards(read("en", "support", "index.html"))), "en index cards");
  });

  await check("populated: the settings export example has the keys the app writes and reads (PRD-R72)", async () => {
    const swift = await readFile(join(ROOT_DIR, "Packages", "AppCore", "Sources", "SettingsStore", "ExportImport.swift"), "utf8");
    const header = [...swift.match(/headerKeys: Set<String> = \[([^\]]+)\]/)[1].matchAll(/"(\w+)"/g)].map((m) => m[1]);
    const sections = [...swift.match(/static let settings = "settings",[^\n]*/)[0].matchAll(/"(\w+)"/g)].map((m) => m[1]);
    const kind = swift.match(/static let kind = "([^"]+)"/)[1];
    const documents = await readFile(join(ROOT_DIR, "Packages", "AppCore", "Sources", "SettingsStore", "Documents.swift"), "utf8");
    const macroBlock = documents.split("public struct StoredMacro")[1].split("public init")[0];
    const macroKeys = [...macroBlock.matchAll(/public var (\w+):/g)].map((m) => m[1]);
    for (const page of [read("ho-tro", "chuyen-tu", "tep-van-ban", "index.html"), read("en", "support", "migrate-from", "plain-text-file", "index.html")]) {
      const code = [...page.matchAll(/<pre><code>([\s\S]*?)<\/code><\/pre>/g)].map((m) => m[1]).find((c) => c.includes('"schemaVersion"'));
      const example = JSON.parse(code);
      assert.deepEqual(Object.keys(example).sort(), [...header, ...sections].sort());
      assert.equal(example.kind, kind);
      assert.deepEqual(Object.keys(example.macros[0]).sort(), [...macroKeys].sort());
      assert.equal(typeof example.appModes, "object");
      assert.ok(!Array.isArray(example.appModes), "appModes is an object");
    }
  });

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
      const guides = new Set(ROUTES.filter((route) => route.id.startsWith("migrate-")).flatMap((route) => LANGS.map((lang) => outputFile(routePath(route.id, lang)))));
      assert.ok(pages.get(join(dist, "index.html")).match(/<title>([^<]*)<\/title>/)[1].includes(named), `${dist}: home title carries the sign`);
      for (const [file, html] of pages) {
        const page = file.slice(dist.length + 1);
        // Every page title carries the sign: the home pages open with it, the others end with the " · " suffix.
        const title = html.match(/<title>([^<]*)<\/title>/)?.[1];
        assert.ok(title !== undefined, `${page}: has a <title>`);
        const home = page === "index.html" || page === join("en", "index.html");
        assert.ok(home ? title.startsWith(named) : title.endsWith(` · ${named}`), `${page}: title "${title}" carries the sign`);
        assert.equal(html.match(/<meta property="og:title" content="([^"]*)">/)?.[1], title, `${page}: og:title matches the title`);
        // The ui.descriptions are prose ({{AppNameTM}}), so they carry the sign too. The migration guides take their
        // description from the guide intro, which moves to {{AppNameTM}} with the inner-page copy (plan Task 7).
        if (!guides.has(page)) assert.ok((html.match(/<meta name="description" content="([^"]*)">/)?.[1] ?? "").includes(named), `${page}: description carries the sign`);
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
      ["--green-text", "--green-soft"], ["--on-green", "--green"], ["--on-night", "--night"], ["--on-night-muted", "--night"], ["--green-on-dark", "--night"]];
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
    await checkSite("analytics", out, { allowedScriptTag: tag });
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
    const files = (await walk(SITE_DIR)).filter((f) => !f.includes(`${SITE_DIR}/dist`) && !f.startsWith(`${SITE_DIR}/demo/`) && /\.(mjs|json|md|txt|html|xml)$/.test(f) && !/\/(test|lib\/tone)\.mjs$/.test(f));
    const offenders = await toneOffendersInFiles([...files, join(ROOT_DIR, "compat", "matrix.json")], (f) => f.slice(ROOT_DIR.length + 1));
    assert.deepEqual(offenders, []);
  });

  // Home page (design 7.3, plan Task 5). The demo texts come from site/demo/frames.json, never from this file.
  const framesPath = join(SITE_DIR, "demo", "frames.json");
  const frames = JSON.parse(await readFile(framesPath, "utf8"));
  const homeCopy = Object.fromEntries(await Promise.all(LANGS.map(async (lang) => [lang, (await import(pathToFileURL(join(SITE_DIR, "content", lang, "pages.mjs")).href)).home])));
  const section = (html, name) => html.match(new RegExp(`<section\\b[^>]*\\sdata-section="${name}"[\\s\\S]*?</section>`))?.[0] ?? "";
  const mainOf = (html) => html.split('<main id="main"')[1]?.split("</main>")[0] ?? "";
  // Text outside tags, so outside every attribute value; entities stay escaped.
  const textOf = (html) => html.replace(/<[^>]*>/g, "");
  const unescapeHtml = (text) => text.replace(/&(amp|lt|gt|quot|#39);/g, (whole, name) => ({ amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" })[name]);
  const framesAttr = (tag) => JSON.parse(unescapeHtml(attrs(tag, "data-demo-frames")[0] ?? "null"));
  const heroTag = (html) => html.match(/<[^>]*\sdata-hero[\s>][^>]*>/)?.[0] ?? "";
  const homePages = [["fallback vi", fallbackPages.get(join(fallback, "index.html")), "vi"], ["fallback en", fallbackPages.get(join(fallback, "en", "index.html")), "en"],
    ["populated vi", read("index.html"), "vi"], ["populated en", read("en", "index.html"), "en"]];
  const emptyOut = join(tmp, "empty");
  await build({ outDir: emptyOut, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "empty"), configPath: offConfig });
  const emptyHome = { vi: await readFile(join(emptyOut, "index.html"), "utf8"), en: await readFile(join(emptyOut, "en", "index.html"), "utf8") };

  await check("home: PRD-R73 items on / and /en/", () => {
    for (const [label, html, lang] of homePages) {
      const h = homeCopy[lang];
      const main = mainOf(html);
      assert.ok(main.includes(`<h1 id="hero-title">${esc(h.h1)}</h1>`), `${label}: the value statement is the h1`);
      const hero = section(html, "hero");
      if (label.startsWith("populated")) {
        // fixtures/populated: stable 1.0.0 with minimumSystemVersion 15.0.
        assert.match(hero, new RegExp(`<a class="btn" href="https://example\\.invalid/app-1\\.0\\.0\\.dmg">[^<]*1\\.0\\.0<small>macOS 15 Sequoia (?:trở lên|or later)</small></a>`), `${label}: download button with version and minimum macOS`);
      } else {
        assert.ok(hero.includes(`<p class="btn btn-disabled" aria-disabled="true">${esc(h.noReleaseBtn)}`), `${label}: the no-release state`);
      }
      assert.match(hero, /<code class="cmd">brew install --cask [^<\s]+\/[a-z0-9-]+<\/code>/, `${label}: brew line in the hero`);
      assert.equal((section(html, "proof").match(/<li\b/g) ?? []).length, 3, `${label}: three proof points`);
      assert.ok(main.includes(`href="${routePath("compat", lang)}"`), `${label}: a link to the compatibility page in the page body`);
      assert.ok(!/<video\b/i.test(html), `${label}: no video (design 6)`);
    }
  });

  await check("home: every demo's final text is in the static HTML (design 7.2, no JavaScript)", () => {
    for (const [label, html] of homePages) {
      const heroIds = (framesAttr(heroTag(html)) ?? []).map((demo) => demo.id);
      const used = new Set([...heroIds, ...attrs(html, "data-demo")]);
      assert.deepEqual([...used].sort(), Object.keys(frames.demos).sort(), `${label}: the page uses every demo of frames.json`);
      const text = textOf(mainOf(html));
      for (const id of used) {
        const final = frames.demos[id].text.replace(/\n/g, "").trim();
        assert.ok(text.includes(esc(final)), `${label}: ${id} "${final}" is not in the page text`);
      }
    }
  });

  await check("home: data-demo-frames parses and matches frames.json", () => {
    for (const [label, html] of homePages) {
      const hero = ["hero-chat", "hero-email", "hero-note"].map((id) => ({ id, ...frames.demos[id] }));
      assert.match(heroTag(html), /^<div class="mac-window"/, `${label}: the hero window carries data-hero`);
      assert.deepEqual(framesAttr(heroTag(html)), hero, `${label}: hero frames`);
      const figures = html.match(/<figure\b[^>]*\sdata-demo="behaviour-[^"]+"[^>]*>/g) ?? [];
      assert.deepEqual(figures.map((tag) => attrs(tag, "data-demo")[0]), ["behaviour-punctuation", "behaviour-revision", "behaviour-escape"], `${label}: behaviour figures`);
      for (const tag of figures) assert.deepEqual(framesAttr(tag), frames.demos[attrs(tag, "data-demo")[0]], `${label}: ${tag.slice(0, 60)}`);
      assert.match(section(html, "behaviours"), /^<section id="(?:tinh-nang|features)"/, `${label}: the features anchor is section 2`);
    }
  });

  await check("home: tags name exactly the English words of the hero sentence", () => {
    // From frames.json: every commit adds a word; a revision replaces the word before it with its new state.
    const words = [];
    for (const frame of frames.demos["hero-chat"].frames) {
      if (frame.revised) words[words.length - 1] = frame.revised;
      if (frame.commit) words.push(frame.commit);
    }
    const english = words.filter((word) => word.english).map((word) => word.raw);
    assert.ok(english.length > 0, "the hero sentence has English words");
    for (const [label, html, lang] of homePages) {
      const tags = html.match(/\sdata-tags[^>]*>([\s\S]*?)<\/(?:p|div)>/)?.[1] ?? "";
      const shown = [...tags.matchAll(/<span class="tag">([^<]*)<\/span>/g)].map((m) => m[1]);
      assert.deepEqual(shown, english.map((word) => esc(homeCopy[lang].hero.keepTag.replace("{{word}}", word))), label);
    }
  });

  await check("home: compat hub shows categories and app names without verified wording while entries are notVerified", async () => {
    const hub = (html) => section(html, "apps");
    const nodes = (html) => [...hub(html).matchAll(/<li class="hub-node[^"]*" data-category="([^"]+)">([\s\S]*?)<\/li>/g)].map(([, category, inner]) => ({ category, inner }));
    const sample = JSON.parse(await readFile(join(SITE_DIR, "fixtures", "matrix.json"), "utf8")).entries;
    const real = JSON.parse(await readFile(join(ROOT_DIR, "compat", "matrix.json"), "utf8")).entries;
    const base = (name) => name.replace(/\s*\([^)]*\)$/, "");
    // fixtures/empty has no matrix, so its build shows the sample fixture, whose every row is notVerified.
    for (const [label, html, lang, entries] of [["empty vi", emptyHome.vi, "vi", sample], ["empty en", emptyHome.en, "en", sample], ...homePages.slice(0, 2).map(([l, h, g]) => [l, h, g, real])]) {
      const copy = homeCopy[lang].apps;
      assert.deepEqual(nodes(html).map((node) => node.category), Object.keys(copy.categories), `${label}: one node per category, in order`);
      assert.equal((hub(html).match(/<path data-thread\b/g) ?? []).length, Object.keys(copy.categories).length, `${label}: one thread per category`);
      assert.match(hub(html), /<div class="hub" data-hub>/, `${label}: the hub`);
      for (const { category, inner } of nodes(html)) {
        assert.ok(inner.includes(esc(copy.categories[category])), `${label}: ${category} label`);
        const names = (inner.match(/<span class="hub-apps">([^<]*)<\/span>/)?.[1] ?? "").split(", ").filter(Boolean).map(unescapeHtml);
        // The apps the maintainers ranked (tier 1 or 2) when the category has any, every app otherwise.
        const inCategory = entries.filter((entry) => entry.category === category);
        const ranked = inCategory.filter((entry) => entry.tier === 1 || entry.tier === 2);
        const pool = ranked.length > 0 ? ranked : inCategory;
        assert.ok(names.length <= 4 && names.length === Math.min(4, new Set(pool.map((entry) => base(entry.displayName))).size), `${label}: ${category} lists up to four apps`);
        for (const name of names) assert.ok(pool.some((entry) => base(entry.displayName) === name), `${label}: ${category} lists ${name}`);
        const tierOne = inCategory.filter((entry) => entry.tier === 1).map((entry) => base(entry.displayName));
        if (names.length > 0 && tierOne.length > 0) assert.ok(tierOne.includes(names[0]), `${label}: ${category} lists tier 1 first`);
      }
      if (entries.every((entry) => entry.status === "notVerified")) {
        const text = textOf(hub(html));
        assert.ok(!/kiểm tra|verif/i.test(text), `${label}: no verified wording while every entry is notVerified`);
        assert.ok(!/\d{1,2}\/\d{1,2}\/\d{4}|\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}|<time\b/.test(hub(html)), `${label}: no date`);
      }
      assert.ok(hub(html).includes(`href="${routePath("compat", lang)}"`), `${label}: link to the compatibility page`);
      assert.match(hub(html), /class="card secure-input"/, `${label}: the Secure Input card below the hub`);
    }
    assert.ok(nodes(homePages[0][1]).find((node) => node.category === "browser").inner.includes("Safari"), "the real matrix lists Safari first among browsers");
    // fixtures/populated: Safari verified on 2026-12-01 shows its date; iTerm2 (2026-06-01) is stale, so it shows none.
    const populatedHub = { vi: hub(read("index.html")), en: hub(read("en", "index.html")) };
    assert.match(populatedHub.vi, /Safari \(kiểm tra <time datetime="2026-12-01">01\/12\/2026<\/time>\)/);
    assert.match(populatedHub.en, /Safari \(verified <time datetime="2026-12-01">1 Dec 2026<\/time>\)/);
    assert.ok(!populatedHub.vi.includes("2026-06-01"), "a stale result shows no date");
  });

  await check("home: home.css places every hub node where its thread ends (design 7.3 item 4)", async () => {
    const css = (await readFile(join(SITE_DIR, "static", "assets", "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    assert.ok(HUB_NODES.length >= 7, "a node per category");
    HUB_NODES.forEach(({ x, y }, index) => {
      const rule = css.match(new RegExp(`\\.hub-node-${index + 1}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
      const [left, top] = ["left", "top"].map((side) => Number(rule.match(new RegExp(`${side}:\\s*([\\d.]+)%`))?.[1]));
      assert.ok(Math.abs(left - (100 * x) / HUB_VIEWBOX.width) < 0.01 && Math.abs(top - (100 * y) / HUB_VIEWBOX.height) < 0.01, `.hub-node-${index + 1} sits at ${left}%, ${top}%, its thread ends at ${x}, ${y}`);
    });
    assert.match(css, new RegExp(`\\.hub\\s*\\{[^}]*aspect-ratio:\\s*${HUB_VIEWBOX.width}\\s*/\\s*${HUB_VIEWBOX.height}`), "the hub keeps the proportions of the thread drawing");
  });

  await check("home: the no-release state appears in hero and closing with site/fixtures/empty", () => {
    for (const lang of LANGS) {
      for (const name of ["hero", "closing"]) {
        const part = section(emptyHome[lang], name);
        assert.ok(part.includes(`<p class="btn btn-disabled" aria-disabled="true">${esc(homeCopy[lang].noReleaseBtn)}`), `${lang} ${name}: the disabled state`);
        assert.ok(!/<a class="btn"/.test(part), `${lang} ${name}: no download button`);
        assert.match(section(read(...(lang === "vi" ? [] : ["en"]), "index.html"), name), /<a class="btn" href="https:\/\/example\.invalid\/app-1\.0\.0\.dmg">/, `${lang} ${name}: the download button with a release`);
      }
    }
  });

  await check("demos: loadDemos rejects a frames file whose last frame differs from text", async () => {
    const loaded = await loadDemos(framesPath);
    assert.deepEqual([...loaded.byId.keys()].sort(), Object.keys(frames.demos).sort());
    const write = async (data) => { const path = join(tmp, "frames-bad.json"); await writeFile(path, JSON.stringify(data)); return path; };
    const bad = structuredClone(frames);
    bad.demos["card-telex"].text = "viet";
    await assert.rejects(async () => loadDemos(await write(bad)), /site\/demo\/frames\.json: card-telex: the last frame/);
    await assert.rejects(async () => loadDemos(await write({ ...frames, schemaVersion: 2 })), /site\/demo\/frames\.json: .*schemaVersion/);
    const keyless = structuredClone(frames);
    delete keyless.demos["card-vni"].frames[0].key;
    await assert.rejects(async () => loadDemos(await write(keyless)), /site\/demo\/frames\.json: card-vni: /);
  });

  await check("demos: wordsOf marks the latest state of each word (a revision replaces the earlier commit)", async () => {
    const { byId } = await loadDemos(framesPath);
    const english = (demo) => wordsOf(demo).filter((piece) => piece.english).map((piece) => piece.text);
    assert.deepEqual(english(byId.get("behaviour-revision")), ["tricky", "as", "hell"], "the revision makes as English");
    assert.deepEqual(english(byId.get("card-slang")), []);
    for (const [id, demo] of byId) assert.equal(wordsOf(demo).map((piece) => piece.text).join(""), demo.text, `${id}: the pieces rebuild the text`);
    // RV4: a word restored as English that the next word gives back to Vietnamese is no longer English.
    const back = { text: "car nhà ", frames: [
      { key: " ", text: "car ", commit: { raw: "car", text: "car", english: true } },
      { key: " ", text: "cả nhà ", commit: { raw: "nhaf", text: "nhà", english: false }, revision: true, revised: { raw: "car", text: "cả", english: false } },
    ] };
    back.text = back.frames.at(-1).text;
    assert.deepEqual(english(back), []);
    assert.deepEqual(wordsOf(back).map((piece) => piece.text).join(""), "cả nhà ");
  });

  await check("content: home copy has the same keys in vi and en, uses file not tệp, and has no dash characters", async () => {
    const load = async (lang) => (await import(pathToFileURL(join(SITE_DIR, "content", lang, "pages.mjs")).href)).home;
    const [vi, en] = [await load("vi"), await load("en")];
    // The shape of the copy: object keys and array lengths, recursively, with the type of every leaf.
    const shape = (value) => (Array.isArray(value) ? value.map(shape)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, shape(value[key])])) : typeof value);
    assert.deepEqual(shape(en), shape(vi), "the en home copy has the keys of the vi copy");
    const strings = (value) => (typeof value === "string" ? [value] : value && typeof value === "object" ? Object.values(value).flatMap(strings) : []);
    assert.deepEqual(strings(vi).filter((text) => /tệp/i.test(text)), [], "vi home says file, never tệp");
    for (const [lang, home] of [["vi", vi], ["en", en]]) assert.deepEqual(strings(home).filter((text) => /[\u2013\u2014]/.test(text)), [], `${lang}: em or en dash`);
    assert.equal(vi.h1, "Gõ tiếng Việt lẫn tiếng Anh, không cần chuyển.");
    assert.equal(en.h1, "Type Vietnamese and English without switching.");
    // The section headings of design 7.3 and the ids the renderers and frames.json share (plan Task 4).
    assert.deepEqual([vi.behaviours.heading, vi.cards.heading, vi.apps.heading, vi.proofHeading, vi.install.heading],
      ["Một câu, hai thứ tiếng", "Gõ theo cách của bạn", "Chạy trong app bạn dùng hằng ngày", "Ba điều bạn có thể kiểm chứng", "Cài trong một phút"]);
    assert.deepEqual(vi.behaviours.items.map((item) => item.id), ["punctuation", "revision", "escape"]);
    assert.deepEqual(vi.cards.items.map((item) => item.id), ["anywhere", "slang", "method", "macros", "layouts", "perApp"]);
    assert.deepEqual(Object.keys(vi.apps.categories), ["browser", "chat", "office", "notes", "launcher", "terminal", "developer"]);
    assert.deepEqual(vi.cards.items.flatMap((item) => item.demos ?? []), ["card-anywhere", "card-slang", "card-telex", "card-vni", "card-traditional", "card-modern"]);
    assert.ok(vi.hero.keepTag.includes("{{word}}") && en.hero.keepTag.includes("{{word}}"), "keepTag names the word");
    assert.equal(vi.install.steps.length, 3);
    // Step 2 names the permission as the download page does, with its VERIFY marker (design 7.3 item 6).
    const download = (await import(pathToFileURL(join(SITE_DIR, "content", "vi", "pages.mjs")).href)).download;
    for (const name of [...download.reqPermission.matchAll(/<strong>([^<]+)<\/strong>/g)].map((m) => m[1]).concat("{{verifyHtml}}")) assert.ok(vi.install.steps[1].includes(name), `install step 2: ${name}`);
    for (const retired of ["demoPlaceholder", "demoCaption", "demoAlt", "typed", "why"]) assert.ok(!(retired in vi) && !(retired in en), `${retired} is retired`);
  });

  await check("vendor: anime.js 4.5.0 is vendored byte-exact with its licence (ADR 0603)", async () => {
    const vendor = join(SITE_DIR, "static", "assets", "vendor");
    const bundle = await readFile(join(vendor, "anime.umd.min.js"));
    assert.ok(bundle.toString("utf8").startsWith("/**\n * Anime.js - UMD minified bundle\n * @version v4.5.0"), "the UMD bundle of anime.js 4.5.0");
    const notices = await readFile(join(ROOT_DIR, "THIRD_PARTY_NOTICES.md"), "utf8");
    const entry = notices.split("\n### anime.js 4.5.0\n")[1]?.split(/\n##/)[0] ?? "";
    const recorded = entry.match(/SHA-256[^\n]*`([0-9a-f]{64})`/)?.[1];
    assert.ok(recorded, "THIRD_PARTY_NOTICES.md section 5 records the SHA-256 of the vendored file in its anime.js entry");
    assert.equal(createHash("sha256").update(bundle).digest("hex"), recorded, "the vendored file is the one the notice names");
    assert.match(await readFile(join(vendor, "anime.LICENSE.txt"), "utf8"), /Julian Garnier/);
  });

  await check("every source file carries an SPDX header", async () => {
    // Third-party files vendored byte-exact keep their own header; THIRD_PARTY_NOTICES.md records them (ADR 0603).
    const vendor = join(SITE_DIR, "static", "assets", "vendor") + "/";
    const files = (await walk(SITE_DIR)).filter((f) => /\.(mjs|js|css)$/.test(f) && !f.includes(`${SITE_DIR}/dist`) && !f.startsWith(vendor));
    const missing = [];
    for (const file of files) if (!(await readFile(file, "utf8")).slice(0, 400).includes("SPDX-License-Identifier: GPL-3.0-or-later")) missing.push(file.slice(SITE_DIR.length + 1));
    assert.deepEqual(missing, []);
  });
} finally {
  await rm(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failures} failed`);
process.exitCode = failures === 0 ? 0 : 1;
