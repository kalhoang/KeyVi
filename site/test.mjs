#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Tiny test script: `node site/test.mjs`. Builds into temp dirs (fallback data and populated fixtures) once and runs
// the check modules of site/tests/ in order: pages, internal links and anchors, language attributes, privacy rules
// (PRD-R74), appcast and sitemap XML, the home page and its motion, copy, donate page, tooling and the release gate
// (strict builds of the shipped config before and after the first release).
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runCopyChecks } from "./tests/copy.mjs";
import { runDataChecks } from "./tests/data.mjs";
import { buildFixtures } from "./tests/fixtures.mjs";
import { runHomeChecks } from "./tests/home.mjs";
import { runMotionChecks } from "./tests/motion.mjs";
import { runReleaseChecks } from "./tests/release.mjs";
import { runShellChecks } from "./tests/shell.mjs";
import { runToolingChecks } from "./tests/tooling.mjs";

const MODULES = [runDataChecks, runShellChecks, runHomeChecks, runMotionChecks, runCopyChecks, runToolingChecks, runReleaseChecks];
let failures = 0;
let passed = 0;

async function check(name, fn) {
  try {
    await fn();
    passed += 1;
    console.log(`ok   ${name}`);
  } catch (error) {
    failures += 1;
    console.error(`FAIL ${name}\n     ${error.message.split("\n").join("\n     ")}`);
  }
}

const tmp = await mkdtemp(join(tmpdir(), "site-test-"));
try {
  const fixtures = await buildFixtures(tmp);
  for (const run of MODULES) await run(check, fixtures);
} finally {
  await rm(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} passed, ${failures} failed`);
process.exitCode = failures === 0 ? 0 : 1;
