#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
// Tests of the site container (ADR 0602): `node deploy/site/test.mjs`. The central check builds the site the way the
// image does, reads the generated nginx locations back with nginx's own matching rules, and proves that every
// request path gets exactly the headers that _headers lists for it.
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { headersForPath, parseHeaders } from "../../site/lib/headers.mjs";
import { buildImageContent, resolveFlags } from "./build.mjs";
import { MISSING_PATH, checkLive, samplePaths } from "./check-live-headers.mjs";
import { HEALTH_PATH, nginxLocations } from "./nginx-headers.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
let passed = 0;
let failures = 0;

async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`ok   ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}\n     ${String(error.stack ?? error.message).split("\n").slice(0, 6).join("\n     ")}`);
  }
}

/** Tokens of an nginx configuration: words, quoted strings (unescaped), `{`, `}` and `;`; comments dropped. */
function tokenize(text) {
  const tokens = [];
  const pattern = /\s+|#[^\n]*|"((?:[^"\\]|\\.)*)"|([{};])|([^\s{};"#]+)/gy;
  let match;
  while (pattern.lastIndex < text.length && (match = pattern.exec(text))) {
    if (match[1] !== undefined) tokens.push({ word: match[1].replace(/\\(.)/g, (_, c) => (c === "n" ? "\n" : c)) });
    else if (match[2]) tokens.push({ punct: match[2] });
    else if (match[3]) tokens.push({ word: match[3] });
  }
  assert.equal(pattern.lastIndex, text.length, "the configuration tokenizes completely");
  return tokens;
}

/** Parses directives into a tree: { name, args: [], block?: [directives] }. */
function parseNginx(text) {
  const tokens = tokenize(text);
  let index = 0;
  const parseBlock = () => {
    const directives = [];
    while (index < tokens.length && tokens[index].punct !== "}") {
      const words = [];
      while (index < tokens.length && tokens[index].word !== undefined) words.push(tokens[index++].word);
      const punct = tokens[index++]?.punct;
      assert.ok(words.length > 0, "directive name");
      if (punct === ";") directives.push({ name: words[0], args: words.slice(1) });
      else if (punct === "{") {
        const block = parseBlock();
        assert.equal(tokens[index++]?.punct, "}", "closing brace");
        directives.push({ name: words[0], args: words.slice(1), block });
      } else assert.fail(`unexpected token after ${words.join(" ")}`);
    }
    return directives;
  };
  const tree = parseBlock();
  assert.equal(index, tokens.length, "no stray closing brace");
  return tree;
}

/** nginx location choice without regex locations: an exact `=` match, else the longest prefix (`^~` or plain). */
function chooseLocation(locations, path) {
  const exact = locations.find((l) => l.args[0] === "=" && l.args[1] === path);
  if (exact) return exact;
  const prefixes = locations.filter((l) => l.args[0] !== "=").map((l) => ({ l, prefix: l.args[0] === "^~" ? l.args[1] : l.args[0] }));
  return prefixes.filter(({ prefix }) => path.startsWith(prefix)).sort((a, b) => b.prefix.length - a.prefix.length)[0]?.l;
}

/** Headers nginx sends from a location: its add_header lines and, with `types { }`, the default_type. */
function locationHeaders(location) {
  const headers = location.block.filter((d) => d.name === "add_header").map((d) => {
    assert.equal(d.args[2], "always", `add_header ${d.args[0]} uses always`);
    return [d.args[0], d.args[1]];
  });
  const emptyTypes = location.block.some((d) => d.name === "types" && d.block.length === 0);
  const defaultType = location.block.find((d) => d.name === "default_type");
  if (emptyTypes && defaultType) headers.push(["Content-Type", defaultType.args[0]]);
  return headers;
}

const sorted = (headers) => headers.map(([n, v]) => `${n.toLowerCase()}: ${v}`).sort();

/** Paths to compare: fixed examples, every pattern's own path and one level below each prefix. */
function samplePathsFor(rules) {
  const paths = new Set(["/", "/tai-ve/", "/en/download/", "/404.html", "/robots.txt", "/favicon.svg", "/appcast.xml", "/assets/style.css", "/assets/qr/vietqr.svg", "/download/app-1.0.0.dmg", "/release-notes/1.0.0/", "/release-notes/1.0.0/index.html"]);
  for (const rule of rules) {
    const base = rule.pattern.endsWith("/*") ? rule.pattern.slice(0, -1) : rule.pattern;
    paths.add(base);
    if (rule.pattern.endsWith("/*")) paths.add(`${base}nested/file.txt`);
  }
  return [...paths];
}

