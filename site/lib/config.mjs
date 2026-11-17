// SPDX-License-Identifier: GPL-3.0-or-later
// Site settings that are not brand values (support addresses, Homebrew tap, sponsor link), and the repository URL.
// Values still containing a placeholder marker are reported so a release build can refuse to ship them.
// `githubRepo` is a brand value (APP_REPOSITORY_URL in scripts/brand.env, CLAUDE.md "Name"): missing or empty here
// means that one, so the shipped config never repeats the product name; set it only to link another repository.
// `sponsorsUrl` is optional: empty (the default) means there is no sponsor page, so the donation page shows no
// GitHub Sponsors card and nothing is left to fill in (PRD-R57, PRD-R59).
// `banner` is the website notice of the rollback and absence runbooks (QA-R38 step 2, QA-R54): when enabled,
// every page shows its text (vi or en) and an optional HTTPS link, usually the pinned issue.
// `analytics` is the optional Umami setup of lib/analytics.mjs (Q7): missing or empty means no analytics at all; its
// script host must be on a `site:` line of scripts/url-hosts.allow (`analyticsHosts`).
import { parseAnalytics } from "./analytics.mjs";
import { readJsonIfExists } from "./util.mjs";

const PLACEHOLDER_MARKERS = ["OWNER", ".invalid"];

const DEFAULTS = Object.freeze({
  githubRepo: "https://github.com/OWNER/REPO",
  homebrewTap: "OWNER/tap",
  supportEmail: "support@example.invalid",
  securityEmail: "security@example.invalid",
});

/** "" (no sponsor page) or an https URL. A placeholder marker in it is still reported for --strict. */
function parseSponsorsUrl(raw) {
  if (raw === undefined || raw === null) return "";
  if (typeof raw !== "string") throw new Error("config.json: sponsorsUrl must be a string");
  const url = raw.trim();
  if (url !== "" && !/^https:\/\/[^\s"'<>]+$/.test(url)) throw new Error("config.json: sponsorsUrl must be empty or an https URL");
  return url;
}

/** Plain text only (escaped when rendered) and an HTTPS link, so the notice can never add markup or scripts. */
function parseBanner(raw) {
  if (raw === undefined || raw === null) return Object.freeze({ enabled: false });
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Error("config.json: banner must be an object");
  if (raw.enabled !== true) return Object.freeze({ enabled: false });
  const text = (lang) => (typeof raw[lang] === "string" ? raw[lang].trim() : "");
  const [vi, en] = [text("vi"), text("en")];
  if (vi === "" || en === "") throw new Error("config.json: an enabled banner needs both vi and en text");
  const link = typeof raw.link === "string" ? raw.link.trim() : "";
  if (link !== "" && !/^https:\/\/[^\s"'<>]+$/.test(link)) throw new Error("config.json: banner.link must be an https URL");
  return Object.freeze({ enabled: true, vi, en, link });
}

/** The repository of scripts/brand.env when it is an https URL, else the placeholder default. */
function defaultsFor(repositoryUrl) {
  const repo = typeof repositoryUrl === "string" ? repositoryUrl.trim() : "";
  return /^https:\/\/[^\s"'<>]+$/.test(repo) ? { ...DEFAULTS, githubRepo: repo.replace(/\/+$/, "") } : DEFAULTS;
}

/**
 * @param {object} options { analyticsHosts: hosts allowed for the analytics script (loadAnalyticsHosts),
 *   repositoryUrl: APP_REPOSITORY_URL of scripts/brand.env (lib/brand.mjs), the default of `githubRepo` }
 */
export async function loadConfig(configPath, options = {}) {
  const fromFile = (await readJsonIfExists(configPath)) ?? {};
  const defaults = defaultsFor(options.repositoryUrl);
  const values = {};
  for (const key of Object.keys(defaults)) {
    const candidate = fromFile[key];
    values[key] = typeof candidate === "string" && candidate.trim() !== "" ? candidate.trim() : defaults[key];
  }
  const sponsorsUrl = parseSponsorsUrl(fromFile.sponsorsUrl);
  const placeholders = Object.entries({ ...values, sponsorsUrl })
    .filter(([, value]) => PLACEHOLDER_MARKERS.some((marker) => value.includes(marker)))
    .map(([key]) => key);
  return Object.freeze({ ...values, sponsorsUrl, placeholders, banner: parseBanner(fromFile.banner), analytics: parseAnalytics(fromFile.analytics, options.analyticsHosts ?? []) });
}
