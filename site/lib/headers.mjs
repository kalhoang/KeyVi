// SPDX-License-Identifier: GPL-3.0-or-later
// The `_headers` file (Cloudflare Pages and Netlify format): a path pattern on its own line, then indented
// `Name: value` lines. site/static/_headers is the single source of the website's response headers; the build
// adapts it (analytics origins in the CSP, the preview's noindex) and deploy/site turns the result into nginx
// configuration (ADR 0602). Only the two pattern forms the site uses are accepted: an exact path (`/appcast.xml`)
// and a prefix ending in `/*` (`/assets/*`, `/*` for every response).

const HEADER_NAME = /^[A-Za-z0-9-]+$/;
const EXACT_PATH = /^\/[A-Za-z0-9._~\/-]*$/;

/** True for a pattern this parser accepts: `/*`, `/<prefix>/*` or an exact path without wildcards. */
export function isSupportedPattern(pattern) {
  if (pattern === "/*") return true;
  if (pattern.endsWith("/*")) return EXACT_PATH.test(pattern.slice(0, -1)) && pattern.slice(0, -1).endsWith("/");
  return EXACT_PATH.test(pattern) && !pattern.includes("*");
}

/** Parses the file into frozen rules `{ pattern, headers: [[name, value], ...] }` in file order. */
export function parseHeaders(text) {
  const rules = [];
  String(text).split("\n").forEach((raw, index) => {
    const line = raw.replace(/\r$/, "");
    if (line.trim() === "" || line.trimStart().startsWith("#")) return;
    const where = `_headers line ${index + 1}`;
    if (!/^\s/.test(line)) {
      const pattern = line.trim();
      if (!isSupportedPattern(pattern)) throw new Error(`${where}: unsupported path pattern "${pattern}"`);
      if (rules.some((rule) => rule.pattern === pattern)) throw new Error(`${where}: duplicate pattern "${pattern}"`);
      rules.push({ pattern, headers: [] });
      return;
    }
    const match = line.trim().match(/^([^:\s]+):\s*(.*)$/);
    if (!match || !HEADER_NAME.test(match[1])) throw new Error(`${where}: expected "Name: value"`);
    if (rules.length === 0) throw new Error(`${where}: header before the first path pattern`);
    if (match[2].trim() === "") throw new Error(`${where}: empty value for ${match[1]}`);
    rules.at(-1).headers.push([match[1], match[2].trim()]);
  });
  return Object.freeze(rules.map((rule) => Object.freeze({ pattern: rule.pattern, headers: Object.freeze(rule.headers) })));
}

/** Writes rules back in the same format. */
export function serializeHeaders(rules, comment = "") {
  const head = comment ? comment.split("\n").map((line) => `# ${line}`.trimEnd()).join("\n") + "\n" : "";
  return head + rules.map((rule) => [rule.pattern, ...rule.headers.map(([name, value]) => `  ${name}: ${value}`)].join("\n")).join("\n\n") + "\n";
}

/** True when the rule's pattern applies to the request path (the `/*` rule applies to every path). */
export function patternMatches(pattern, path) {
  return pattern.endsWith("/*") ? path.startsWith(pattern.slice(0, -1)) : path === pattern;
}

/** Every header that applies to a request path, in rule order then line order (hosts send all of them). */
export function headersForPath(rules, path) {
  return rules.filter((rule) => patternMatches(rule.pattern, path)).flatMap((rule) => rule.headers);
}

/** Adds sources to directives of a CSP value; a missing directive starts from `'self'`. Returns the new value. */
export function extendCsp(policy, additions) {
  const directives = policy.split(";").map((part) => part.trim()).filter(Boolean);
  for (const [name, sources] of Object.entries(additions)) {
    if (sources.length === 0) continue;
    const index = directives.findIndex((d) => d.split(/\s+/)[0] === name);
    if (index === -1) directives.push([name, "'self'", ...sources].join(" "));
    else directives[index] = [directives[index], ...sources.filter((s) => !directives[index].split(/\s+/).includes(s))].join(" ");
  }
  return directives.join("; ");
}

/**
 * The deployed header set: the `/*` rule's CSP gains the analytics origins (only there: the stricter
 * `/release-notes/*` policy stays as written) and, for a preview, `X-Robots-Tag: noindex` on every response.
 * @param {object} options { cspAdditions?: {directive: [source]}, noindex?: boolean }
 */
export function adaptHeaders(rules, options = {}) {
  const additions = options.cspAdditions ?? {};
  const adapted = rules.map((rule) => {
    if (rule.pattern !== "/*") return rule;
    const headers = rule.headers.map(([name, value]) => (name.toLowerCase() === "content-security-policy" ? [name, extendCsp(value, additions)] : [name, value]));
    if (options.noindex) headers.push(["X-Robots-Tag", "noindex"]);
    return { pattern: rule.pattern, headers };
  });
  if (options.noindex && !rules.some((rule) => rule.pattern === "/*")) adapted.unshift({ pattern: "/*", headers: [["X-Robots-Tag", "noindex"]] });
  return adapted;
}
