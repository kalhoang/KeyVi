// SPDX-License-Identifier: GPL-3.0-or-later
// Loads and normalises the data the site renders: releases (site/data/releases.json, written by
// scripts/publish-release), the compatibility matrix (compat/matrix.json, QA-R17) and the changelog
// (CHANGELOG.md). Input is treated as untrusted: unknown shapes are skipped with a warning, never fatal.
// When a real file is absent the site falls back to site/fixtures/ (see docs/decisions/0601). The matrix
// fallback (site/fixtures/matrix.json) is schema-valid sample data with every row notVerified.
import { join } from "node:path";
import { daysBetween, parseIsoDate } from "./dates.mjs";
import { compareVersions, readJsonIfExists, readTextIfExists } from "./util.mjs";

export const STALE_AFTER_DAYS = 120; // QA-R19
// compat/schema/matrix.schema.json is the source of truth for every matrix field name and value (PRD-R35,
// QA-R17). Statuses, in legend order:
export const STATUSES = ["works", "worksWithNotes", "notVerified", "knownLimitation"];
export const CATEGORIES = ["browser", "office", "chat", "notes", "developer", "terminal", "design", "launcher",
  "remote", "game", "system", "other"];

/** A status outside the schema enum shows as "notVerified": never claim more than the data says. */
export function normalizeStatus(raw) {
  return STATUSES.includes(raw) ? raw : "notVerified";
}

function safeUrl(value) {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return /^https:\/\//i.test(trimmed) || /^\/(?!\/)/.test(trimmed) ? trimmed : undefined;
}

function localized(value) {
  if (typeof value === "string") return { vi: value, en: value };
  if (value && typeof value === "object") {
    const vi = typeof value.vi === "string" ? value.vi : undefined;
    const en = typeof value.en === "string" ? value.en : undefined;
    return { vi: vi ?? en ?? "", en: en ?? vi ?? "" };
  }
  return { vi: "", en: "" };
}

function asList(raw, keys) {
  if (Array.isArray(raw)) return raw;
  if (raw && typeof raw === "object") {
    for (const key of keys) if (Array.isArray(raw[key])) return raw[key];
  }
  return [];
}

export function normalizeRelease(raw, warn) {
  const dmg = raw?.dmg && typeof raw.dmg === "object" ? raw.dmg : {};
  const version = typeof raw?.version === "string" ? raw.version.trim() : "";
  const url = safeUrl(raw?.dmgUrl ?? raw?.dmg_url ?? raw?.url ?? dmg.url);
  if (version === "" || !url) {
    warn(`releases.json: skipped an entry without a version or a safe https DMG URL (${JSON.stringify(raw?.version)})`);
    return undefined;
  }
  const sha = String(raw?.sha256 ?? raw?.dmgSha256 ?? dmg.sha256 ?? "").trim().toLowerCase();
  return {
    version,
    build: raw?.build === undefined ? "" : String(raw.build),
    channel: String(raw?.channel ?? "stable").toLowerCase() === "beta" ? "beta" : "stable",
    date: typeof raw?.date === "string" ? raw.date : "",
    url,
    sha256: /^[0-9a-f]{64}$/.test(sha) ? sha : "",
    minimumSystemVersion: String(raw?.minimumSystemVersion ?? raw?.minimum_system_version ?? "").trim(),
    notes: localized(raw?.notes),
  };
}

function byNewest(a, b) {
  return compareVersions(b.version, a.version) || String(b.date).localeCompare(String(a.date));
}

export function summarizeReleases(releases) {
  const sorted = [...releases].sort(byNewest);
  const stable = sorted.find((r) => r.channel === "stable");
  const betaCandidate = sorted.find((r) => r.channel === "beta");
  // A beta only matters while it is newer than the latest stable (QA-R28: beta users also get newer stables).
  const beta = betaCandidate && (!stable || compareVersions(betaCandidate.version, stable.version) > 0) ? betaCandidate : undefined;
  const shown = new Set([stable, beta].filter(Boolean));
  return { all: sorted, stable, beta, archive: sorted.filter((r) => !shown.has(r)) };
}

