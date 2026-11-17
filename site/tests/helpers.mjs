// SPDX-License-Identifier: GPL-3.0-or-later
// Shared helpers of the site checks (`node site/test.mjs`): paths, file walking, HTML and XML probes, colour contrast.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { headersForPath } from "../lib/headers.mjs";
import { shortHash } from "../lib/util.mjs";

export const SITE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const ROOT_DIR = resolve(SITE_DIR, "..");
export const ASSETS_DIR = join(SITE_DIR, "static", "assets");
// home.js is a classic script that also exports its pure functions as CommonJS (site/ has no package.json); it is
// loaded inside each motion check, so a missing or broken file fails those checks and not the whole run.
export const siteMotion = () => createRequire(import.meta.url)(join(ASSETS_DIR, "home.js"));

export async function walk(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path)));
    else out.push(path);
  }
  return out;
}

/** Every HTML page of a build, by absolute path. */
export async function readPages(dist) {
  const htmlFiles = (await walk(dist)).filter((f) => f.endsWith(".html"));
  return new Map(await Promise.all(htmlFiles.map(async (f) => [f, await readFile(f, "utf8")])));
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

export const attrs = (html, name) => [...html.matchAll(new RegExp(`\\s${name}="([^"]*)"`, "g"))].map((m) => m[1]);
// Pages written by scripts/publish-release (ADR 0304): one bilingual page per release, opened by Sparkle.
export const isReleaseNotesPage = (relPath) => relPath.startsWith("release-notes/");

export function resolveInternal(dist, fromFile, href) {
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
export async function appHelpTargets() {
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

export const sha256Base64 = (text) => createHash("sha256").update(text, "utf8").digest("base64");

/** WCAG 2.2 contrast ratio of two #rrggbb colours (relative luminance of sRGB). */
export function contrast(first, second) {
  const luminance = (hex) => {
    const [r, g, b] = [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const [high, low] = [luminance(first), luminance(second)].sort((x, y) => y - x);
  return (high + 0.05) / (low + 0.05);
}

/** Origins other than the site itself that a page or header can make the browser contact: resource attributes
 * (script src, stylesheet, preload, icon, img, media) and every CSP source with a scheme and host. */
export function thirdPartyOrigins(html) {
  const origins = new Set();
  const add = (url) => { const m = url.match(/^(https?:)?\/\/[^/"'\s]+/i); if (m) origins.add(m[0].startsWith("//") ? `https:${m[0]}` : m[0]); };
  for (const tag of html.match(/<(?:script|img|source|video|audio|iframe|embed)\b[^>]*>/gi) ?? []) for (const src of attrs(tag, "src")) add(src);
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) if (!/rel="(?:alternate|canonical)"/.test(tag)) for (const href of attrs(tag, "href")) add(href);
  for (const policy of attrs(html, "content").filter((value) => /default-src/.test(value))) for (const source of policy.split(/[\s;]+/)) add(source);
  return origins;
}

export const cspOf = (rules, path) => headersForPath(rules, path).filter(([name]) => name === "Content-Security-Policy").map(([, value]) => value);


/**
 * Every `/assets/...` URL in the built pages names the current content of its file, either as `?v=<hash>` or in the
 * file name (`name.<hash>.js`), so a changed file always gets a new URL despite the year-long immutable caching of
 * `/assets/*` in static/_headers (browsers and Cloudflare never serve a stale copy, and no purge is needed).
 */
export async function assertFingerprinted(dist) {
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

// Home page probes (design 7.3).
export const section = (html, name) => html.match(new RegExp(`<section\\b[^>]*\\sdata-section="${name}"[\\s\\S]*?</section>`))?.[0] ?? "";
export const mainOf = (html) => html.split('<main id="main"')[1]?.split("</main>")[0] ?? "";
// Text outside tags, so outside every attribute value; entities stay escaped.
export const textOf = (html) => html.replace(/<[^>]*>/g, "");
export const unescapeHtml = (text) => text.replace(/&(amp|lt|gt|quot|#39);/g, (whole, name) => ({ amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'" })[name]);
export const framesAttr = (tag) => JSON.parse(unescapeHtml(attrs(tag, "data-demo-frames")[0] ?? "null"));
export const heroTag = (html) => html.match(/<[^>]*\sdata-hero[\s>][^>]*>/)?.[0] ?? "";
// Visible text of <main>: tags dropped (pageText) or turned into spaces (plainText), entities unescaped, spaces folded.
export const pageText = (html) => unescapeHtml(mainOf(html).replace(/<[^>]*>/g, "")).replace(/\s+/g, " ");
export const plainText = (html) => unescapeHtml(mainOf(html).replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ");
// The hero tags (design 9 item 1): the inner HTML of each `<span class="tag">` of a tags row, in order. A tag holds a
// <strong> word and, for a word plain Telex would have changed, a struck-through <span class="tag-plain">.
export const tagsOf = (rowHtml) => rowHtml.split('<span class="tag">').slice(1).map((piece) => piece.replace(/<\/span>\s*$/, ""));
/** What a tag says, in words: the plain form's template when plain Telex would have changed the word, keepTag otherwise. */
export const tagText = (copy, { text, plain }) => (plain ? copy.plainTag.replace("{{word}}", text).replace("{{plain}}", plain) : copy.keepTag.replace("{{word}}", text));
// The keys strip (design 9 item 4): it ends at the key a demo is about, the restore toggle of a correction or the commit
// the engine took from memory (rule learned, L9c), else at the last key, and keeps the last eight keycaps up to there.
export const keysEndOf = (frames) => {
  const focus = frames.findLastIndex((frame) => frame.toggle === true || frame.commit?.rule === "learned");
  return focus >= 0 ? focus : frames.length - 1;
};
export const stripKeys = (frames) => frames.slice(0, keysEndOf(frames) + 1).slice(-8).map((frame) => frame.key);
// The learned badge of the learning section as lib/pages/home/learning.mjs writes it; its label is group 1.
export const LEARNED_BADGE = /<span class="learned-badge"(?: lang="[a-z]+")?><span class="visually-hidden"> \(<\/span>([^<]*)<span class="visually-hidden">\)<\/span><\/span>/g;
// The rows of the learning demo: label, field and keys strip of each `<li class="learning-row" data-run>`.
export const learningRows = (html) => [...html.matchAll(/<li class="learning-row" data-run><span class="learning-label">([^<]*)<\/span><p class="demo-field" data-input[^>]*>([\s\S]*?)<\/p><p class="keys" data-keys aria-hidden="true">([\s\S]*?)<\/p><\/li>/g)]
  .map(([, label, field, keys]) => ({ label, field, keys }));
