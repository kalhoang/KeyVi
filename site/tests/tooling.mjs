// SPDX-License-Identifier: GPL-3.0-or-later
// The preview server, the vendored anime.js and the SPDX headers of site/.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { parseHeaders } from "../lib/headers.mjs";
import { SITE_DIR, ROOT_DIR, walk, cspOf } from "./helpers.mjs";

/** Tooling and repository checks. */
export async function runToolingChecks(check, fixtures) {
  const { fallback } = fixtures;

  await check("preview: serves the production CSP header for / and immutable caching for /assets/", async () => {
    // site/preview.mjs (plan Task 9): the browser pass sees the headers of dist/_headers, as the container sends them.
    const { startPreview } = await import(pathToFileURL(join(SITE_DIR, "preview.mjs")).href);
    const rules = parseHeaders(await readFile(join(fallback, "_headers"), "utf8"));
    const preview = await startPreview({ dir: fallback, port: 0 });
    // A raw request, so the path reaches the server as written (fetch would resolve the dot segments itself).
    const raw = (path) => new Promise((resolveGet, reject) => {
      const { hostname, port } = new URL(preview.url);
      const request = httpRequest({ hostname, port, path, method: "GET", agent: false }, (response) => {
        response.resume();
        response.on("end", () => resolveGet(response));
      });
      request.on("error", reject);
      request.end();
    });
    try {
      assert.match(preview.url, /^http:\/\/127\.0\.0\.1:\d+$/, "bound to the loopback address only");
      const home = await fetch(`${preview.url}/`);
      assert.equal(home.status, 200);
      assert.match(home.headers.get("content-type") ?? "", /^text\/html/);
      assert.equal(home.headers.get("content-security-policy"), cspOf(rules, "/")[0], "the production CSP of dist/_headers");
      assert.equal(home.headers.get("x-frame-options"), "DENY");
      assert.equal(home.headers.get("cache-control"), null, "pages are not cached for a year");
      const html = await home.text();
      const css = html.match(/href="(\/assets\/style\.css\?v=[0-9a-f]{10})"/)?.[1];
      assert.ok(css, "the home page links its fingerprinted stylesheet");
      const asset = await fetch(`${preview.url}${css}`);
      assert.equal(asset.status, 200);
      assert.match(asset.headers.get("content-type") ?? "", /^text\/css/);
      assert.equal(asset.headers.get("cache-control"), "public, max-age=31536000, immutable");
      assert.equal(await asset.text(), await readFile(join(fallback, "assets", "style.css"), "utf8"));
      const appcast = await fetch(`${preview.url}/appcast.xml`);
      assert.equal(appcast.headers.get("content-type"), "application/rss+xml; charset=utf-8", "a Content-Type of _headers replaces the default");
      const folder = await fetch(`${preview.url}/tai-ve`, { redirect: "manual" });
      assert.deepEqual([folder.status, folder.headers.get("location")], [301, "/tai-ve/"], "a folder without its slash redirects, relatively");
      assert.equal(folder.headers.get("content-type"), null, "the empty redirect body claims no type");
      assert.equal(folder.headers.get("content-security-policy"), cspOf(rules, "/tai-ve")[0], "the redirect keeps the path's headers");
      const missing = await fetch(`${preview.url}/assets/nope.css`);
      assert.equal(missing.status, 404);
      assert.match(await missing.text(), /<html lang="vi">/, "the 404 page");
      assert.equal(missing.headers.get("cache-control"), null, "the 404 page carries its own headers, not the asset's");
      for (const path of ["/../test.mjs", "/%2e%2e/test.mjs", "/assets/%2e%2e/%2e%2e/build.mjs"]) assert.equal((await raw(path)).statusCode, 404, `${path} stays inside the site`);
      // The paths above are collapsed by the URL parser before resolveTarget sees them. Encoded slashes are not: this
      // one decodes to /../config-no-analytics.json, a real file next to the site folder, and only the root check of
      // resolveTarget keeps it out.
      assert.ok(existsSync(join(fallback, "..", "config-no-analytics.json")), "the file outside the site exists");
      assert.equal((await raw("/%2e%2e%2fconfig-no-analytics.json")).statusCode, 404, "an encoded-slash path stays inside the site");
    } finally {
      await preview.close();
    }
  });

  await check("vendor: anime.js 4.5.0 is vendored byte-exact with its licence (ADR 0603)", async () => {
    const vendor = join(SITE_DIR, "static", "assets", "vendor");
    const bundle = await readFile(join(vendor, "anime.umd.min.js"));
    assert.ok(bundle.toString("utf8").startsWith("/**\n * Anime.js - UMD minified bundle\n * @version v4.5.0"), "the UMD bundle of anime.js 4.5.0");
    const notices = await readFile(join(ROOT_DIR, "THIRD_PARTY_NOTICES.md"), "utf8");
    const entry = notices.split("\n### anime.js 4.5.0\n")[1]?.split(/\n##/)[0] ?? "";
    const recorded = entry.match(/SHA-256[^\n]*`([0-9a-f]{64})`/)?.[1];
    assert.ok(recorded, "THIRD_PARTY_NOTICES.md section 5 records the SHA-256 of the vendored file in its anime.js entry");
    assert.equal(createHash("sha256").update(bundle).digest("hex"), recorded, "the vendored file is the one the notice names");
    assert.match(await readFile(join(vendor, "anime.LICENSE.txt"), "utf8"), /Julian Garnier/);
  });

  await check("every source file carries an SPDX header", async () => {
    // Third-party files vendored byte-exact keep their own header; THIRD_PARTY_NOTICES.md records them (ADR 0603).
    const vendor = join(SITE_DIR, "static", "assets", "vendor") + "/";
    const files = (await walk(SITE_DIR)).filter((f) => /\.(mjs|js|css)$/.test(f) && !f.includes(`${SITE_DIR}/dist`) && !f.startsWith(vendor));
    const missing = [];
    for (const file of files) if (!(await readFile(file, "utf8")).slice(0, 400).includes("SPDX-License-Identifier: GPL-3.0-or-later")) missing.push(file.slice(SITE_DIR.length + 1));
    assert.deepEqual(missing, []);
  });
}
