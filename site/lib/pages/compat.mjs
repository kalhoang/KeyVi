// SPDX-License-Identifier: GPL-3.0-or-later
// Compatibility matrix (PRD-R35, QA-R17, QA-R19): server-rendered, grouped by category, JS only adds filters.
import { kit } from "../context.mjs";
import { STATUSES } from "../data.mjs";
import { formatDate } from "../dates.mjs";
import { esc } from "../util.mjs";
import { pageHead } from "./head.mjs";

// Keys are the status values of compat/schema/matrix.schema.json; the icon repeats the label's meaning so
// the status is never conveyed by colour alone.
const ICONS = { works: "✓", worksWithNotes: "!", notVerified: "?", knownLimitation: "×" };

function categoryLabel(ui, key) {
  return ui.categories[key] ?? key.charAt(0).toUpperCase() + key.slice(1);
}

function issueLinks(kt, entry) {
  if (entry.issues.length === 0) return "";
  const base = `${kt.ctx.config.githubRepo.replace(/\/+$/, "")}/issues/`;
  const links = entry.issues.map((n) => `<a href="${esc(base + n)}" rel="noopener">#${n}</a>`).join(", ");
  return `<small>${esc(kt.c.compat.issuesLabel)} ${links}</small>`;
}

function noteCell(kt, entry) {
  const { c, lang } = kt;
  const parts = [];
  const note = entry.note[lang];
  if (note) parts.push(esc(note));
  if (entry.stale) parts.push(`<small>${esc(c.compat.staleDetail.replace("{{date}}", formatDate(lang, entry.lastVerified)))}</small>`);
  else if (!entry.lastVerified && !note) parts.push(`<small>${esc(c.compat.neverVerified)}</small>`);
  parts.push(issueLinks(kt, entry));
  return parts.join("") || "-";
}

function row(kt, entry) {
  const { ui, lang } = kt;
  const status = ui.status[entry.status];
  const verified = entry.lastVerified
    ? `<time datetime="${esc(entry.lastVerified)}">${esc(formatDate(lang, entry.lastVerified))}</time>`
    : "-";
  const version = entry.appVersion ? `<small>${esc(entry.appVersion)}</small>` : "";
  const rule = entry.ruleId ? ` data-rule-id="${esc(entry.ruleId)}"` : "";
  return `<tr data-status="${esc(entry.status)}"${rule}>
<th scope="row">${esc(entry.name)}${version}</th>
<td><span class="status status-${esc(entry.status)}" data-icon="${ICONS[entry.status]}">${esc(status.label)}</span></td>
<td>${noteCell(kt, entry)}</td>
<td>${verified}</td>
<td>${esc(entry.macOS || "-")}</td>
</tr>`;
}

function groupSection(kt, key, entries) {
  const { ui, c } = kt;
  const label = categoryLabel(ui, key);
  const cols = c.compat.cols;
  return `<section data-category-group="${esc(key)}" data-label="${esc(label)}" aria-labelledby="cat-${esc(key)}">
<h2 id="cat-${esc(key)}">${esc(label)}</h2>
<div class="table-wrap"><table>
<thead><tr><th scope="col">${esc(cols.app)}</th><th scope="col">${esc(cols.status)}</th><th scope="col">${esc(cols.notes)}</th><th scope="col">${esc(cols.verified)}</th><th scope="col">${esc(cols.macos)}</th></tr></thead>
<tbody>
${entries.map((entry) => row(kt, entry)).join("\n")}
</tbody></table></div></section>`;
}

export function renderCompat(ctx, lang) {
  const kt = { ...kit(ctx, lang), ctx };
  const { c, f, p, ui } = kt;
  const m = c.compat;
  const { entries, usingFixture } = ctx.data.matrix;

  const byCategory = new Map();
  for (const entry of entries) byCategory.set(entry.category, [...(byCategory.get(entry.category) ?? []), entry]);
  const keys = [...byCategory.keys()].sort((a, b) => categoryLabel(ui, a).localeCompare(categoryLabel(ui, b), lang));

  const legend = STATUSES.map((s) => `<li><span class="status status-${s}" data-icon="${ICONS[s]}">${esc(ui.status[s].label)}</span><br><span class="muted">${esc(ui.status[s].help)}</span></li>`).join("");
  const filterData = {
    category: m.filterLabels.category, status: m.filterLabels.status, all: m.filterLabels.all, shown: m.filterLabels.shown,
  };
  const statusOptions = STATUSES.map((s) => [s, ui.status[s].label]);
  const jump = keys.map((k) => `<li><a href="#cat-${esc(k)}">${esc(categoryLabel(ui, k))}</a></li>`).join("");
  const issueUrl = `${ctx.config.githubRepo}/issues/new/choose`;

  const body = `
    ${pageHead(esc(m.h1), esc(m.lede))}
    ${usingFixture ? `<div class="callout warn" data-sample-data><p>${esc(ui.common.sampleDataNotice)}</p></div>` : ""}
    <h2 id="legend">${esc(m.legendHeading)}</h2>
    <ul class="legend">${legend}</ul>
    <p class="muted">${esc(m.staleNote)}</p>
    ${keys.length === 0 ? `<p>${esc(m.empty)}</p>` : `
    <nav aria-label="${esc(m.jumpLabel)}"><ul class="toc">${jump}</ul></nav>
    <div data-matrix-filters hidden data-labels="${esc(JSON.stringify(filterData))}" data-statuses="${esc(JSON.stringify(statusOptions))}"></div>
    <div data-matrix>
${keys.map((k) => groupSection(kt, k, byCategory.get(k))).join("\n")}
    </div>`}
    <h2 id="report">${esc(m.reportHeading)}</h2>
    <div class="card prose">
      <p>${esc(m.reportBody)}</p>
      <p><a class="btn" href="${esc(issueUrl)}" rel="noopener">${esc(m.reportLink)}</a></p>
      <p class="muted">${f(m.reportEmail)}</p>
    </div>`;

  return {
    routeId: "compat",
    navId: "compat",
    title: p(ui.titles.compat),
    description: p(ui.descriptions.compat),
    body,
    scripts: keys.length > 0 ? ["/assets/matrix.js"] : [],
  };
}
