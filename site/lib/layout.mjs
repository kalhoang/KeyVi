// SPDX-License-Identifier: GPL-3.0-or-later
// Page shell: head (canonical, hreflang, CSP), the inline mark symbol, header, language switch, footer.
// Privacy by construction (PRD-R74): system fonts, local stylesheets, no third-party anything, except the
// optional cookieless Umami analytics of lib/analytics.mjs when site/config.json configures it (Pa, 2026-11-13, Q7).
// No style attribute or style element anywhere (design 4): the CSP allows stylesheets from the site only.
import { analyticsCspAdditions, analyticsScriptTag } from "./analytics.mjs";
import { fingerprintAssets } from "./fingerprint.mjs";
import { extendCsp } from "./headers.mjs";
import { esc } from "./util.mjs";
import { routePath } from "./routes.mjs";

// Header navigation after the features anchor of the home page; privacy and changelog live in the footer (design 7.3).
// The compatibility page is unlisted (routes.mjs, design 9 item 2), so no navigation links to it.
const NAV_ORDER = ["support"];
// The home section that lists the features: the header links to it from every page.
export const FEATURES_ANCHOR = Object.freeze({ vi: "tinh-nang", en: "features" });

// The KV mark of site/static/favicon.svg (Pa's artwork, CLR-R7), as a symbol that the header, the footer, the hero menu
// bar and the apps hub reuse. Attributes only: the letters take `color` and the dot takes `fill` from the referencing
// element, so CSS decides both (the dot is green when the input method is on).
const MARK_SYMBOL = `<svg class="sprite" width="0" height="0" aria-hidden="true" focusable="false">
    <symbol id="mark" viewBox="1.3 1.9 19.2 17.1">
      <g fill="currentColor">
        <rect x="1.8" y="6.5" width="2.3" height="12.0"/>
        <polygon points="7.0,6.5 9.6,6.5 4.1,13.2 4.1,10.3"/>
        <polygon points="5.0,11.4 6.9,10.2 10.0,18.5 7.4,18.5"/>
        <polygon points="11.2,6.5 13.7,6.5 16.7,18.5 14.5,18.5"/>
        <polygon points="17.5,6.5 20.0,6.5 16.7,18.5 14.5,18.5"/>
      </g>
      <circle cx="15.6" cy="4.3" r="1.9"/>
    </symbol>
  </svg>`;

/** The mark, decorative: the name or a label beside it says what it is. */
export function markSvg(className = "mark") {
  return `<svg class="${esc(className)}" width="28" height="25" aria-hidden="true" focusable="false"><use href="#mark"></use></svg>`;
}

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

const current = (page, id) => (page.navId === id ? ' aria-current="page"' : "");

function otherLanguagePath(page) {
  return page.routeId === undefined ? page.otherLangPath : routePath(page.routeId, page.ui.langSwitch.lang);
}

/** The header's download button, or its disabled state while there is no stable release (Review Focus 4). */
function downloadCta(ctx, page) {
  const { ui, lang } = page;
  if (!ctx.data.releases.stable) return `<span class="btn btn-disabled" aria-disabled="true">${esc(ui.common.noRelease)}</span>`;
  return `<a class="btn" href="${esc(routePath("download", lang))}"${current(page, "download")}>${esc(ui.nav.downloadCta)}</a>`;
}

