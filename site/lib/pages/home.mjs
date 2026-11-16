// SPDX-License-Identifier: GPL-3.0-or-later
// Landing page (PRD-R73): value statement, demo slot, download button, brew line, three proof points.
import { esc } from "../util.mjs";
import { kit, macosRequirement } from "../context.mjs";
import { FEATURES_ANCHOR } from "../layout.mjs";
import { routePath } from "../routes.mjs";

function demoBlock({ ctx, c, f, esc: e }) {
  const h = c.home;
  const sources = ctx.demo
    .map((name) => `<source src="/assets/${e(name)}" type="${name.endsWith(".mp4") ? "video/mp4" : "video/webm"}">`)
    .join("");
  const media = ctx.demo.length > 0
    ? `<video controls muted loop playsinline preload="none" aria-label="${e(f(h.demoAlt))}">${sources}</video>`
    : `<div class="demo-slot" role="img" aria-label="${e(f(h.demoAlt))}"><p>${e(h.demoPlaceholder)}</p></div>`;
  return `<figure data-slot="demo">${media}<figcaption>${e(h.demoCaption)}</figcaption></figure>`;
}

function typedExample({ c, esc: e }) {
  const h = c.home;
  const rows = h.typed
    .map((row) => `<p>${e(row.keys)} <span class="arrow" aria-hidden="true">&rarr;</span> <span class="out">${e(row.out)}</span></p>`)
    .join("");
  return `<div class="typed" role="group" aria-label="${e(h.typedLabel)}">${rows}<p class="cap">${e(h.typedCaption)}</p></div>`;
}

function downloadBlock(kt, lang) {
  const { ctx, c, f, esc: e } = kt;
  const h = c.home;
  const stable = ctx.data.releases.stable;
  const brew = `<p class="muted">${e(h.brewLabel)}</p><code class="cmd">brew install --cask ${e(ctx.config.homebrewTap)}/${e(ctx.brand.slug)}</code>`;
  const all = `<a href="${e(routePath("download", lang))}">${e(h.allDownloads)}</a>`;
  if (!stable) {
    return `<div class="actions"><p class="btn btn-disabled" aria-disabled="true">${e(h.noReleaseBtn)}<small>${e(h.preRelease)}</small></p>${all}</div>${brew}`;
  }
  const requirement = macosRequirement(lang, stable.minimumSystemVersion);
  const button = `<a class="btn" href="${e(stable.url)}">${f(h.downloadBtn, { version: stable.version })}<small>${e(f(h.downloadSub, { requirement }))}</small></a>`;
  return `<div class="actions">${button}${all}</div>${brew}`;
}

export function renderHome(ctx, lang) {
  const kt = { ...kit(ctx, lang), ctx };
  const { c, f, p, ui } = kt;
  const h = c.home;
  const proof = h.proof
    .map((item) => {
      const link = item.link
        ? `<p><a href="${esc(f(item.link))}"${item.external ? ' rel="noopener"' : ""}>${esc(item.linkText)}</a></p>`
        : "";
      return `<li><h3>${esc(item.h)}</h3><p>${f(item.p)}</p>${link}</li>`;
    })
    .join("");
  const why = h.why.map((item) => `<li>${f(item)}</li>`).join("");
  const body = `
    <section class="hero" aria-labelledby="hero-title">
      <div>
        <h1 id="hero-title">${esc(h.h1)}</h1>
        <p class="lede">${esc(h.lede)}</p>
        ${downloadBlock(kt, lang)}
        <p class="muted">${f(h.footnote)}</p>
      </div>
      <div>${typedExample(kt)}</div>
    </section>
    ${demoBlock(kt)}
    <section aria-labelledby="proof-title" class="band-dark">
      <h2 id="proof-title">${esc(h.proofHeading)}</h2>
      <ul class="proof">${proof}</ul>
    </section>
    <section id="${FEATURES_ANCHOR[lang]}" aria-labelledby="why-title" class="prose">
      <h2 id="why-title">${esc(h.whyHeading)}</h2>
      <ul>${why}</ul>
    </section>
    <section aria-labelledby="compat-title" class="prose">
      <h2 id="compat-title">${esc(h.compatHeading)}</h2>
      <p>${esc(h.compatText)}</p>
      <p><a href="${esc(routePath("compat", lang))}">${esc(h.compatLink)}</a></p>
    </section>`;
  return {
    routeId: "home",
    isHome: true,
    title: p(ui.titles.home),
    description: p(ui.descriptions.home),
    body,
    styles: ["/assets/home.css"],
  };
}
