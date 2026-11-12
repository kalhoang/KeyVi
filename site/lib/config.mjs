// SPDX-License-Identifier: LicenseRef-App-Pending
// Site settings that are not brand values (repository URL, support addresses, Homebrew tap, sponsor link).
// Values still containing a placeholder marker are reported so a release build can refuse to ship them.
import { readJsonIfExists } from "./util.mjs";

const PLACEHOLDER_MARKERS = ["OWNER", ".invalid"];

const DEFAULTS = Object.freeze({
  githubRepo: "https://github.com/OWNER/REPO",
  sponsorsUrl: "https://github.com/sponsors/OWNER",
  homebrewTap: "OWNER/tap",
  supportEmail: "support@example.invalid",
  securityEmail: "security@example.invalid",
});

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
  return Object.freeze({ ...values, placeholders });
}
