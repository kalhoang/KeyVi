// SPDX-License-Identifier: GPL-3.0-or-later
// Content-led pages: changelog, privacy, donate, 404. Each opens with the shared page head (lib/pages/head.mjs).
import { kit } from "../context.mjs";
import { renderMarkdown, slugifyHeading } from "../markdown.mjs";
import { routePath } from "../routes.mjs";
import { esc } from "../util.mjs";
import { pageHead } from "./head.mjs";

// A release heading of Keep a Changelog: `## [1.2.0] - 2026-12-01`, `## [1.3.0-beta.1] - ...`.
const RELEASE_HEADING = /^\[?v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\]?(?:\s|$)/;

/** Release headings get the id `v<version>`: each release-notes page links to #v<version> (ADR 0504). */
export function changelogHeadingId(depth, text) {
  const match = depth === 2 ? RELEASE_HEADING.exec(text.trim()) : null;
  return match ? `v${match[1]}` : undefined;
}

/**
 * Heading ids for one rendering of the changelog: release headings get `v<version>`, and a group heading under a
 * release (`### Fixed`) gets `v<version>-<slug>`, so the same group name in two releases does not repeat an id.
 * The returned function keeps the current release, so make a new one for each rendering.
 */
export function changelogHeadingIds() {
  let release;
  return (depth, text) => {
    const id = changelogHeadingId(depth, text);
    if (id) {
      release = id;
      return id;
    }
    return release && depth > 2 ? `${release}-${slugifyHeading(text)}` : undefined;
  };
}

/**
 * The part of a changelog visitors see: its release sections, in file order. The preamble (writing rules for
 * contributors) and the Unreleased section stay in the file; the page lists what shipped (spec/03-product.md section 16,
 * `/nhat-ky-thay-doi`: per release, date, channel and changes). Returns "" when no release has a section yet.
 */
