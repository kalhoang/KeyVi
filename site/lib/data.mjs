// SPDX-License-Identifier: LicenseRef-App-Pending
// Loads and normalises the data the site renders: releases (site/data/releases.json, written by
// scripts/publish-release), the compatibility matrix (compat/matrix.json, QA-R17) and the changelog
// (CHANGELOG.md). Input is treated as untrusted: unknown shapes are skipped with a warning, never fatal.
// When a real file is absent the site falls back to site/fixtures/ (see docs/decisions/0601).
import { join } from "node:path";
import { daysBetween, parseIsoDate } from "./dates.mjs";
import { compareVersions, readJsonIfExists, readTextIfExists } from "./util.mjs";

export const STALE_AFTER_DAYS = 120; // QA-R19
export const STATUSES = ["works", "notes", "unverified", "limitation"]; // PRD-R35

const STATUS_ALIASES = new Map([
  ["works", "works"], ["ok", "works"], ["pass", "works"], ["verified", "works"], ["good", "works"],
  ["hoat dong tot", "works"],
  ["notes", "notes"], ["works-with-notes", "notes"], ["workswithnotes", "notes"], ["works_with_notes", "notes"],
  ["caveat", "notes"], ["hoat dong, co luu y", "notes"],
  ["unverified", "unverified"], ["not-verified", "unverified"], ["notverified", "unverified"],
  ["unknown", "unverified"], ["untested", "unverified"], ["chua kiem tra", "unverified"],
  ["limitation", "limitation"], ["known-limitation", "limitation"], ["knownlimitation", "limitation"],
  ["known_limitation", "limitation"], ["limited", "limitation"], ["fail", "limitation"],
  ["han che da biet", "limitation"],
]);

function foldAscii(text) {
  return String(text).normalize("NFD").replace(/\p{M}/gu, "").replace(/đ/g, "d").replace(/Đ/g, "D").toLowerCase().trim();
}

export function normalizeStatus(raw) {
  return STATUS_ALIASES.get(foldAscii(raw ?? "")) ?? "unverified";
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

export function normalizeMatrixEntry(raw, today) {
  const name = String(raw?.displayName ?? raw?.name ?? raw?.app ?? "").trim();
  if (name === "") return undefined;
  const verifiedAt = typeof (raw?.lastVerified ?? raw?.verifiedAt ?? raw?.date) === "string"
    ? String(raw.lastVerified ?? raw.verifiedAt ?? raw.date) : "";
  const verifiedDate = parseIsoDate(verifiedAt);
  const stale = !verifiedDate || daysBetween(verifiedDate, today) > STALE_AFTER_DAYS;
  const declared = normalizeStatus(raw?.status);
  return {
    name,
    bundleId: String(raw?.bundleId ?? raw?.bundleID ?? "").trim(),
    category: String(raw?.category ?? "other").trim().toLowerCase() || "other",
    tier: Number.parseInt(raw?.tier, 10) || 0,
    declaredStatus: declared,
    // QA-R19: entries not verified for 120 days display as "Chưa kiểm tra".
    status: stale ? "unverified" : declared,
    stale: stale && declared !== "unverified",
    note: localized(raw?.note ?? raw?.notes),
    lastVerified: verifiedDate ? verifiedAt.slice(0, 10) : "",
    appVersion: String(raw?.appVersion ?? "").trim(),
    macOSVersion: String(raw?.macOSVersion ?? raw?.macosVersion ?? raw?.macOS ?? "").trim(),
  };
}

export async function loadMatrix(matrixPath, fixturesDir, today, warn) {
  const real = await readJsonIfExists(matrixPath);
  const usingFixture = real === undefined;
  const raw = usingFixture ? await readJsonIfExists(join(fixturesDir, "matrix.json")) : real;
  if (usingFixture) warn("compat/matrix.json not found: using the sample fixture (every row unverified)");
  const entries = asList(raw, ["entries", "apps", "rows", "items"])
    .map((entry) => normalizeMatrixEntry(entry, today))
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
