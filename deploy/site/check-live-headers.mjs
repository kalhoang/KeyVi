#!/usr/bin/env node
// SPDX-License-Identifier: LicenseRef-App-Pending
// Asks a running site container for one file of every _headers pattern and checks that each response carries every
// header the file lists for that path, with the same value (ADR 0602). site-image.yml runs it against the freshly
// built image before anything is pushed.
//   node deploy/site/check-live-headers.mjs --base http://127.0.0.1:8080 --headers _headers --files files.txt
// --files lists the paths the image serves, one per line (`/index.html`, `/assets/style.css`, ...); a pattern with
// no served file is reported and skipped. A path that does not exist and the bare directory of each prefix pattern are
// also asked for: they must answer 404 with the site-wide headers. Exit status 0 when every header matches, 1 otherwise.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { headersForPath, parseHeaders, patternMatches } from "../../site/lib/headers.mjs";

export const MISSING_PATH = "/this-page-does-not-exist/";

/** The URL path a served file is requested under: `/a/index.html` is asked for as `/a/`. */
function requestPath(file) {
  return file.endsWith("/index.html") ? file.slice(0, -"index.html".length) : file;
}

/**
 * One request per pattern (the first served file it matches), the site root, a missing page, and the bare directory
 * of every prefix pattern without an index page, which must answer the 404 page (nginx.conf maps 403 to it).
 */
export function samplePaths(rules, files) {
  const served = files.map((f) => f.trim()).filter((f) => f.startsWith("/")).sort();
  const samples = [{ path: "/", status: 200 }, { path: MISSING_PATH, status: 404 }];
  const skipped = [];
  for (const rule of rules.filter((r) => r.pattern !== "/*")) {
    const file = served.find((f) => patternMatches(rule.pattern, f));
    if (file) samples.push({ path: requestPath(file), status: 200 });
    else skipped.push(rule.pattern);
    const directory = rule.pattern.endsWith("/*") ? rule.pattern.slice(0, -1) : null;
    if (directory && !served.includes(`${directory}index.html`)) samples.push({ path: directory, status: 404 });
  }
  return { samples, skipped };
}

/** Compares a response's headers with the expected [name, value] pairs; returns the problems found. */
export function compareHeaders(expected, actual, label) {
  const problems = [];
  const byName = new Map();
  for (const [name, value] of expected) {
    const entry = byName.get(name.toLowerCase()) ?? { name, values: [] };
    byName.set(name.toLowerCase(), { name: entry.name, values: [...entry.values, value] });
  }
  for (const { name, values } of byName.values()) {
    const got = actual.get(name);
    if (got === null) problems.push(`${label}: missing ${name}`);
    else if (got !== values.join(", ")) problems.push(`${label}: ${name} is "${got}", expected "${values.join(", ")}"`);
  }
  return problems;
}

/** Runs every sample against `base`. Returns { problems, skipped, checked }. */
export async function checkLive(base, rules, files) {
  const { samples, skipped } = samplePaths(rules, files);
  const problems = [];
  for (const sample of samples) {
    const response = await fetch(new URL(sample.path, base), { redirect: "manual" });
    await response.arrayBuffer();
    const label = `${sample.path} (${response.status})`;
    if (response.status !== sample.status) problems.push(`${label}: expected status ${sample.status}`);
    // A missing page is answered by the 404 page through the site-wide location.
    const expected = sample.status === 404 ? headersForPath(rules.filter((r) => r.pattern === "/*"), sample.path) : headersForPath(rules, sample.path);
    problems.push(...compareHeaders(expected, response.headers, label));
  }
  return { problems, skipped, checked: samples.length };
}

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!["--base", "--headers", "--files"].includes(argv[i]) || i + 1 >= argv.length) throw new Error(`usage: --base URL --headers FILE --files FILE (got ${argv[i]})`);
    options[argv[i].slice(2)] = argv[i + 1];
  }
  if (!options.base || !options.headers || !options.files) throw new Error("usage: --base URL --headers FILE --files FILE");
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const rules = parseHeaders(await readFile(options.headers, "utf8"));
    const files = (await readFile(options.files, "utf8")).split("\n");
    const { problems, skipped, checked } = await checkLive(options.base, rules, files);
    for (const pattern of skipped) console.log(`note: no served file matches ${pattern}; not checked`);
    for (const problem of problems) console.error(`FAIL ${problem}`);
    console.log(`${checked} response(s) checked, ${problems.length} problem(s)`);
    process.exitCode = problems.length === 0 ? 0 : 1;
  } catch (error) {
    console.error(`check-live-headers: ${error.message}`);
    process.exitCode = 1;
  }
}