function header(ctx, page) {
  const { ui, lang } = page;
  const home = routePath("home", lang);
  const features = `<li><a href="${esc(`${home}#${FEATURES_ANCHOR[lang]}`)}">${esc(ui.nav.features)}</a></li>`;
  const links = NAV_ORDER.map((id) => `<li><a href="${esc(routePath(id, lang))}"${current(page, id)}>${esc(ui.nav[id])}</a></li>`).join("");
  return `<header class="site-header">
    <div class="wrap bar">
      <a class="brand" href="${esc(home)}">${markSvg()}<span>${esc(ctx.brand.name)}</span></a>
      <nav class="site-nav" aria-label="${esc(ui.navLabel)}"><ul>${features}${links}</ul></nav>
      <div class="header-actions">
        ${downloadCta(ctx, page)}
        <a class="lang-switch" href="${esc(otherLanguagePath(page))}" hreflang="${esc(ui.langSwitch.lang)}" lang="${esc(ui.langSwitch.lang)}" title="${esc(ui.langSwitch.title)}">${esc(ui.langSwitch.text)}</a>
      </div>
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
  const { brand } = ctx;
  return `<footer class="site-footer">
    <div class="wrap footer-grid">
      <div class="footer-about">
        <p class="footer-name">${markSvg()}<span>${esc(brand.name + brand.trademarkSign)} &middot; ${esc(ui.footer.byline)}</span></p>
        <p>${esc(ui.footer.promise)}</p>
      </div>
      <ul class="footer-links">
        <li><a href="${esc(routePath("privacy", lang))}"${current(page, "privacy")}>${esc(ui.nav.privacy)}</a></li>
        <li><a href="${esc(routePath("changelog", lang))}"${current(page, "changelog")}>${esc(ui.nav.changelog)}</a></li>
        <li><a href="${esc(ctx.config.githubRepo)}" rel="noopener">${esc(ui.footer.repo)}</a></li>
        <li><a href="/appcast.xml">${esc(ui.footer.appcast)}</a></li>
        <li><a href="${esc(routePath("donate", lang))}"${current(page, "donate")}>${esc(ui.footer.donate)}</a></li>
        <li class="footer-lang">${esc(ui.footer.language)}: <a href="${esc(otherLanguagePath(page))}" hreflang="${esc(ui.langSwitch.lang)}" lang="${esc(ui.langSwitch.lang)}">${esc(ui.langSwitch.text)}</a></li>
      </ul>
    </div>
  </footer>`;
}

/**
 * @param {object} ctx build context
 * @param {object} page { lang, ui, routeId?, navId?, title, description, body, path, styles?, scripts?, otherLangPath?, robots? }
 *   styles: extra stylesheets after style.css; scripts: classic scripts, `defer`, in this order. Both fingerprinted.
 */
export function renderDocument(ctx, page) {
  const { ui, lang } = page;
  // Page titles carry the trademark sign (spec/03-product.md); the header and og:site_name keep the bare name.
  const fullTitle = page.isHome ? page.title : `${page.title} · ${ctx.brand.name}${ctx.brand.trademarkSign}`;
  const analytics = ctx.config.analytics;
  const styles = [ctx.assets.css, ...(page.styles ?? [])].map((href) => `<link rel="stylesheet" href="${esc(href)}">`).join("\n  ");
  const scripts = [...(page.scripts ?? []).map((src) => `<script src="${esc(src)}" defer></script>`), analyticsScriptTag(analytics, ctx.brand.host)].filter(Boolean).join("\n  ");
  const csp = extendCsp(CSP, analyticsCspAdditions(analytics));
  const robots = page.robots ? `<meta name="robots" content="${esc(page.robots)}">\n  ` : "";
  const canonical = page.routeId === undefined ? "" : `<link rel="canonical" href="${esc(absolute(ctx, page.path))}">`;
  const html = `<!doctype html>
<html lang="${esc(lang)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="${esc(csp)}">
  <meta name="color-scheme" content="light dark">
  <meta name="theme-color" content="#faf8f4" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#141619" media="(prefers-color-scheme: dark)">
  ${robots}<title>${esc(fullTitle)}</title>
  <meta name="description" content="${esc(page.description)}">
  <meta property="og:title" content="${esc(fullTitle)}">
  <meta property="og:description" content="${esc(page.description)}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="${esc(ctx.brand.name)}">
  ${canonical}
  ${alternates(ctx, page)}
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  ${styles}
  ${scripts}
</head>
<body>
  ${MARK_SYMBOL}
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
  return fingerprintAssets(html, ctx.assets.hashes);
}

