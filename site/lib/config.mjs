// SPDX-License-Identifier: LicenseRef-App-Pending
// Site settings that are not brand values (repository URL, support addresses, Homebrew tap, sponsor link).
// Values still containing a placeholder marker are reported so a release build can refuse to ship them.
// `banner` is the website notice of the rollback and absence runbooks (QA-R38 step 2, QA-R54): when enabled,
// every page shows its text (vi or en) and an optional HTTPS link, usually the pinned issue.
// `analytics` is the optional PostHog Cloud setup of lib/analytics.mjs: an empty key means no analytics at all.
import { parseAnalytics } from "./analytics.mjs";
import { readJsonIfExists } from "./util.mjs";

const PLACEHOLDER_MARKERS = ["OWNER", ".invalid"];

const DEFAULTS = Object.freeze({
  githubRepo: "https://github.com/OWNER/REPO",
  sponsorsUrl: "https://github.com/sponsors/OWNER",
  homebrewTap: "OWNER/tap",
  supportEmail: "support@example.invalid",
  securityEmail: "security@example.invalid",
});

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

export async function loadConfig(configPath) {
  const fromFile = (await readJsonIfExists(configPath)) ?? {};
  const values = {};
  for (const key of Object.keys(DEFAULTS)) {
    const candidate = fromFile[key];
    values[key] = typeof candidate === "string" && candidate.trim() !== "" ? candidate.trim() : DEFAULTS[key];
  }
  const placeholders = Object.entries(values)
    .filter(([, value]) => PLACEHOLDER_MARKERS.some((marker) => value.includes(marker)))
    .map(([key]) => key);
  return Object.freeze({ ...values, placeholders, banner: parseBanner(fromFile.banner), analytics: parseAnalytics(fromFile.analytics) });
}
