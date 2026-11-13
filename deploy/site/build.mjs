#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
// Builds what the site image serves (ADR 0602); deploy/site/Dockerfile runs it, the tests run it too.
//   node deploy/site/build.mjs --out DIR [--strict true|false] [--noindex auto|true|false] [--downloads DIR]
//                              [--today YYYY-MM-DD]
// Writes DIR/html (the site, without _headers), DIR/nginx/_headers (the deployed header set) and
// DIR/nginx/locations.conf (the same headers as nginx locations), and copies the release files of --downloads
// (deploy/site/fetch-downloads.py) into DIR/html/download/.
// --strict defaults to true: a deployed build refuses VERIFY markers and placeholder config (ADR 0601). --strict
// false is a preview; --noindex auto (the default) then sends `X-Robots-Tag: noindex` on every response, as Pa decided
// on 2026-11-13 for the preview before the first public release.
import { cp, mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "../../site/build.mjs";
import { parseHeaders } from "../../site/lib/headers.mjs";
import { nginxLocations } from "./nginx-headers.mjs";

const BOOLEAN = new Map([["true", true], ["false", false]]);

/** Resolves --strict and --noindex. Throws on anything but the documented values. */
export function resolveFlags(strictArg = "true", noindexArg = "auto") {
  const strict = BOOLEAN.get(String(strictArg).trim());
  if (strict === undefined) throw new Error(`--strict must be true or false, got "${strictArg}"`);
  const noindexText = String(noindexArg ?? "").trim() || "auto";
  const noindex = noindexText === "auto" ? !strict : BOOLEAN.get(noindexText);
  if (noindex === undefined) throw new Error(`--noindex must be auto, true or false, got "${noindexArg}"`);
  return { strict, noindex };
}

/** Copies regular, non-hidden files of `from` (one level) into `to`; returns their names. */
async function copyDownloads(from, to) {
  const names = [];
  for (const entry of await readdir(from, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    if (!entry.isFile()) throw new Error(`downloads: ${entry.name} is not a regular file`);
    names.push(entry.name);
  }
  if (names.length === 0) return names;
  await mkdir(to, { recursive: true });
  for (const name of names) await cp(join(from, name), join(to, name));
  return names.sort();
}

/** Builds the image content. Returns { strict, noindex, pageCount, downloads }. */
export async function buildImageContent(options) {
  const { strict, noindex } = resolveFlags(options.strict, options.noindex);
  const out = resolve(options.outDir);
  const html = join(out, "html");
  const nginx = join(out, "nginx");
  await rm(out, { recursive: true, force: true });
  const summary = await build({ outDir: html, strict, noindex, today: options.today, configPath: options.configPath, dataDir: options.dataDir });
  await mkdir(nginx, { recursive: true });
  await rename(join(html, "_headers"), join(nginx, "_headers"));
  const rules = parseHeaders(await readFile(join(nginx, "_headers"), "utf8"));
  await writeFile(join(nginx, "locations.conf"), nginxLocations(rules));
  let downloads = [];
  if (options.downloadsDir && (await stat(options.downloadsDir).catch(() => null))?.isDirectory()) {
    downloads = await copyDownloads(options.downloadsDir, join(html, "download"));
  }
  return { strict, noindex, pageCount: summary.pageCount, downloads };
}

function parseArgs(argv) {
  const options = {};
  const names = new Map([["--out", "outDir"], ["--strict", "strict"], ["--noindex", "noindex"], ["--downloads", "downloadsDir"], ["--today", "today"], ["--config", "configPath"], ["--data-dir", "dataDir"]]);
  for (let i = 0; i < argv.length; i += 2) {
    const key = names.get(argv[i]);
    if (!key) throw new Error(`Unknown argument: ${argv[i]}`);
    if (i + 1 >= argv.length) throw new Error(`${argv[i]} needs a value`);
    options[key] = argv[i + 1];
  }
  if (!options.outDir) throw new Error("--out is required");
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await buildImageContent(parseArgs(process.argv.slice(2)));
    console.log(`site image content: ${result.pageCount} pages, strict ${result.strict}, noindex ${result.noindex}, ${result.downloads.length} release file(s)`);
  } catch (error) {
    console.error(`deploy/site/build.mjs: ${error.message}`);
    process.exitCode = 1;
  }
}
