// SPDX-License-Identifier: GPL-3.0-or-later
// Download page (PRD-R73): stable and beta DMGs, SHA-256, signature statement, requirements, Homebrew, archive.
import { kit, macosRequirement } from "../context.mjs";
import { formatDate } from "../dates.mjs";
import { esc } from "../util.mjs";

function releaseBlock(kt, release, heading, headingId) {
  const { c, ui, f, lang } = kt;
  const d = c.download;
  const facts = [
    [ui.common.version, `${esc(release.version)}${release.build ? ` (${esc(release.build)})` : ""}`],
    [d.releaseDate, esc(formatDate(lang, release.date))],
    [ui.common.channel, esc(ui.channel[release.channel])],
    [ui.common.minMacos, esc(macosRequirement(lang, release.minimumSystemVersion))],
    [d.fileHash, release.sha256 ? `<code>${esc(release.sha256)}</code>` : "-"],
  ]
    .filter(([, value]) => value !== "")
    .map(([term, value]) => `<dt>${esc(term)}</dt><dd>${value}</dd>`)
    .join("");
  return `<section class="release" aria-labelledby="${headingId}">
      <h3 id="${headingId}">${esc(heading)}</h3>
      <dl class="facts">${facts}</dl>
      <p><a class="btn" href="${esc(release.url)}">${f(d.button, { version: release.version })}</a></p>
    </section>`;
}

function archiveTable(kt, archive) {
  const { c, ui, lang } = kt;
  const d = c.download;
  if (archive.length === 0) return `<p class="muted">${esc(d.archiveEmpty)}</p>`;
  const rows = archive
    .map((r) => `<tr><th scope="row">${esc(r.version)}</th><td>${esc(formatDate(lang, r.date))}</td><td>${esc(ui.channel[r.channel])}</td><td>${r.sha256 ? `<code>${esc(r.sha256)}</code>` : "-"}</td><td><a href="${esc(r.url)}">${esc(ui.common.download)}</a></td></tr>`)
    .join("");
  return `<div class="table-wrap"><table>
    <thead><tr><th scope="col">${esc(ui.common.version)}</th><th scope="col">${esc(ui.common.date)}</th><th scope="col">${esc(ui.common.channel)}</th><th scope="col">${esc(ui.common.sha256)}</th><th scope="col"><span class="visually-hidden">${esc(ui.common.download)}</span></th></tr></thead>
    <tbody>${rows}</tbody></table></div>`;
}

export function renderDownload(ctx, lang) {
  const kt = { ...kit(ctx, lang), ctx };
  const { c, f, p, ui } = kt;
  const d = c.download;
  const { stable, beta, archive } = ctx.data.releases;
  const minimum = stable?.minimumSystemVersion ?? beta?.minimumSystemVersion ?? "";
  const usingDefaultMinimum = minimum === "";
  const macosLine = `${esc(macosRequirement(lang, minimum))}${usingDefaultMinimum ? ` ${f("{{verifyHtml}}")}` : ""}`;

  const releaseSections = [];
  if (stable) releaseSections.push(releaseBlock(kt, stable, d.stableHeading, "stable"));
  if (beta) {
    releaseSections.push(releaseBlock(kt, beta, d.betaHeading, "beta"));
    releaseSections.push(`<p class="muted">${esc(d.betaNote)}</p>`);
  }
  if (!stable && !beta) {
    releaseSections.push(`<div class="callout"><p><strong>${esc(ui.common.noRelease)}</strong></p><p>${esc(ui.common.noReleaseDetail)}</p></div>`);
  }

  const body = `
    <h1>${f(d.h1)}</h1>
    <p class="lede">${esc(d.lede)}</p>
    ${releaseSections.join("\n")}
    <div class="prose">
    <h2 id="install">${esc(d.installHeading)}</h2>
    <ol class="steps">${d.install.map((s) => `<li>${f(s)}</li>`).join("")}</ol>

    <h2 id="requirements">${esc(d.reqHeading)}</h2>
    <ul>
      <li>${macosLine}</li>
      <li>${esc(d.reqArch)}</li>
      <li>${esc(d.reqExcluded)}</li>
      <li>${f(d.reqPermission)}</li>
      <li>${f(d.reqNoOthers)}</li>
    </ul>

    <h2 id="trust">${esc(d.trustHeading)}</h2>
    <p>${esc(d.trustBody)}</p>
    <h3>${esc(d.verifyHeading)}</h3>
    <p>${esc(d.verifyBody)}</p>
    <pre><code>${d.verifyHashCmd}
spctl -a -vv "/Applications/${esc(ctx.brand.name)}.app"</code></pre>

    <h2 id="homebrew">${esc(d.brewHeading)}</h2>
    <p>${esc(d.brewBody)}</p>
    <p><code class="cmd">brew install --cask ${esc(ctx.config.homebrewTap)}/${esc(ctx.brand.slug)}</code></p>
    <p>${esc(d.brewUpgrade)}</p>
    <pre><code>brew upgrade --cask ${esc(ctx.brand.slug)}
brew uninstall --cask --zap ${esc(ctx.brand.slug)}</code></pre>
    </div>

    <h2 id="archive">${esc(d.archiveHeading)}</h2>
    <p class="prose">${esc(d.archiveBody)}</p>
    ${archiveTable(kt, archive)}
    <p class="muted prose">${f(d.appcastNote)}</p>`;

  return {
    routeId: "download",
    navId: "download",
    title: p(ui.titles.download),
    description: p(ui.descriptions.download),
    body,
  };
}
