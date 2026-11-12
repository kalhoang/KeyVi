// SPDX-License-Identifier: LicenseRef-App-Pending
// Content-led pages: changelog, privacy, donate, 404.
import { kit } from "../context.mjs";
import { renderMarkdown } from "../markdown.mjs";
import { routePath } from "../routes.mjs";
import { esc } from "../util.mjs";

export function renderChangelog(ctx, lang) {
  const { c, f, p, ui } = kit(ctx, lang);
  const m = c.changelog;
  const source = ctx.data.changelog[lang].replace(/^\s*#\s[^\n]*\n/, ""); // the page owns the h1
  const body = `
    <h1>${esc(m.h1)}</h1>
    <p class="lede">${esc(m.lede)}</p>
    <div class="prose changelog">${renderMarkdown(source, { baseLevel: 1 })}</div>
    <p class="muted prose">${f(m.donateLine)}</p>`;
  return { routeId: "changelog", navId: "changelog", title: p(ui.titles.changelog), description: p(ui.descriptions.changelog), body };
}

export function renderPrivacy(ctx, lang) {
  const { c, f, p, ui } = kit(ctx, lang);
  const m = c.privacy;
  const body = `
    <h1>${esc(m.h1)}</h1>
    <p class="lede">${esc(m.lede)}</p>
    <p class="muted">${esc(m.updated)}</p>
    <div class="prose">${f(m.html)}</div>`;
  return { routeId: "privacy", navId: "privacy", title: p(ui.titles.privacy), description: p(ui.descriptions.privacy), body };
}

function qrCard(kt, key, src, extraHtml) {
  const { c, esc: e } = kt;
  const m = c.donate[key];
  return `<section class="qr-card" aria-labelledby="donate-${key}">
      <h3 id="donate-${key}">${e(m.h)}</h3>
      <img src="${e(src)}" width="240" height="240" alt="${e(m.alt)}">
      ${extraHtml}
      <p class="muted">${e(m.how)}</p>
    </section>`;
}

/** Donation block exactly per PRD-R59: thank-you line, VietQR (Napas), MoMo QR, GitHub Sponsors link. */
export function renderDonate(ctx, lang) {
  const kt = kit(ctx, lang);
  const { c, f, p, ui } = kt;
  const m = c.donate;
  const verify = f("{{verifyHtml}}");
  const account = `<dl class="facts"><dt>${esc(m.vietqr.accountLabel)}</dt><dd>${esc(m.vietqr.accountValue)} ${verify}</dd><dt>${esc(m.vietqr.bankLabel)}</dt><dd>${esc(m.vietqr.bankValue)} ${verify}</dd></dl>`;
  const body = `
    <h1>${f(m.h1)}</h1>
    <p class="lede">${f(m.thanks)}</p>
    <p>${esc(m.promise)}</p>
    <div class="qr-grid">
      ${qrCard(kt, "vietqr", "/assets/qr/vietqr.svg", account)}
      ${qrCard(kt, "momo", "/assets/qr/momo.svg", `<p>${verify}</p>`)}
      <section class="qr-card" aria-labelledby="donate-sponsors">
        <h3 id="donate-sponsors">${esc(m.sponsors.h)}</h3>
        <p>${esc(m.sponsors.body)}</p>
        <p><a class="btn" href="${esc(ctx.config.sponsorsUrl)}" rel="noopener">${esc(m.sponsors.link)}</a> ${verify}</p>
      </section>
    </div>
    <div class="callout warn"><p>${esc(m.placeholderNote)} ${verify}</p></div>
    <p class="muted prose">${esc(m.privacy)} <a href="${esc(routePath("privacy", lang))}">${esc(ui.nav.privacy)}</a></p>`;
  return { routeId: "donate", navId: undefined, title: p(ui.titles.donate), description: p(ui.descriptions.donate), body };
}

/** The 404 page is Vietnamese-first with an English line; it ships as /404.html. */
export function renderNotFound(ctx) {
  const vi = kit(ctx, "vi");
  const en = kit(ctx, "en");
  const body = `
    <h1>${esc(vi.ui.notFound.heading)}</h1>
    <p class="lede">${esc(vi.ui.notFound.body)}</p>
    <p><a class="btn" href="${esc(routePath("home", "vi"))}">${esc(vi.ui.notFound.home)}</a>
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
