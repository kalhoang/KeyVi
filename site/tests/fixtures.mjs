// SPDX-License-Identifier: GPL-3.0-or-later
// The builds every check module reads, made once per run of `node site/test.mjs`.
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { build } from "../build.mjs";
import { LANGS } from "../lib/routes.mjs";
import { SITE_DIR, readPages } from "./helpers.mjs";

/** Builds the fallback, populated and empty sites under `tmp` and loads the home copy and demo frames. */
export async function buildFixtures(tmp) {
  // The shipped site/config.json enables the Umami analytics (Q7). The fallback and populated builds use the same
  // config without `analytics`, so their privacy checks see a site with no third-party origin at all; the
  // analytics checks build with the shipped file.
  const shipped = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
  const offConfig = join(tmp, "config-no-analytics.json");
  await writeFile(offConfig, JSON.stringify({ ...shipped, analytics: undefined }));

  // 1. Fallback data (no releases.json, sample matrix fixture).
  const fallback = join(tmp, "fallback");
  const real = existsSync(join(SITE_DIR, "data", "releases.json"));
  await build({ outDir: fallback, today: "2026-11-13", dataDir: real ? join(SITE_DIR, "fixtures", "empty") : undefined, configPath: offConfig });
  const fallbackPages = await readPages(fallback);

  // 2. Populated fixtures: releases, matrix statuses, staleness, changelog.
  const populated = join(tmp, "populated");
  await build({ outDir: populated, today: "2026-12-10", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath: offConfig });
  const pop = await readPages(populated);
  const read = (...p) => pop.get(join(populated, ...p));

  // 3. No release at all (site/fixtures/empty), for the home page's no-release state.
  const emptyOut = join(tmp, "empty");
  await build({ outDir: emptyOut, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "empty"), configPath: offConfig });
  const emptyHome = { vi: await readFile(join(emptyOut, "index.html"), "utf8"), en: await readFile(join(emptyOut, "en", "index.html"), "utf8") };

  // Home page (design 7.3, plan Task 5). The demo texts come from site/demo/frames.json, never from the checks.
  const framesPath = join(SITE_DIR, "demo", "frames.json");
  const frames = JSON.parse(await readFile(framesPath, "utf8"));
  const homeCopy = Object.fromEntries(await Promise.all(LANGS.map(async (lang) => [lang, (await import(pathToFileURL(join(SITE_DIR, "content", lang, "pages.mjs")).href)).home])));
  const homePages = [["fallback vi", fallbackPages.get(join(fallback, "index.html")), "vi"], ["fallback en", fallbackPages.get(join(fallback, "en", "index.html")), "en"],
    ["populated vi", read("index.html"), "vi"], ["populated en", read("en", "index.html"), "en"]];

  return Object.freeze({ tmp, shipped, offConfig, fallback, fallbackPages, populated, pop, read, emptyHome, framesPath, frames, homeCopy, homePages });
}
