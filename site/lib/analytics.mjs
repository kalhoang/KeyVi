// SPDX-License-Identifier: GPL-3.0-or-later
// Optional website analytics (Pa, 2026-11-13, Q7 and its evening follow-up; ADR 0602 amendment): Umami, self-hosted
// by the project on the Kalera Swarm, cookieless, no consent banner (PRD-R74). site/config.json:
//   "analytics": { "provider": "umami", "scriptUrl": "https://<host>/script.js", "websiteId": "<uuid>" }
// A missing `analytics`, or one whose three values are empty, means no analytics: no script, no third-party origin
// in the CSP. Otherwise every value is validated strictly: the script must be an https URL on a host listed on a
// `site:` line of scripts/url-hosts.allow (the website-only part of the QA-R60 allowlist), and the website id must
// be a UUID, so neither value can break out of the attribute it is written into.
// layout.mjs adds the tag to every page it renders. Release-notes pages are static files written by
// scripts/publish-release and shown in the app's update window; they never pass through layout.mjs and their
// `/release-notes/*` header policy allows no script at all, so they never carry analytics.
import { readFile } from "node:fs/promises";
import { esc } from "./util.mjs";

export const ANALYTICS_PROVIDER = "umami";
const FIELDS = Object.freeze(["provider", "scriptUrl", "websiteId"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HOST = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const DISABLED = Object.freeze({ enabled: false });

/** The hosts of the `site:` lines of scripts/url-hosts.allow, lower-cased, in file order. */
export async function loadAnalyticsHosts(allowFile) {
  const hosts = [];
  (await readFile(allowFile, "utf8")).split("\n").forEach((raw, index) => {
    const line = raw.split("#", 1)[0].trim().toLowerCase();
    if (!line.startsWith("site:")) return;
    const host = line.slice("site:".length).trim();
    if (!HOST.test(host)) throw new Error(`${allowFile}:${index + 1}: expected "site: <host>"`);
    hosts.push(host);
  });
  return Object.freeze(hosts);
}

function scriptUrlOf(raw, allowedHosts) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error("config.json: analytics.scriptUrl must be a URL");
  }
  if (url.protocol !== "https:") throw new Error("config.json: analytics.scriptUrl must be an https URL");
  if (url.username || url.password || url.port || url.search || url.hash || url.href !== raw || !url.pathname.endsWith(".js")) {
    throw new Error("config.json: analytics.scriptUrl must be a plain https://<host>/<path>.js URL");
  }
  if (!allowedHosts.includes(url.hostname)) {
    throw new Error(`config.json: analytics.scriptUrl must be on an allowed host (site: lines of scripts/url-hosts.allow: ${allowedHosts.join(", ") || "none"})`);
  }
  return url;
}

/**
 * Validates `analytics` of site/config.json against the allowed hosts. Returns `{ enabled: false }` or the frozen
 * settings `{ enabled, provider, scriptUrl, origin, websiteId }`.
 */
export function parseAnalytics(raw, allowedHosts) {
  if (raw === undefined || raw === null) return DISABLED;
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Error("config.json: analytics must be an object");
  const stray = Object.keys(raw).filter((key) => !FIELDS.includes(key));
  if (stray.length > 0) throw new Error(`config.json: analytics has unknown keys (${stray.join(", ")}); expected ${FIELDS.join(", ")}`);
  for (const key of FIELDS) {
    if (raw[key] !== undefined && typeof raw[key] !== "string") throw new Error(`config.json: analytics.${key} must be a string`);
  }
  const values = Object.fromEntries(FIELDS.map((key) => [key, (raw[key] ?? "").trim()]));
  const set = FIELDS.filter((key) => values[key] !== "");
  if (set.length === 0) return DISABLED;
  if (set.length !== FIELDS.length) throw new Error(`config.json: analytics needs ${FIELDS.join(", ")} together (or all empty for no analytics)`);
  if (values.provider !== ANALYTICS_PROVIDER) throw new Error(`config.json: analytics.provider must be "${ANALYTICS_PROVIDER}"`);
  const url = scriptUrlOf(values.scriptUrl, allowedHosts);
  if (!UUID.test(values.websiteId)) throw new Error("config.json: analytics.websiteId must be a UUID");
  return Object.freeze({ enabled: true, provider: values.provider, scriptUrl: url.href, origin: url.origin, websiteId: values.websiteId.toLowerCase() });
}

/** The CSP sources analytics needs: the script and its event endpoint, both on the Umami origin. Empty when off. */
export function analyticsCspAdditions(analytics) {
  if (!analytics?.enabled) return {};
  return { "script-src": [analytics.origin], "connect-src": [analytics.origin] };
}

/**
 * The tracker tag for a rendered page, or "" when analytics is off. `data-domains` limits counting to the site host
 * (a copy of the page elsewhere sends nothing); `data-do-not-track` honours the browser's Do Not Track setting.
 */
export function analyticsScriptTag(analytics, siteHost) {
  if (!analytics?.enabled) return "";
  if (typeof siteHost !== "string" || !HOST.test(siteHost)) throw new Error("analytics: the site host is not a valid domain");
  return `<script defer src="${esc(analytics.scriptUrl)}" data-website-id="${esc(analytics.websiteId)}" data-domains="${esc(siteHost)}" data-do-not-track="true"></script>`;
}