function assertEquivalent(rules, locationsText, label) {
  const locations = parseNginx(locationsText).filter((d) => d.name === "location");
  for (const path of samplePathsFor(rules)) {
    const location = chooseLocation(locations, path);
    assert.ok(location, `${label}: no location serves ${path}`);
    assert.deepEqual(sorted(locationHeaders(location)), sorted(headersForPath(rules, path)), `${label}: headers of ${path}`);
  }
  const health = locations.find((l) => l.args[0] === "=" && l.args[1] === HEALTH_PATH);
  assert.ok(health, "health check location");
  assert.deepEqual(health.block.find((d) => d.name === "return").args, ["200", "ok\n"]);
}

const tmp = await mkdtemp(join(tmpdir(), "site-image-test-"));
try {
  const plain = join(tmp, "plain");
  const plainResult = await buildImageContent({ outDir: plain, strict: "false", today: "2026-11-13" });

  await check("image content: html without _headers, nginx/_headers and the locations generated from it", async () => {
    assert.ok(plainResult.pageCount > 20);
    const html = await readdir(join(plain, "html"));
    assert.ok(html.includes("index.html") && html.includes("appcast.xml"));
    assert.ok(!html.includes("_headers"), "_headers is configuration, never served");
    const headers = await readFile(join(plain, "nginx", "_headers"), "utf8");
    assert.equal(await readFile(join(plain, "nginx", "locations.conf"), "utf8"), nginxLocations(parseHeaders(headers)));
  });

  await check("every request path gets exactly the headers of _headers (the built site, preview)", async () => {
    const rules = parseHeaders(await readFile(join(plain, "nginx", "_headers"), "utf8"));
    assert.ok(headersForPath(rules, "/").some(([name, value]) => name === "X-Robots-Tag" && value === "noindex"), "a non-strict build is a noindex preview");
    assertEquivalent(rules, await readFile(join(plain, "nginx", "locations.conf"), "utf8"), "preview");
  });

  await check("every request path gets exactly the headers of _headers (analytics on, indexable)", async () => {
    const configPath = join(tmp, "config.json");
    const base = JSON.parse(await readFile(join(HERE, "..", "..", "site", "config.json"), "utf8"));
    await writeFile(configPath, JSON.stringify({ ...base, analytics: { posthogKey: "phc_TestProjectKey0123456789abcdef", posthogHost: "https://eu.i.posthog.com" } }));
    const out = join(tmp, "analytics");
    const result = await buildImageContent({ outDir: out, strict: "false", noindex: "false", today: "2026-11-13", configPath });
    assert.equal(result.noindex, false);
    const rules = parseHeaders(await readFile(join(out, "nginx", "_headers"), "utf8"));
    assert.ok(!headersForPath(rules, "/").some(([name]) => name === "X-Robots-Tag"));
    assert.match(headersForPath(rules, "/").find(([name]) => name === "Content-Security-Policy")[1], /connect-src 'self' https:\/\/eu\.i\.posthog\.com/);
    assertEquivalent(rules, await readFile(join(out, "nginx", "locations.conf"), "utf8"), "analytics");
  });

  await check("nested prefixes and exact paths inside a prefix keep every matching block", () => {
    const rules = parseHeaders("/*\n  A: 1\n/a/*\n  B: 2\n/a/b/*\n  C: 3\n/a/x.txt\n  D: 4\n  Content-Type: text/plain; charset=utf-8\n/y.xml\n  E: 5\n");
    assertEquivalent(rules, nginxLocations(rules), "synthetic");
    assert.deepEqual(sorted(headersForPath(rules, "/a/b/c")), sorted([["A", "1"], ["B", "2"], ["C", "3"]]));
  });

  await check("values nginx would misread, Content-Type for every path and the health path are refused", () => {
    for (const [text, message] of [
      ["/*\n  A: $host\n", /cannot be written/],
      ['/*\n  A: say "hi"\n', /cannot be written/],
      ["/*\n  Content-Type: text/plain\n", /Content-Type in the \/\* block/],
      ["/x\n  Content-Type: a\n  Content-Type: b\n", /more than one Content-Type/],
      [`${HEALTH_PATH}\n  A: 1\n`, /reserved/],
    ]) assert.throws(() => nginxLocations(parseHeaders(text)), message, text);
  });

  await check("build flags: strict by default, a preview is noindex unless asked otherwise", async () => {
    assert.deepEqual(resolveFlags(), { strict: true, noindex: false });
    assert.deepEqual(resolveFlags("false"), { strict: false, noindex: true });
    assert.deepEqual(resolveFlags("false", "false"), { strict: false, noindex: false });
    assert.deepEqual(resolveFlags("true", "true"), { strict: true, noindex: true });
    assert.deepEqual(resolveFlags("false", ""), { strict: false, noindex: true }, "an empty build arg means auto");
    assert.throws(() => resolveFlags("yes"), /--strict/);
    assert.throws(() => resolveFlags("true", "maybe"), /--noindex/);
    const configPath = join(tmp, "placeholder.json");
    await writeFile(configPath, JSON.stringify({ githubRepo: "https://github.com/OWNER/REPO" }));
    await assert.rejects(() => buildImageContent({ outDir: join(tmp, "strict"), strict: "true", today: "2026-11-13", configPath }), /--strict/);
  });

  await check("release files are copied into /download/, hidden files are not", async () => {
    const downloads = join(tmp, "downloads");
    await mkdir(downloads);
    await writeFile(join(downloads, "app-1.0.0.dmg"), "dmg");
    await writeFile(join(downloads, ".gitignore"), "*\n");
    const out = join(tmp, "with-downloads");
    const result = await buildImageContent({ outDir: out, strict: "false", today: "2026-11-13", downloadsDir: downloads });
    assert.deepEqual(result.downloads, ["app-1.0.0.dmg"]);
    assert.deepEqual(await readdir(join(out, "html", "download")), ["app-1.0.0.dmg"]);
    await mkdir(join(downloads, "nested"));
    await assert.rejects(() => buildImageContent({ outDir: out, strict: "false", today: "2026-11-13", downloadsDir: downloads }), /not a regular file/);
    const none = await buildImageContent({ outDir: join(tmp, "no-downloads"), strict: "false", today: "2026-11-13", downloadsDir: join(tmp, "absent") });
    assert.deepEqual(none.downloads, []);
  });

  await check("nginx.conf: unprivileged port, generated locations, relative redirects, a log without client data", async () => {
    const tree = parseNginx(await readFile(join(HERE, "nginx.conf"), "utf8"));
    const http = tree.find((d) => d.name === "http").block;
    const server = http.find((d) => d.name === "server").block;
    const value = (block, name) => block.find((d) => d.name === name)?.args;
    assert.deepEqual(value(server, "listen"), ["8080", "default_server"]);
    assert.deepEqual(value(server, "include"), ["/etc/nginx/site/locations.conf"]);
    assert.deepEqual(value(server, "absolute_redirect"), ["off"]);
    assert.deepEqual(value(server, "error_page"), ["404", "/404.html"]);
    assert.deepEqual(value(server, "root"), ["/srv/site"]);
    assert.ok(!server.some((d) => d.name === "add_header" || d.name === "location"), "headers and locations come only from the generated file");
    assert.deepEqual(value(http, "server_tokens"), ["off"]);
    assert.ok(!value(http, "charset_types").includes("application/rss+xml"), "the appcast keeps the Content-Type of _headers");
    const format = http.find((d) => d.name === "log_format");
    assert.equal(format.args[0], "privacy");
    assert.deepEqual(value(http, "access_log"), ["/dev/stdout", "privacy"]);
    for (const variable of ["$remote_addr", "$http_x_forwarded_for", "$http_user_agent", "$http_referer", "$request ", "$request_uri", "$args", "$query_string"]) {
      assert.ok(!`${format.args.slice(1).join(" ")} `.includes(variable), `the access log never writes ${variable.trim()}`);
    }
    assert.equal(value(tree, "pid")[0], "/tmp/nginx.pid", "writable under a read-only root file system");
  });

  await check("live check: a server with the headers of _headers passes, a missing header fails", async () => {
    const rules = parseHeaders(await readFile(join(plain, "nginx", "_headers"), "utf8"));
    const locations = parseNginx(nginxLocations(rules)).filter((d) => d.name === "location");
    const files = ["/index.html", "/appcast.xml", "/assets/style.css", "/release-notes/1.0.0/index.html"];
    const { samples, skipped } = samplePaths(rules, files);
    assert.deepEqual(samples.map((s) => s.path), ["/", MISSING_PATH, "/appcast.xml", "/assets/style.css", "/release-notes/1.0.0/"]);
    assert.deepEqual(skipped, ["/download/*"]);
    let broken = false;
    const server = createServer((request, response) => {
      const path = new URL(request.url, "http://x").pathname;
      const known = path === "/" || files.includes(path) || files.includes(`${path}index.html`);
      const location = known ? chooseLocation(locations, path) : chooseLocation(locations, "/404.html");
      for (const [name, value] of locationHeaders(location)) {
        if (broken && path.startsWith("/assets/") && name === "Strict-Transport-Security") continue;
        response.appendHeader(name, value);
      }
      response.statusCode = known ? 200 : 404;
      response.end("x");
    });
    await new Promise((done) => server.listen(0, "127.0.0.1", done));
    try {
      const base = `http://127.0.0.1:${server.address().port}`;
      const good = await checkLive(base, rules, files);
      assert.deepEqual(good.problems, []);
      assert.equal(good.checked, 5);
      broken = true;
      const bad = await checkLive(base, rules, files);
      assert.deepEqual(bad.problems, ["/assets/style.css (200): missing Strict-Transport-Security"]);
    } finally {
      server.close();
    }
  });
} finally {
  await rm(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failures} failed`);
process.exitCode = failures === 0 ? 0 : 1;
