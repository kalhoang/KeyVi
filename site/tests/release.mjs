// SPDX-License-Identifier: GPL-3.0-or-later
// The release gate on the shipped config: the site builds with --strict (no VERIFY marker, no placeholder) both before
// the first release (no releases.json) and once scripts/publish-release has written the 1.0.0 entry, and in the second
// state the home page and the download page show the release (PRD-R73, docs/runbooks/site-deploy.md section 8).
import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { build } from "../build.mjs";
import { loadBrand } from "../lib/brand.mjs";
import { macosRequirement } from "../lib/context.mjs";
import { formatDate } from "../lib/dates.mjs";
import { SITE_DIR, ROOT_DIR } from "./helpers.mjs";

// The entry exactly as `publish_helpers.py releases-add` writes it (scripts/publish-release section 4): the build number
// of scripts/build-number.sh 1.0.0, the DMG under https://<site host>/download/ (ADR 0504) and LSMinimumSystemVersion.
function firstRelease(brand) {
  return {
    version: "1.0.0",
    build: 1000099,
    channel: "stable",
    date: "2026-11-17",
    dmgUrl: `https://${brand.host}/download/${brand.slug}-1.0.0.dmg`,
    sha256: "0123456789abcdef".repeat(4),
    size: 9876543,
    minimumSystemVersion: "12.0",
    notes: { vi: "Bản phát hành đầu tiên.", en: "First release." },
  };
}

const section = (html, name) => html.match(new RegExp(`<section[^>]*data-section="${name}"[\\s\\S]*?</section>`))?.[0] ?? "";
const header = (html) => html.match(/<header class="site-header">[\s\S]*?<\/header>/)?.[0] ?? "";

/** Strict builds of the shipped config before and after the first release. */
export async function runReleaseChecks(check, fixtures) {
  const { tmp, shipped } = fixtures;
  const configPath = join(SITE_DIR, "config.json");
  const brand = await loadBrand(join(ROOT_DIR, "scripts", "brand.env"));
  const brew = `brew install --cask ${shipped.homebrewTap}/${brand.slug}`;
  const pages = (out) => ({
    home: { vi: join(out, "index.html"), en: join(out, "en", "index.html") },
    download: { vi: join(out, "tai-ve", "index.html"), en: join(out, "en", "download", "index.html") },
  });
  const read = (file) => readFile(file, "utf8");

  await check("release gate: the shipped config names the real tap and repository, no placeholder", () => {
    assert.match(shipped.homebrewTap, /^[a-z0-9-]+\/tap$/, "homebrewTap is <owner>/tap (repository <owner>/homebrew-tap)");
    assert.ok(!("githubRepo" in shipped) || !shipped.githubRepo.includes("OWNER"), "githubRepo comes from APP_REPOSITORY_URL");
    assert.match(brand.repositoryUrl, /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+$/, "scripts/brand.env names the repository");
    assert.equal(shipped.sponsorsUrl, "", "no GitHub Sponsors page: empty, which is not a placeholder");
  });

  await check("release gate: --strict passes before the first release, with the no-release state shown", async () => {
    const out = join(tmp, "strict-unreleased");
    const summary = await build({ outDir: out, today: "2026-11-17", strict: true, configPath, dataDir: join(SITE_DIR, "fixtures", "empty") });
    assert.equal(summary.verifyCount, 0);
    assert.deepEqual(summary.placeholders, []);
    const p = pages(out);
    for (const lang of ["vi", "en"]) {
      const home = await read(p.home[lang]);
      assert.match(section(home, "hero"), /<p class="btn btn-disabled" aria-disabled="true">/, `${lang}: disabled hero button`);
      assert.match(section(home, "closing"), /<p class="btn btn-disabled" aria-disabled="true">/, `${lang}: disabled closing button`);
      assert.match(header(home), /<span class="btn btn-disabled" aria-disabled="true">/, `${lang}: disabled header button`);
      assert.ok(!/\.dmg"/.test(home), `${lang}: no DMG link before the release`);
      const download = await read(p.download[lang]);
      assert.match(download, /<div class="callout"><p><strong>[^<]+<\/strong><\/p>/, `${lang}: the no-release callout`);
      assert.ok(download.includes(macosRequirement(lang, "")), `${lang}: the default minimum, macOS 12`);
      assert.ok(download.includes(brew), `${lang}: the brew line`);
    }
  });

  await check("release gate: --strict passes once publish-release wrote 1.0.0; hero, closing and download page show it", async () => {
    const release = firstRelease(brand);
    const dataDir = join(tmp, "release-1.0.0");
    await mkdir(dataDir, { recursive: true });
    await writeFile(join(dataDir, "releases.json"), JSON.stringify({ schemaVersion: 1, releases: [release] }, null, 2));
    const out = join(tmp, "strict-released");
    const summary = await build({ outDir: out, today: "2026-11-17", strict: true, configPath, dataDir });
    assert.equal(summary.verifyCount, 0);
    assert.deepEqual(summary.placeholders, []);
    assert.deepEqual(summary.warnings.filter((w) => w.startsWith("releases.json")), [], "the entry is accepted as written");
    const p = pages(out);
    const copy = {
      vi: { button: `Tải ${brand.name} 1.0.0`, dmgButton: `Tải ${brand.name} 1.0.0 (DMG)`, cta: "/tai-ve/" },
      en: { button: `Download ${brand.name} 1.0.0`, dmgButton: `Download ${brand.name} 1.0.0 (DMG)`, cta: "/en/download/" },
    };
    for (const lang of ["vi", "en"]) {
      const requirement = macosRequirement(lang, release.minimumSystemVersion);
      assert.match(requirement, /^macOS 12 Monterey /, `${lang}: the minimum is macOS 12`);
      const home = await read(p.home[lang]);
      const button = `<a class="btn" href="${release.dmgUrl}">${copy[lang].button}<small>${requirement}</small></a>`;
      assert.ok(section(home, "hero").includes(button), `${lang}: hero download button with version and minimum`);
      assert.ok(section(home, "closing").includes(button), `${lang}: closing download button`);
      assert.ok(section(home, "hero").includes(brew), `${lang}: hero brew line`);
      assert.ok(header(home).includes(`<a class="btn" href="${copy[lang].cta}">`), `${lang}: header download button`);
      assert.ok(!home.includes("btn-disabled"), `${lang}: no disabled state once released`);
      const download = await read(p.download[lang]);
      for (const fact of [`<dd>1.0.0 (1000099)</dd>`, `<dd>${formatDate(lang, release.date)}</dd>`, `<dd>${requirement}</dd>`, `<dd><code>${release.sha256}</code></dd>`,
        `<a class="btn" href="${release.dmgUrl}">${copy[lang].dmgButton}</a>`, `<code class="cmd">${brew}</code>`]) {
        assert.ok(download.includes(fact), `${lang} download page: ${fact}`);
      }
      assert.ok(!download.includes('<div class="callout">'), `${lang}: no no-release callout`);
    }
  });
}