export async function loadReleases(dataDir, warn) {
  const raw = await readJsonIfExists(join(dataDir, "releases.json"));
  const entries = asList(raw, ["releases", "items"]);
  const releases = entries.map((entry) => normalizeRelease(entry, warn)).filter(Boolean);
  return summarizeReleases(releases);
}

const text = (value) => (typeof value === "string" ? value.trim() : "");

function schemaNote(value) {
  // Schema: note is {vi, en}. Anything else is ignored rather than guessed.
  if (!value || typeof value !== "object" || Array.isArray(value)) return { vi: "", en: "" };
  return localized(value);
}

/** Normalises one compat/matrix.json entry (field names of matrix.schema.json). */
export function normalizeMatrixEntry(raw, today, warn = () => {}) {
  const name = text(raw?.displayName);
  if (name === "") {
    warn("compat/matrix.json: skipped an entry without a displayName");
    return undefined;
  }
  if (raw.status !== undefined && !STATUSES.includes(raw.status)) {
    warn(`compat/matrix.json: ${name}: status ${JSON.stringify(raw.status)} is not in the schema; shown as notVerified`);
  }
  const verifiedAt = text(raw.lastVerified);
  const verifiedDate = parseIsoDate(verifiedAt);
  const stale = !verifiedDate || daysBetween(verifiedDate, today) > STALE_AFTER_DAYS;
  const declared = normalizeStatus(raw.status);
  return {
    name,
    bundleId: text(raw.bundleId),
    category: CATEGORIES.includes(raw.category) ? raw.category : "other",
    tier: raw.tier === 1 || raw.tier === 2 ? raw.tier : 0,
    ruleId: text(raw.ruleId),
    declaredStatus: declared,
    // QA-R19: entries not verified for 120 days display as "Chưa kiểm tra".
    status: stale ? "notVerified" : declared,
    stale: stale && declared !== "notVerified",
    note: schemaNote(raw.note),
    lastVerified: verifiedDate ? verifiedAt.slice(0, 10) : "",
    appVersion: text(raw.appVersion),
    macOS: text(raw.macOS),
    issues: Array.isArray(raw.issues) ? raw.issues.filter((n) => Number.isInteger(n) && n > 0) : [],
  };
}

export async function loadMatrix(matrixPath, fixturesDir, today, warn) {
  const real = await readJsonIfExists(matrixPath);
  const usingFixture = real === undefined;
  const raw = usingFixture ? await readJsonIfExists(join(fixturesDir, "matrix.json")) : real;
  if (usingFixture) warn("compat/matrix.json not found: using the sample fixture (every row not verified)");
  const entries = asList(raw, ["entries"])
    .map((entry) => normalizeMatrixEntry(entry, today, warn))
    .filter(Boolean)
    .sort((a, b) => (a.tier || 9) - (b.tier || 9) || a.name.localeCompare(b.name, "en"));
  return { entries, usingFixture };
}

export async function loadChangelog(rootDir, dataDirOverride, fixturesDir, warn) {
  const candidates = (name) => [dataDirOverride, rootDir].filter(Boolean).map((dir) => join(dir, name));
  const firstExisting = async (name) => {
    for (const path of candidates(name)) {
      const text = await readTextIfExists(path);
      if (text !== undefined) return text;
    }
    return undefined;
  };
  const base = await firstExisting("CHANGELOG.md");
  const vi = (await firstExisting("CHANGELOG.vi.md")) ?? base;
  if (base === undefined) warn("CHANGELOG.md not found: using the fixture");
  const fallback = base === undefined ? await readTextIfExists(join(fixturesDir, "CHANGELOG.md")) : undefined;
  return { vi: vi ?? fallback ?? "", en: base ?? fallback ?? "", usingFixture: base === undefined };
}
