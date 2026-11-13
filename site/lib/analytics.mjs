// SPDX-License-Identifier: GPL-3.0-or-later
// Optional website analytics (Pa, 2026-11-13, Q7; ADR 0601 amendment, ADR 0602): PostHog Cloud in cookieless mode.
// site/config.json `analytics.posthogKey` empty means no analytics: no script, no third-party origin in the CSP.
// With a key, layout.mjs adds one local loader to the pages it renders. The build writes it as
// assets/analytics.<content hash>.js: `/assets/*` is cached for a year as immutable (site/static/_headers), so a
// changed loader must get a new URL to reach returning visitors and Cloudflare's cache (ADR 0602).
// Release-notes pages are static files written by scripts/publish-release and shown in the app's update window; they
// never pass through layout.mjs and their `/release-notes/*` header policy allows no script at all.
import { readFile } from "node:fs/promises";
import { esc, shortHash } from "./util.mjs";

/** PostHog Cloud ingestion hosts and the asset host each one serves its browser library from. */
export const POSTHOG_HOSTS = Object.freeze({
  "https://us.i.posthog.com": "https://us-assets.i.posthog.com",
  "https://eu.i.posthog.com": "https://eu-assets.i.posthog.com",
});
export const DEFAULT_POSTHOG_HOST = "https://us.i.posthog.com";
export const LOADER_SOURCE = new URL("./analytics-loader.js", import.meta.url);

// Project API keys are public tokens shaped `phc_<letters and digits>`; anything else is refused, so the value can
// never break out of the attribute it is written into.
const KEY_SHAPE = /^phc_[A-Za-z0-9]{16,80}$/;
const DISABLED = Object.freeze({ enabled: false });

/** Validates `analytics` of site/config.json. Returns `{ enabled: false }` or the frozen PostHog settings. */
export function parseAnalytics(raw) {
  if (raw === undefined || raw === null) return DISABLED;
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Error("config.json: analytics must be an object");
  const key = typeof raw.posthogKey === "string" ? raw.posthogKey.trim() : "";
  if (raw.posthogKey !== undefined && typeof raw.posthogKey !== "string") throw new Error("config.json: analytics.posthogKey must be a string");
  if (key === "") return DISABLED;
  if (!KEY_SHAPE.test(key)) throw new Error("config.json: analytics.posthogKey must look like phc_<letters and digits>");
  const apiHost = typeof raw.posthogHost === "string" && raw.posthogHost.trim() !== "" ? raw.posthogHost.trim().replace(/\/+$/, "") : DEFAULT_POSTHOG_HOST;
  const assetsHost = POSTHOG_HOSTS[apiHost];
  if (!assetsHost) throw new Error(`config.json: analytics.posthogHost must be one of ${Object.keys(POSTHOG_HOSTS).join(", ")}`);
  return Object.freeze({ enabled: true, key, apiHost, assetsHost });
}

/** The CSP sources analytics needs: the library from the asset host, events to the API host. Empty when off. */
export function analyticsCspAdditions(analytics) {
  if (!analytics?.enabled) return {};
  return { "script-src": [analytics.assetsHost], "connect-src": [analytics.apiHost, analytics.assetsHost] };
}

/** The URL the loader is served under: its content hash is part of the file name. */
export function analyticsScriptPath(source) {
  return `/assets/analytics.${shortHash(source)}.js`;
}

/** The loader tag for a rendered page (`src` from analyticsScriptPath), or "" when analytics is off. */
export function analyticsScriptTag(analytics, src) {
  if (!analytics?.enabled) return "";
  if (typeof src !== "string" || src === "") throw new Error("analytics: the loader URL is missing");
  return `<script src="${esc(src)}" defer data-posthog-key="${esc(analytics.key)}" data-posthog-host="${esc(analytics.apiHost)}" data-posthog-assets="${esc(analytics.assetsHost)}"></script>`;
}

/** The loader's source text (site/lib/analytics-loader.js), written to analyticsScriptPath(source) when analytics is on. */
export async function loaderSource() {
  return readFile(LOADER_SOURCE, "utf8");
}
