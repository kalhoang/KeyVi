// SPDX-License-Identifier: LicenseRef-App-Pending
// Page shell: head (canonical, hreflang, CSP), header, language switch, footer.
// Privacy by construction (PRD-R74): system fonts, one local stylesheet, no third-party anything.
import { esc } from "./util.mjs";
import { routePath } from "./routes.mjs";

const NAV_ORDER = ["download", "compat", "support", "privacy", "changelog"];

// Meta CSP is defence in depth; the real policy ships in static/_headers for hosts that support it.
const CSP =
  "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; " +
  "base-uri 'none'; form-action 'none'; object-src 'none'";

export function verifyBadge(lang, label = "VERIFY") {
  const hint = lang === "vi" ? "Cần xác minh trước khi công bố" : "Must be verified before publishing";
  return `<span class="verify" title="${esc(hint)}">${esc(label)}</span>`;
}

function absolute(ctx, path) {
  return `https://${ctx.brand.host}${path}`;
}

function alternates(ctx, page) {
  if (page.routeId === undefined) return "";
  const vi = routePath(page.routeId, "vi");
  const en = routePath(page.routeId, "en");
  return [
    `<link rel="alternate" hreflang="vi" href="${esc(absolute(ctx, vi))}">`,
    `<link rel="alternate" hreflang="en" href="${esc(absolute(ctx, en))}">`,
    `<link rel="alternate" hreflang="x-default" href="${esc(absolute(ctx, vi))}">`,
  ].join("\n  ");
}

function header(ctx, page) {
  const { ui, lang } = page;
  const home = routePath("home", lang);
  const otherPath = page.routeId === undefined ? page.otherLangPath : routePath(page.routeId, ui.langSwitch.lang);
  const current = page.navId;
  const links = NAV_ORDER.map((id) => {
    const attrs = id === current ? ' aria-current="page"' : "";
    return `<li><a href="${esc(routePath(id, lang))}"${attrs}>${esc(ui.nav[id])}</a></li>`;
  }).join("");
  return `<header class="site-header">
    <div class="wrap bar">
      <a class="brand" href="${esc(home)}">${esc(ctx.brand.name)}</a>
      <nav aria-label="${esc(ui.navLabel)}"><ul>${links}</ul></nav>
      <a class="lang-switch" href="${esc(otherPath)}" hreflang="${esc(ui.langSwitch.lang)}" lang="${esc(ui.langSwitch.lang)}" title="${esc(ui.langSwitch.title)}">${esc(ui.langSwitch.text)}</a>
    </div>
  </header>`;
}

// QA-R38 step 2, QA-R54: the incident or absence notice of site/config.json `banner`, on every page. Plain
// escaped text and a link, no script (PRD-R74).
function siteNotice(ctx, page) {
  const notice = ctx.config.banner;
  if (!notice?.enabled) return "";
  const { ui, lang } = page;
  const link = notice.link ? ` <a href="${esc(notice.link)}" rel="noopener">${esc(ui.notice.link)}</a>` : "";
  return `<aside class="site-notice" aria-label="${esc(ui.notice.label)}">
    <div class="wrap"><p>${esc(notice[lang])}${link}</p></div>
  </aside>`;
}

function footer(ctx, page) {
  const { ui, lang } = page;
  return `<footer class="site-footer">
    <div class="wrap">
      <p>${esc(ctx.brand.name)} &middot; ${esc(ui.footer.byline)}</p>
      <p>${esc(ui.footer.promise)}</p>
      <ul>
        <li><a href="${esc(routePath("privacy", lang))}">${esc(ui.nav.privacy)}</a></li>
        <li><a href="${esc(routePath("changelog", lang))}">${esc(ui.nav.changelog)}</a></li>
        <li><a href="${esc(ctx.config.githubRepo)}" rel="noopener">${esc(ui.footer.repo)}</a></li>
        <li><a href="/appcast.xml">${esc(ui.footer.appcast)}</a></li>
        <li><a href="${esc(routePath("donate", lang))}">${esc(ui.footer.donate)}</a></li>
      </ul>
    </div>
  </footer>`;
}

/**
 * @param {object} ctx build context
 * @param {object} page { lang, ui, routeId?, navId?, title, description, body, path, scripts?, otherLangPath?, robots? }
 */
export function renderDocument(ctx, page) {
  const { ui, lang } = page;
  const fullTitle = page.isHome ? page.title : `${page.title} · ${ctx.brand.name}`;
  const scripts = (page.scripts ?? []).map((src) => `<script src="${esc(src)}" defer></script>`).join("\n  ");
  const robots = page.robots ? `<meta name="robots" content="${esc(page.robots)}">\n  ` : "";
  const canonical = page.routeId === undefined ? "" : `<link rel="canonical" href="${esc(absolute(ctx, page.path))}">`;
  return `<!doctype html>
<html lang="${esc(lang)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="${esc(CSP)}">
  <meta name="color-scheme" content="light dark">
  <meta name="theme-color" content="#faf8f4" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#141513" media="(prefers-color-scheme: dark)">
  ${robots}<title>${esc(fullTitle)}</title>
  <meta name="description" content="${esc(page.description)}">
  <meta property="og:title" content="${esc(fullTitle)}">
  <meta property="og:description" content="${esc(page.description)}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="${esc(ctx.brand.name)}">
  ${canonical}
  ${alternates(ctx, page)}
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="${esc(ctx.assets.css)}">
  ${scripts}
</head>
<body>
  <a class="skip" href="#main">${esc(ui.skipLink)}</a>
  ${siteNotice(ctx, page)}
  ${header(ctx, page)}
  <main id="main" class="wrap">
${page.body}
  </main>
  ${footer(ctx, page)}
</body>
</html>
`;
}

