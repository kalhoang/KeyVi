// SPDX-License-Identifier: GPL-3.0-or-later
// The checks every build passes: pages, language attributes, links and anchors, privacy (PRD-R74), XML, prose,
// tone placement and donation entry points (PRD-R57).
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { extname, join } from "node:path";
import { LANGS, ROUTES, outputFile, routePath } from "../lib/routes.mjs";
import { siteToneOffenders } from "../lib/tone.mjs";
import { walk, readPages, assertWellFormedXml, attrs, isReleaseNotesPage, resolveInternal, sha256Base64 } from "./helpers.mjs";

/** The checks every build passes. `allowedScriptTag`: the one external script a build may carry (the analytics tag of
 * site/config.json, Q7). */
export async function checkSite(check, label, dist, { allowedScriptTag = "" } = {}) {
  const pages = await readPages(dist);
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
    const listed = ROUTES.filter((route) => !route.unlisted);
    assert.equal(locs.length, listed.length * LANGS.length);
    for (const path of locs) assert.ok(existsSync(join(dist, path, "index.html")), `sitemap: ${path}`);
    assert.match(await readFile(join(dist, "robots.txt"), "utf8"), /Sitemap: https:\/\/[^/]+\/sitemap\.xml/);
  });

  // Design 9 item 2: the compatibility page is unlisted. It stays at its URL, because the app's menu opens it
  // (CompatibilityPage in Packages/AppCore/Sources/ShellCore/StatusPresentation.swift), but no other page links to it,
  // the sitemap leaves it out and it asks search engines not to index it.
  const compatPaths = new Set(LANGS.map((lang) => routePath("compat", lang)));
  const isCompatPage = (file) => compatPaths.has(`/${rel(file).replace(/index\.html$/, "")}`);
  await check(`${label}: no page links to the compatibility page, which is unlisted and noindex (design 9 item 2)`, async () => {
    assert.ok(ROUTES.find((route) => route.id === "compat")?.unlisted === true, "routes.mjs marks compat unlisted");
    const problems = [];
    for (const [file, html] of pages) {
      const compat = isCompatPage(file);
      const robots = /<meta name="robots" content="noindex">/.test(html);
      // The 404 page has always carried noindex, and so do the release-notes pages publish-release writes for the
      // update window (ADR 0304); every listed page is indexed.
      if (compat ? !robots : robots && rel(file) !== "404.html" && !isReleaseNotesPage(rel(file))) problems.push(`${rel(file)}: ${compat ? "no" : "unexpected"} noindex`);
      // The compatibility pages may link to each other (language switch, alternates); no other page links to them.
      if (compat) continue;
      for (const href of attrs(html, "href")) {
        const path = href.replace(/^https:\/\/[^/]+/, "").split(/[?#]/)[0];
        if (compatPaths.has(path) || compatPaths.has(`${path}/`)) problems.push(`${rel(file)} -> ${href}`);
      }
    }
    assert.deepEqual(problems, []);
    const sitemap = await readFile(join(dist, "sitemap.xml"), "utf8");
    for (const path of compatPaths) assert.ok(!sitemap.includes(`${path}<`) && !sitemap.includes(`${path}"`), `sitemap.xml lists ${path}`);
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
}
