// SPDX-License-Identifier: GPL-3.0-or-later
// Content fingerprints for /assets/ URLs (ADR 0602). site/static/_headers caches `/assets/*` for a year as
// `immutable`, so a URL must change whenever its file changes: every `src` or `href` that names a file of
// site/static/assets gets `?v=<short content hash>`. Files the build writes under a hashed name (the analytics loader,
// lib/analytics.mjs) already carry the hash and are left alone, as is any URL that has a query string already.
import { readFile, readdir } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import { shortHash } from "./util.mjs";

const ASSET_REFERENCE = /\b(src|href)="(\/assets\/[^"?#]+)"/g;

/** Map of `/assets/<relative path>` to the short content hash of every file under `assetsDir`. */
export async function assetHashes(assetsDir) {
  const entries = await readdir(assetsDir, { recursive: true, withFileTypes: true });
  const files = entries.filter((entry) => entry.isFile());
  const pairs = await Promise.all(files.map(async (entry) => {
    const path = join(entry.parentPath, entry.name);
    const url = `/assets/${relative(assetsDir, path).split(sep).join("/")}`;
    return [url, shortHash(await readFile(path))];
  }));
  return new Map(pairs);
}

/** `html` with `?v=<hash>` appended to every reference to a known asset file. */
export function fingerprintAssets(html, hashes) {
  return html.replace(ASSET_REFERENCE, (match, attribute, url) => {
    const hash = hashes.get(url);
    return hash ? `${attribute}="${url}?v=${hash}"` : match;
  });
}
