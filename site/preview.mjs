#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Local preview of a built site under its production headers (plan Task 9, design 7.9):
//   node site/build.mjs && node site/preview.mjs [--dir site/dist] [--port 4173]
// A static file server bound to 127.0.0.1 only. Every response carries the headers that dist/_headers gives its path
// (lib/headers.mjs reads the file deploy/site turns into the container's nginx configuration, ADR 0602), so a browser
// sees the production CSP. As in the container: a folder without its trailing slash redirects relatively, a missing
// file gets /404.html with that page's headers, and a Content-Type of _headers replaces the default one. Local use
// only: GET and HEAD, no TLS, no compression. No dependencies.
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { dirname, extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { headersForPath, parseHeaders } from "./lib/headers.mjs";

const HOST = "127.0.0.1";
const DEFAULT_PORT = 4173;
const SITE_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_DIR = join(SITE_DIR, "dist");
const NOT_FOUND_PAGE = "/404.html";
const CONTENT_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".js", "application/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml; charset=utf-8"],
  [".xml", "text/xml; charset=utf-8"],
  [".txt", "text/plain; charset=utf-8"],
  [".png", "image/png"],
  [".ico", "image/x-icon"],
]);

/** The headers of `urlPath` from the parsed _headers rules; a repeated name is sent once per value, as nginx does. */
function responseHeaders(rules, urlPath, file) {
  const headers = { "Content-Type": CONTENT_TYPES.get(extname(file)) ?? "application/octet-stream" };
  for (const [name, value] of headersForPath(rules, urlPath)) {
    if (name.toLowerCase() === "content-type") headers["Content-Type"] = value;
    else headers[name] = headers[name] === undefined ? value : [].concat(headers[name], value);
  }
  return headers;
}

/** The file a decoded URL path names inside `root`: `{ file }`, `{ redirect: true }` for a folder without its slash,
 * or `{}` when there is none (a path that leaves `root` included). */
async function resolveTarget(root, path) {
  if (!path.startsWith("/") || path.includes("\0")) return {};
  const full = resolve(root, `.${path}`);
  if (full !== root && !full.startsWith(root + sep)) return {};
  const info = await stat(full).catch(() => null);
  if (info?.isFile()) return { file: full };
  if (!info?.isDirectory()) return {};
  if (!path.endsWith("/")) return { redirect: true };
  const index = join(full, "index.html");
  return (await stat(index).catch(() => null))?.isFile() ? { file: index } : {};
}

async function send(req, res, status, headers, file) {
  const body = await readFile(file);
  res.writeHead(status, { ...headers, "Content-Length": body.length });
  res.end(req.method === "HEAD" ? undefined : body);
}

async function respond(root, rules, req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" });
    res.end("method not allowed\n");
    return;
  }
  const url = new URL(req.url ?? "/", `http://${HOST}`);
  let path;
  try {
    path = decodeURIComponent(url.pathname);
  } catch {
    path = "";
  }
  const target = path ? await resolveTarget(root, path) : {};
  if (target.redirect) {
    // The path's headers without a Content-Type: the redirect has an empty body, so it claims no type.
    const { "Content-Type": _none, ...headers } = responseHeaders(rules, url.pathname, "");
    res.writeHead(301, { ...headers, Location: `${url.pathname}/${url.search}` });
    res.end();
  } else if (target.file) {
    await send(req, res, 200, responseHeaders(rules, url.pathname, target.file), target.file);
  } else {
    const page = join(root, NOT_FOUND_PAGE);
    await send(req, res, 404, responseHeaders(rules, NOT_FOUND_PAGE, page), page);
  }
}

async function loadRules(root) {
  try {
    return parseHeaders(await readFile(join(root, "_headers"), "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`${join(root, "_headers")} not found: run node site/build.mjs first`);
    throw error;
  }
}

/**
 * Starts the preview server on 127.0.0.1.
 * @param {{ dir?: string, port?: number }} options the built site (default site/dist) and the port (0 picks a free one)
 * @returns {Promise<{ url: string, close: () => Promise<void> }>} the base URL without a trailing slash, and a close
 *   function that also ends idle keep-alive connections
 */
export async function startPreview({ dir = DEFAULT_DIR, port = DEFAULT_PORT } = {}) {
  const root = resolve(dir);
  const rules = await loadRules(root);
  const server = createServer((req, res) => {
    respond(root, rules, req, res).catch((error) => {
      console.error(`preview: ${req.method} ${req.url}: ${error.message}`);
      if (!res.headersSent) res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("internal error\n");
    });
  });
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(port, HOST, () => {
      server.off("error", reject);
      resolveListen();
    });
  });
  const close = () => new Promise((resolveClose, reject) => {
    server.close((error) => (error ? reject(error) : resolveClose()));
    server.closeAllConnections();
  });
  return { url: `http://${HOST}:${server.address().port}`, close };
}

function parseArgs(argv) {
  const options = { dir: DEFAULT_DIR, port: DEFAULT_PORT };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${arg} needs a value`);
      i += 1;
      return argv[i];
    };
    if (arg === "--dir") options.dir = resolve(value());
    else if (arg === "--port") {
      const port = Number(value());
      if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("--port must be a whole number from 0 to 65535");
      options.port = port;
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    const preview = await startPreview(options);
    console.log(`preview of ${options.dir} with its _headers at ${preview.url}/ (Ctrl+C stops it)`);
    const stop = () => preview.close().finally(() => process.exit(0));
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
  } catch (error) {
    console.error(`preview failed: ${error.message}`);
    process.exitCode = 1;
  }
}
