// SPDX-License-Identifier: LicenseRef-App-Pending
// Reads the brand values (display name, slug, bundle IDs, site host) from scripts/brand.env.
// The name is temporary; scripts/rename-app.sh keeps brand.env in sync, so the site never hard-codes it.
import { readFile } from "node:fs/promises";

const REQUIRED = ["APP_DISPLAY_NAME", "APP_SLUG", "APP_BUNDLE_ID_RELEASE", "APP_SITE_HOST"];

export function parseBrandEnv(text) {
  const values = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;
    const match = /^(?:export\s+)?([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!match) continue;
    let value = match[2].trim();
    if (/^(".*"|'.*')$/.test(value)) value = value.slice(1, -1);
    values[match[1]] = value;
  }
  return values;
}

export async function loadBrand(brandEnvPath) {
  let text;
  try {
    text = await readFile(brandEnvPath, "utf8");
  } catch (error) {
    throw new Error(`Cannot read brand values from ${brandEnvPath}: ${error.message}`);
  }
  const env = parseBrandEnv(text);
  const missing = REQUIRED.filter((key) => !env[key]);
  if (missing.length > 0) throw new Error(`Missing ${missing.join(", ")} in ${brandEnvPath}`);
  return Object.freeze({
    name: env.APP_DISPLAY_NAME,
    slug: env.APP_SLUG,
    bundleId: env.APP_BUNDLE_ID_RELEASE,
    host: env.APP_SITE_HOST,
  });
}
