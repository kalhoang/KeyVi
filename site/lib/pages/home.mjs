// SPDX-License-Identifier: GPL-3.0-or-later
// Landing page (PRD-R73): value statement, download button, brew line, three proof points, compatibility link.
import { esc } from "../util.mjs";
import { DEFAULT_MIN_MACOS, kit, macosRequirement } from "../context.mjs";
import { FEATURES_ANCHOR } from "../layout.mjs";
import { routePath } from "../routes.mjs";

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
  const minMacos = (ctx.data.releases.stable?.minimumSystemVersion || DEFAULT_MIN_MACOS).replace(/\.0+$/, "");
  const behaviours = h.behaviours.items.map((item) => `<li><strong>${esc(item.title)}</strong> ${f(item.body)}</li>`).join("");
  // Interim layout until the redesigned sections land (plan Task 5).
  const body = `
    <section class="hero" aria-labelledby="hero-title">
      <div>
        <h1 id="hero-title">${esc(h.h1)}</h1>
        <p class="lede">${f(h.lede)}</p>
        ${downloadBlock(kt, lang)}
        <p class="muted">${f(h.meta, { minMacos })}</p>
      </div>
    </section>
    <section id="${FEATURES_ANCHOR[lang]}" aria-labelledby="why-title" class="prose">
      <h2 id="why-title">${esc(h.behaviours.heading)}</h2>
      <p>${f(h.behaviours.intro)}</p>
      <ul>${behaviours}</ul>
    </section>
    <section aria-labelledby="proof-title" class="band-dark">
      <h2 id="proof-title">${esc(h.proofHeading)}</h2>
      <ul class="proof">${proof}</ul>
    </section>
    <section aria-labelledby="compat-title" class="prose">
      <h2 id="compat-title">${esc(h.apps.heading)}</h2>
      <p>${esc(h.apps.intro)}</p>
      <p><a href="${esc(routePath("compat", lang))}">${esc(h.apps.link)}</a></p>
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
