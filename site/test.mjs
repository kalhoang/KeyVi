#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
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
import { loadBrand } from "./lib/brand.mjs";
import { CATEGORIES, STATUSES } from "./lib/data.mjs";
import { changelogHeadingId } from "./lib/pages/simple.mjs";
import { LANGS, ROUTES, outputFile } from "./lib/routes.mjs";

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

async function checkSite(label, dist) {
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
    for (const [file, html] of pages) {
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
      const ok = rel(file).includes("changelog") || rel(file).includes("nhat-ky") || links.length === 1; // footer link, plus the release-notes line
      assert.ok(ok, `${rel(file)}: unexpected donation links`);
      assert.ok(!/<[^>]+class="[^"]*popup|modal|banner/.test(html), `${rel(file)}: popup-like element`);
    }
  });

  return pages;
}

const tmp = await mkdtemp(join(tmpdir(), "site-test-"));
try {
  // 1. Fallback data (no releases.json, sample matrix fixture).
  const fallback = join(tmp, "fallback");
  const real = existsSync(join(SITE_DIR, "data", "releases.json"));
  const fallbackPages = await (async () => {
    await build({ outDir: fallback, today: "2026-11-13", dataDir: real ? join(SITE_DIR, "fixtures", "empty") : undefined });
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
  await build({ outDir: populated, today: "2026-12-10", dataDir: join(SITE_DIR, "fixtures", "populated") });
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

  await check("populated: matrix statuses, 120-day staleness (QA-R19), escaping, filters hook", () => {
    const m = read("tuong-thich", "index.html");
    for (const label of ["Hoạt động tốt", "Hoạt động, có lưu ý", "Chưa kiểm tra", "Hạn chế đã biết"]) assert.ok(m.includes(label), label);
    assert.match(m, /iTerm2[\s\S]*?status-notVerified[\s\S]*?quá 120 ngày/);
    assert.ok(!m.includes("<script>alert"), "matrix notes are escaped");
    assert.match(m, /data-matrix-filters/);
    assert.match(m, /<script src="\/assets\/matrix\.js" defer><\/script>/);
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
      assert.match(d, /<img src="\/assets\/qr\/vietqr\.png" width="240" height="240" alt="[^"]+">/, `${lang}: bundled VietQR image`);
      assert.ok(d.includes(`<dt>${bankLabel}</dt><dd>LioBank</dd>`), `${lang}: bank name`);
      assert.ok(d.includes(`<dt>${accountLabel}</dt><dd>688688678</dd>`), `${lang}: account number`);
      assert.ok(!/momo/i.test(d), `${lang}: no MoMo (S8)`);
      assert.ok(!/Tên tài khoản|Chủ tài khoản|Account name|account holder/i.test(d), `${lang}: the holder's name is never shown (S8)`);
      assert.ok(!d.includes('class="verify"'), `${lang}: real details, nothing left to verify`);
      assert.ok(!d.includes("donate-sponsors"), `${lang}: no sponsor card while sponsorsUrl is a placeholder`);
    }
    assert.ok(existsSync(join(populated, "assets", "qr", "vietqr.png")), "QR image shipped");
    assert.ok(!existsSync(join(populated, "assets", "qr", "momo.svg")), "MoMo image removed");
    // A real sponsor page in site/config.json brings the GitHub Sponsors card back (PRD-R57).
    const configPath = join(tmp, "sponsors-config.json");
    const base = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
    await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: "https://github.com/sponsors/example" }));
    const out = join(tmp, "sponsors");
    await build({ outDir: out, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath });
    const sponsored = await readFile(join(out, "ung-ho", "index.html"), "utf8");
    assert.match(sponsored, /id="donate-sponsors"[\s\S]*href="https:\/\/github\.com\/sponsors\/example"/);
  });

  await check("populated: favicon, touch icon and header logo come from the app icon (CLR-R7)", async () => {
    for (const file of ["favicon.svg", "favicon.ico", "apple-touch-icon.png", "assets/brand/app-icon-64.png", "assets/brand/app-icon-128.png"]) {
      assert.ok(existsSync(join(populated, file)), `${file} shipped`);
    }
    const favicon = await readFile(join(populated, "favicon.svg"), "utf8");
    assert.match(favicon, /Source: derived from Pa's own artwork/);
    assert.match(read("index.html"), /<link rel="icon" href="\/favicon\.svg" type="image\/svg\+xml">/);
    const css = await readFile(join(populated, "assets", "style.css"), "utf8");
    assert.match(css, /\.brand::before\s*\{[^}]*url\("\/assets\/brand\/app-icon-64\.png"\)/, "header logo");
    for (const [, src] of css.matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(populated, src)), `${src} exists`);
  });

  await check("populated: privacy page covers storage, network, diagnostics, analytics none", () => {
    const p = read("rieng-tu", "index.html");
    for (const id of ["luu-tren-may", "gui-di", "chan-doan", "ban-ghi", "trang-web", "xoa-du-lieu"]) assert.ok(p.includes(`id="${id}"`), id);
    assert.match(p, /Phân tích truy cập: không có/);
    assert.match(read("en", "privacy", "index.html"), /Visitor analytics: none/);
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
    const policy = headers.split("\n").find((line) => line.trim().startsWith("Content-Security-Policy:")) ?? "";
    assert.ok(policy.includes(`'sha256-${sha256Base64(css)}'`), `add 'sha256-${sha256Base64(css)}' to style-src in static/_headers`);
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

  await check("every source file carries an SPDX header", async () => {
    const files = (await walk(SITE_DIR)).filter((f) => /\.(mjs|js|css)$/.test(f) && !f.includes(`${SITE_DIR}/dist`));
    const missing = [];
    for (const file of files) if (!(await readFile(file, "utf8")).slice(0, 400).includes("SPDX-License-Identifier: LicenseRef-App-Pending")) missing.push(file.slice(SITE_DIR.length + 1));
    assert.deepEqual(missing, []);
  });
} finally {
  await rm(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failures} failed`);
process.exitCode = failures === 0 ? 0 : 1;
