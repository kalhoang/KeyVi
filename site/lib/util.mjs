// SPDX-License-Identifier: GPL-3.0-or-later
// Small shared helpers for the static site generator. No dependencies.
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const HTML_ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escape text for use in HTML text nodes and attribute values. */
export function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => HTML_ESCAPES[ch]);
}

/**
 * Replace {{Token}} placeholders with HTML-escaped values. Tokens whose name ends in "Html" carry
 * trusted markup and are inserted as is. Unknown tokens are left untouched so a typo is visible in
 * the output (and caught by the test).
 */
export function interp(template, tokens) {
  return String(template).replace(/\{\{([A-Za-z][A-Za-z0-9]*)\}\}/g, (match, name) => {
    if (!Object.hasOwn(tokens, name)) return match;
    return name.endsWith("Html") ? String(tokens[name]) : esc(tokens[name]);
  });
}

export async function readJsonIfExists(path) {
  if (!existsSync(path)) return undefined;
  const text = await readFile(path, "utf8");
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new Error(`Invalid JSON in ${path}: ${error.message}`);
  }
}

export async function readTextIfExists(path) {
  return existsSync(path) ? readFile(path, "utf8") : undefined;
}

export async function writeFileDeep(path, content) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, content);
}

export function shortHash(content) {
  return createHash("sha256").update(content).digest("hex").slice(0, 10);
}

/** Version compare for dotted numeric versions with optional "-pre" suffix; returns <0, 0, >0. */
export function compareVersions(a, b) {
  const split = (v) => {
    const [core, pre = ""] = String(v).split("-", 2);
    return { nums: core.split(".").map((n) => Number.parseInt(n, 10) || 0), pre };
  };
  const left = split(a);
  const right = split(b);
  const length = Math.max(left.nums.length, right.nums.length);
  for (let i = 0; i < length; i += 1) {
    const diff = (left.nums[i] ?? 0) - (right.nums[i] ?? 0);
    if (diff !== 0) return diff;
  }
  if (left.pre === right.pre) return 0;
  if (left.pre === "") return 1; // a release outranks its pre-release
  if (right.pre === "") return -1;
  return left.pre < right.pre ? -1 : 1;
}
