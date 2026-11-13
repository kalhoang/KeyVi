// SPDX-License-Identifier: LicenseRef-App-Pending
// Build context: brand, config, data, per-language content and the token tables used to fill copy.
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { loadBrand } from "./brand.mjs";
import { loadConfig } from "./config.mjs";
import { loadChangelog, loadMatrix, loadReleases } from "./data.mjs";
import { verifyBadge } from "./layout.mjs";
import { LANGS, ROUTES, routePath } from "./routes.mjs";
import { esc, interp, shortHash } from "./util.mjs";

export const DEFAULT_MIN_MACOS = "15"; // PRD-R8, pending Pa's confirmation (ADR 0001 #6)
const MACOS_NAMES = new Map([["15", "Sequoia"]]);

function pascal(id) {
  return id.split("-").map((part) => part[0].toUpperCase() + part.slice(1)).join("");
}

async function loadContent(siteDir, lang) {
  const load = async (name) => import(pathToFileURL(join(siteDir, "content", lang, `${name}.mjs`)).href);
  const [ui, pages, support] = await Promise.all([load("ui"), load("pages"), load("support")]);
  return { ui: ui.default, ...pages, ...support };
}

export function macosRequirement(lang, minimum) {
  const major = String(minimum || DEFAULT_MIN_MACOS).replace(/\.0+$/, "");
  const name = MACOS_NAMES.get(major.split(".")[0]);
  const label = `macOS ${major}${name && !major.includes(".") ? ` ${name}` : ""}`;
  return lang === "vi" ? `${label} trở lên` : `${label} or later`;
}

/**
 * @param {object} options { rootDir, siteDir, dataDir?, configPath?, today }
 */
export async function createContext(options) {
  const { rootDir, siteDir, today } = options;
  const warnings = [];
  const warn = (message) => warnings.push(message);
  const brand = await loadBrand(join(rootDir, "scripts", "brand.env"));
  const config = await loadConfig(options.configPath ?? join(siteDir, "config.json"));
  const fixturesDir = join(siteDir, "fixtures");
  const dataDir = options.dataDir ?? join(siteDir, "data");
  const matrixPath = options.dataDir ? join(options.dataDir, "matrix.json") : join(rootDir, "compat", "matrix.json");

  const releases = await loadReleases(dataDir, warn);
  const matrix = await loadMatrix(matrixPath, fixturesDir, today, warn);
  const changelog = await loadChangelog(rootDir, options.dataDir, fixturesDir, warn);
  const content = Object.fromEntries(await Promise.all(LANGS.map(async (lang) => [lang, await loadContent(siteDir, lang)])));

  const css = await readFile(join(siteDir, "static", "assets", "style.css"));
  const demo = ["demo.mp4", "demo.webm"].filter((name) => existsSync(join(siteDir, "static", "assets", name)));

  const ctx = {
    brand,
    config,
    today,
    warnings,
    warn,
    data: { releases, matrix, changelog },
    content,
    demo,
    assets: { css: `/assets/style.css?v=${shortHash(css)}` },
  };
  ctx.tokensFor = (lang) => tokensFor(ctx, lang);
  return ctx;
}

function tokensFor(ctx, lang) {
  const { brand, config } = ctx;
  const tokens = {
    AppName: brand.name,
    slug: brand.slug,
    host: brand.host,
    bundleId: brand.bundleId,
    tap: config.homebrewTap,
    repo: config.githubRepo,
    email: config.supportEmail,
    securityEmail: config.securityEmail,
    sponsors: config.sponsorsUrl,
    appcastUrl: `https://${brand.host}/appcast.xml`,
    verifyHtml: verifyBadge(lang),
  };
  for (const route of ROUTES) tokens[`href${pascal(route.id)}`] = routePath(route.id, lang);
  return tokens;
}

/** Per-page helpers: UI strings, content, a token filler and an escaper. */
export function kit(ctx, lang) {
  const tokens = ctx.tokensFor(lang);
  const f = (html, extra = {}) => interp(html, { ...tokens, ...extra });
  // Plain text (no HTML escaping) for <title> and meta values that renderDocument escapes itself.
  const p = (text, extra = {}) => {
    const all = { ...tokens, ...extra };
    return String(text).replace(/\{\{([A-Za-z][A-Za-z0-9]*)\}\}/g, (m, name) => (Object.hasOwn(all, name) ? String(all[name]) : m));
  };
  return { ui: ctx.content[lang].ui, c: ctx.content[lang], f, p, esc, lang };
}
