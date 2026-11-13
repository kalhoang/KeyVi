#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
// Tiny test script: `node site/test.mjs`. Builds into temp dirs (fallback data and populated fixtures) and checks
// pages, internal links and anchors, language attributes, privacy rules (PRD-R74), appcast and sitemap XML.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "./build.mjs";
import { loadBrand } from "./lib/brand.mjs";
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
      if (/<style[\s>]/i.test(html)) problems.push(`${rel(file)}: inline style element`);
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
    assert.match(m, /iTerm2[\s\S]*?status-unverified[\s\S]*?quá 120 ngày/);
    assert.ok(!m.includes("<script>alert"), "matrix notes are escaped");
    assert.match(m, /data-matrix-filters/);
    assert.match(m, /<script src="\/assets\/matrix\.js" defer><\/script>/);
    assert.ok(!/Mystery app[\s\S]{0,200}status-works/.test(m), "unknown status falls back to unverified");
    assert.match(read("en", "compatibility", "index.html"), /Works with notes/);
  });

  await check("populated: changelog rendered from CHANGELOG.md", () => {
    const c = read("nhat-ky-thay-doi", "index.html");
    assert.match(c, /<h2 id="1-0-0-2026-12-01">/);
    assert.match(c, /<strong>iTerm2<\/strong>/);
    assert.match(c, /href="\/ung-ho\/"/);
  });

  await check("populated: donate block per PRD-R59 (QR placeholders, VERIFY, sponsors)", () => {
    const d = read("ung-ho", "index.html");
    assert.match(d, /miễn phí và sẽ luôn miễn phí\. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp\./);
    assert.match(d, /vietqr\.svg/);
    assert.match(d, /momo\.svg/);
    assert.match(d, /class="verify"/);
    assert.match(d, /sponsors/i);
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

  await check("populated: language switch and hreflang alternates point at the sibling page", () => {
    const html = read("tai-ve", "index.html");
    assert.match(html, /hreflang="en" href="https:\/\/[^"]+\/en\/download\/"/);
    assert.match(html, /<a class="lang-switch" href="\/en\/download\/"/);
    assert.match(read("en", "download", "index.html"), /<a class="lang-switch" href="\/tai-ve\/"/);
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
