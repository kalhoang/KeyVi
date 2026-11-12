// SPDX-License-Identifier: LicenseRef-App-Pending
// Route table: every page exists in Vietnamese (at /) and English (at /en/). Output is
// <path>/index.html so the site works on any static host without rewrite rules.
export const MIGRATION_SOURCES = Object.freeze([
  { id: "xkey", vi: "xkey", en: "xkey" },
  { id: "openkey", vi: "openkey", en: "openkey" },
  { id: "evkey", vi: "evkey", en: "evkey" },
  { id: "gonhanh", vi: "go-nhanh", en: "go-nhanh" },
  { id: "phtv", vi: "phtv", en: "phtv" },
  { id: "macos", vi: "macos-co-san", en: "built-in-macos" },
  { id: "plaintext", vi: "tep-van-ban", en: "plain-text-file" },
]);

const PAGES = [
  { id: "home", vi: "/", en: "/en/" },
  { id: "download", vi: "/tai-ve/", en: "/en/download/" },
  { id: "compat", vi: "/tuong-thich/", en: "/en/compatibility/" },
  { id: "changelog", vi: "/nhat-ky-thay-doi/", en: "/en/changelog/" },
  { id: "privacy", vi: "/rieng-tu/", en: "/en/privacy/" },
  { id: "support", vi: "/ho-tro/", en: "/en/support/" },
  { id: "donate", vi: "/ung-ho/", en: "/en/donate/" },
];

export const ROUTES = Object.freeze([
  ...PAGES,
  ...MIGRATION_SOURCES.map((source) => ({
    id: `migrate-${source.id}`,
    vi: `/ho-tro/chuyen-tu/${source.vi}/`,
    en: `/en/support/migrate-from/${source.en}/`,
  })),
]);

export const LANGS = Object.freeze(["vi", "en"]);

const BY_ID = new Map(ROUTES.map((route) => [route.id, route]));

export function routePath(id, lang) {
  const route = BY_ID.get(id);
  if (!route) throw new Error(`Unknown route id: ${id}`);
  return route[lang];
}

/** Output file for a route path, relative to dist/. */
export function outputFile(path) {
  return `${path.replace(/^\//, "")}index.html`;
}
