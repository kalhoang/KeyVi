#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
// Static site generator: `node site/build.mjs` writes site/dist. Node 22+, no dependencies.
//   --out <dir>        output directory (default site/dist)
//   --data-dir <dir>   read releases.json, matrix.json, CHANGELOG.md from this directory (tests, previews)
//   --today <date>     fixed build date (YYYY-MM-DD), also honours SOURCE_DATE_EPOCH
//   --strict           fail when VERIFY markers or placeholder config values remain (release gate)
import { cp, mkdir, readdir, rm } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { renderAppcast } from "./lib/appcast.mjs";
import { createContext } from "./lib/context.mjs";
import { isoDay, parseIsoDate } from "./lib/dates.mjs";
import { renderDocument } from "./lib/layout.mjs";
import { renderCompat } from "./lib/pages/compat.mjs";
import { renderDownload } from "./lib/pages/download.mjs";
import { renderHome } from "./lib/pages/home.mjs";
import { renderChangelog, renderDonate, renderNotFound, renderPrivacy } from "./lib/pages/simple.mjs";
import { renderMigration, renderSupport } from "./lib/pages/support.mjs";
import { LANGS, MIGRATION_SOURCES, ROUTES, outputFile, routePath } from "./lib/routes.mjs";
import { renderRobots, renderSitemap } from "./lib/sitemap.mjs";
import { writeFileDeep } from "./lib/util.mjs";

const SITE_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = resolve(SITE_DIR, "..");

const RENDERERS = new Map([
  ["home", renderHome], ["download", renderDownload], ["compat", renderCompat],
  ["changelog", renderChangelog], ["privacy", renderPrivacy], ["support", renderSupport], ["donate", renderDonate],
  ...MIGRATION_SOURCES.map((source) => [`migrate-${source.id}`, (ctx, lang) => renderMigration(ctx, lang, source.id)]),
]);

function assertSafeOutDir(outDir) {
  const withSep = (path) => (path.endsWith(sep) ? path : path + sep);
  for (const protectedDir of [ROOT_DIR, SITE_DIR]) {
    if (withSep(protectedDir).startsWith(withSep(outDir))) {
      throw new Error(`Refusing to clean ${outDir}: it contains the project (${protectedDir})`);
    }
  }
}

function resolveToday(option) {
  const fromOption = option ? parseIsoDate(option) : undefined;
  if (option && !fromOption) throw new Error(`--today expects YYYY-MM-DD, got ${option}`);
  if (fromOption) return fromOption;
  const epoch = Number(process.env.SOURCE_DATE_EPOCH);
  return Number.isFinite(epoch) && epoch > 0 ? new Date(epoch * 1000) : new Date();
}

/** Build the whole site. Returns a summary used by the CLI and by test.mjs. */
export async function build(options = {}) {
  const outDir = resolve(options.outDir ?? join(SITE_DIR, "dist"));
  assertSafeOutDir(outDir);
  const today = resolveToday(options.today);
  const ctx = await createContext({ rootDir: ROOT_DIR, siteDir: SITE_DIR, dataDir: options.dataDir, today });

  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });

  const pages = [];
  for (const route of ROUTES) {
    for (const lang of LANGS) {
      const partial = RENDERERS.get(route.id)(ctx, lang);
      const path = routePath(route.id, lang);
      pages.push({ file: outputFile(path), html: renderDocument(ctx, { ...partial, lang, ui: ctx.content[lang].ui, path }) });
    }
  }
  const notFound = renderNotFound(ctx);
  pages.push({ file: "404.html", html: renderDocument(ctx, { ...notFound, ui: ctx.content.vi.ui }) });

  await Promise.all(pages.map((page) => writeFileDeep(join(outDir, page.file), page.html)));
  await cp(join(SITE_DIR, "static"), outDir, { recursive: true, filter: (src) => !src.endsWith(`${sep}appcast.xml`) });
  await writeFileDeep(join(outDir, "appcast.xml"), await renderAppcast(join(SITE_DIR, "static", "appcast.xml"), ctx.brand));
  await writeFileDeep(join(outDir, "sitemap.xml"), renderSitemap(ctx.brand, isoDay(today)));
  await writeFileDeep(join(outDir, "robots.txt"), renderRobots(ctx.brand));

  const verifyCount = pages.reduce((sum, page) => sum + (page.html.match(/class="verify"/g) ?? []).length, 0);
  const summary = { outDir, pageCount: pages.length, verifyCount, placeholders: ctx.config.placeholders, warnings: ctx.warnings, files: (await readdir(outDir)).length };
  if (options.strict && (verifyCount > 0 || summary.placeholders.length > 0)) {
    throw new Error(`--strict: ${verifyCount} VERIFY marker(s) and placeholder config value(s) [${summary.placeholders.join(", ")}] remain`);
  }
  return summary;
}

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`);
      i += 1;
      return argv[i];
    };
    if (arg === "--out") options.outDir = value();
    else if (arg === "--data-dir") options.dataDir = resolve(value());
    else if (arg === "--today") options.today = value();
    else if (arg === "--strict") options.strict = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const summary = await build(parseArgs(process.argv.slice(2)));
    for (const warning of summary.warnings) console.warn(`warning: ${warning}`);
    if (summary.placeholders.length > 0) console.warn(`warning: placeholder values in site/config.json: ${summary.placeholders.join(", ")}`);
    console.log(`built ${summary.pageCount} pages into ${summary.outDir} (${summary.verifyCount} VERIFY markers to resolve before release)`);
  } catch (error) {
    console.error(`build failed: ${error.message}`);
    process.exitCode = 1;
  }
}