export function releaseSections(markdown) {
  return markdown
    .split(/^(?=## )/m)
    .filter((section) => section.startsWith("## ") && RELEASE_HEADING.test(section.slice(3).trim()))
    .join("")
    .trimEnd();
}

export function renderChangelog(ctx, lang) {
  const { c, f, p, ui } = kit(ctx, lang);
  const m = c.changelog;
  // The page owns the h1. Brand tokens ({{AppName}}) are filled as plain text; the renderer escapes them.
  const source = releaseSections(p(ctx.data.changelog[lang]));
  const releases = source ? renderMarkdown(source, { baseLevel: 1, headingId: changelogHeadingIds() }) : `<p class="muted">${esc(m.empty)}</p>`;
  const body = `
    ${pageHead(esc(m.h1), esc(m.lede))}
    <div class="prose changelog">${releases}</div>
    <p class="muted prose">${f(m.donateLine)}</p>`;
  return { routeId: "changelog", navId: "changelog", title: p(ui.titles.changelog), description: p(ui.descriptions.changelog), body };
}

export function renderPrivacy(ctx, lang) {
  const { c, f, p, ui } = kit(ctx, lang);
  const m = c.privacy;
  // The website section states the analytics this build really ships (site/config.json `analytics`, ADR 0602).
  const analytics = ctx.config.analytics;
  const analyticsHtml = analytics.enabled ? f(m.analytics.umami, { analyticsOrigin: analytics.origin }) : m.analytics.off;
  const servedHtml = analytics.enabled ? m.served.umami : m.served.off;
  const body = `
    ${pageHead(esc(m.h1), esc(m.lede), `<p class="muted">${esc(m.updated)}</p>`)}
    <div class="prose">${f(m.html, { analyticsHtml, servedHtml })}</div>`;
  return { routeId: "privacy", navId: "privacy", title: p(ui.titles.privacy), description: p(ui.descriptions.privacy), body };
}

// A copy button that copy.js shows when the browser can copy. The visible text is the short "Copy"; the accessible name
// says what it copies, as the app's VoiceOver labels do, so the buttons differ in the Tab order (WCAG 2.5.3: the name
// starts with the visible text).
function copyButton(value, text, name, className) {
  return `<button type="button" class="${className}" data-copy="${esc(value)}" aria-label="${esc(name)}" hidden>${esc(text)}</button>`;
}

// One value of the account block: selectable text and its copy button.
function copyRow(label, value, copyText, copyName) {
  return `<dt>${esc(label)}</dt><dd><span data-copy-value>${esc(value)}</span>${copyButton(value, copyText, copyName, "btn btn-ghost btn-small")}</dd>`;
}

// The status line of a block with copy buttons: empty until copy.js writes data-copied into it (role=status announces it).
const copyStatus = (m) => `<p class="copy-status" role="status" data-copy-status data-copied="${esc(m.copied)}"></p>`;

/**
 * The donation block of the About pane, on the web (PRD-R59, Pa's decision S8, design 7.5): two columns, the copy left
 * and the bank VietQR code right (one column on phones). The bank name and the account number are shown, never the
 * holder's name: the payer's bank app shows it after the scan. No other payment method; GitHub Sponsors only once
 * site/config.json holds a real sponsor page. The copy and share buttons are hidden in the HTML and shown by copy.js
 * (no inline script under the CSP). The QR image is generated by scripts/make-vietqr.py.
 */
export function renderDonate(ctx, lang) {
  const { c, f, p, ui } = kit(ctx, lang);
  const m = c.donate;
  const shareText = p(m.shareText);
  // An empty sponsorsUrl means no sponsor page exists; a placeholder value is never linked either.
  const sponsorsUrl = ctx.config.placeholders.includes("sponsorsUrl") ? "" : ctx.config.sponsorsUrl;
  const sponsors = sponsorsUrl
    ? `
        <section class="card donate-block" aria-labelledby="donate-sponsors">
          <h2 id="donate-sponsors">${esc(m.sponsors.h)}</h2>
          <p>${esc(m.sponsors.body)}</p>
          <p><a class="btn" href="${esc(sponsorsUrl)}" rel="noopener">${esc(m.sponsors.link)}</a></p>
        </section>`
    : "";
  const body = `
    <div class="donate">
      <div class="donate-copy">
        ${pageHead(f(m.title), f(m.body))}
        <p>${f(m.howTo)}</p>
        <section class="card donate-block" aria-labelledby="donate-account" data-copy-scope>
          <h2 id="donate-account">${esc(m.accountTitle)}</h2>
          <dl class="facts copy-facts">${copyRow(m.bankLabel, m.bank, m.copy, m.copyLabels.bank)}${copyRow(m.accountLabel, m.account, m.copy, m.copyLabels.account)}</dl>
          ${copyStatus(m)}
        </section>
        <section class="card donate-block" aria-labelledby="donate-share" data-copy-scope>
          <h2 id="donate-share">${esc(m.shareTitle)}</h2>
          <p class="share-text" data-copy-value>${esc(shareText)}</p>
          <p class="donate-actions"><button type="button" class="btn" data-share="${esc(shareText)}" hidden>${esc(m.share)}</button>${copyButton(shareText, m.copy, m.copyLabels.shareText, "btn btn-ghost")}</p>
          ${copyStatus(m)}
        </section>${sponsors}
      </div>
      <figure class="card donate-qr">
        <img src="/assets/qr/vietqr.png" width="1024" height="1024" alt="${esc(m.qrAlt)}">
        <figcaption><strong>${esc(m.qrCaption)}</strong> ${esc(m.qrHow)}</figcaption>
      </figure>
    </div>`;
  return { routeId: "donate", navId: undefined, title: p(ui.titles.donate), description: p(ui.descriptions.donate), body, scripts: ["/assets/copy.js"] };
}

/** The 404 page is Vietnamese-first with an English line; it ships as /404.html. */
export function renderNotFound(ctx) {
  const vi = kit(ctx, "vi");
  const en = kit(ctx, "en");
  const body = `
    ${pageHead(esc(vi.ui.notFound.heading), esc(vi.ui.notFound.body))}
    <p class="actions"><a class="btn" href="${esc(routePath("home", "vi"))}">${esc(vi.ui.notFound.home)}</a>
       <a href="${esc(routePath("support", "vi"))}">${esc(vi.ui.notFound.support)}</a></p>
    <hr>
    <div lang="en">
      <h2>${esc(en.ui.notFound.heading)}</h2>
      <p>${esc(en.ui.notFound.body)}</p>
      <p><a href="${esc(routePath("home", "en"))}">${esc(en.ui.notFound.home)}</a> &middot;
         <a href="${esc(routePath("support", "en"))}">${esc(en.ui.notFound.support)}</a></p>
    </div>`;
  return {
    lang: "vi",
    routeId: undefined,
    path: "/404.html",
    otherLangPath: routePath("home", "en"),
    title: vi.ui.titles.notFound,
    description: vi.p(vi.ui.descriptions.home),
    body,
    robots: "noindex",
  };
}
