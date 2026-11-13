// SPDX-License-Identifier: LicenseRef-App-Pending
// Turns the deployed _headers file (dist/_headers of `node site/build.mjs`, Cloudflare Pages and Netlify format) into
// the nginx `location` blocks of the site container, so the container sends exactly the headers the file lists
// (ADR 0602). deploy/site/build.mjs runs it while the image is built; deploy/site/test.mjs proves the equivalence.
//
// Mapping. `/*` applies to every location. `/<prefix>/*` becomes `location ^~ /<prefix>/`, an exact path becomes
// `location = <path>`, and each block repeats every header whose pattern matches its path, because nginx drops the
// add_header directives of an outer level as soon as a location has its own. `Content-Type` becomes `types {}` plus
// `default_type` (add_header would send a second Content-Type). Every add_header uses `always`, so error pages carry
// the headers too. Values with `"`, `\`, `$` or control characters are refused: nginx would read `$` as a variable.
import { patternMatches } from "../../site/lib/headers.mjs";

const UNSAFE_VALUE = /["\\$\u0000-\u001f\u007f]/;
export const HEALTH_PATH = "/healthz";

function quote(value, label) {
  if (UNSAFE_VALUE.test(value)) throw new Error(`${label}: value cannot be written into nginx configuration: ${value}`);
  return `"${value}"`;
}

/** The location of a rule's pattern: `/` for `/*`, a `^~` prefix, or an exact match. */
export function locationOf(pattern) {
  if (pattern === "/*") return { modifier: "", path: "/" };
  if (pattern.endsWith("/*")) return { modifier: "^~", path: pattern.slice(0, -1) };
  return { modifier: "=", path: pattern };
}

/** A path that the location of `pattern` serves, used to decide which rules apply to the whole location. */
function representativePath(pattern) {
  return pattern.endsWith("/*") ? pattern.slice(0, -1) : pattern;
}

function headerLines(headers, label) {
  const lines = [];
  const contentTypes = headers.filter(([name]) => name.toLowerCase() === "content-type");
  if (contentTypes.length > 1) throw new Error(`${label}: more than one Content-Type`);
  for (const [name, value] of headers) {
    if (name.toLowerCase() === "content-type") continue;
    lines.push(`add_header ${name} ${quote(value, `${label} ${name}`)} always;`);
  }
  if (contentTypes.length === 1) lines.push("types { }", `default_type ${quote(contentTypes[0][1], `${label} Content-Type`)};`);
  return lines;
}

function block(location, lines) {
  const head = location.modifier ? `location ${location.modifier} ${location.path}` : `location ${location.path}`;
  return [`${head} {`, ...lines.map((line) => `    ${line}`), "}"].join("\n");
}

/**
 * nginx configuration for the server block: one location per rule plus `/` and the health check.
 * @param {ReadonlyArray<{pattern: string, headers: ReadonlyArray<[string, string]>}>} rules parsed _headers
 */
export function nginxLocations(rules) {
  const root = rules.find((rule) => rule.pattern === "/*");
  if (root?.headers.some(([name]) => name.toLowerCase() === "content-type")) throw new Error("_headers: Content-Type in the /* block");
  if (rules.some((rule) => rule.pattern === HEALTH_PATH)) throw new Error(`_headers: ${HEALTH_PATH} is reserved for the container health check`);
  const rootHeaders = root?.headers ?? [];
  const blocks = [block({ modifier: "", path: "/" }, [...headerLines(rootHeaders, "/*"), "try_files $uri $uri/ =404;"])];
  for (const rule of rules.filter((r) => r.pattern !== "/*")) {
    const path = representativePath(rule.pattern);
    const applying = rules.filter((other) => other === rule || (other.pattern.endsWith("/*") && patternMatches(other.pattern, path)));
    const headers = applying.flatMap((other) => other.headers);
    const fallback = rule.pattern.endsWith("/*") ? "try_files $uri $uri/ =404;" : "try_files $uri =404;";
    blocks.push(block(locationOf(rule.pattern), [...headerLines(headers, rule.pattern), fallback]));
  }
  blocks.push(block({ modifier: "=", path: HEALTH_PATH }, ["access_log off;", ...headerLines(rootHeaders, HEALTH_PATH), "default_type text/plain;", 'return 200 "ok\\n";']));
  return `# Generated from _headers by deploy/site/nginx-headers.mjs (ADR 0602). Do not edit; change site/static/_headers.\n${blocks.join("\n\n")}\n`;
}
