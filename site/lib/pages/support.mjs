// SPDX-License-Identifier: GPL-3.0-or-later
// Support page (PRD-R73, QA-R52) and the migration guides (PRD-R71, PRD-R69).
import { kit } from "../context.mjs";
import { MIGRATION_SOURCES, routePath } from "../routes.mjs";
import { esc } from "../util.mjs";

function faq(kt) {
  const { c, f } = kt;
  return c.support.faq
    .map(([q, a]) => `<details><summary>${f(q)}</summary><p>${f(a)}</p></details>`)
    .join("\n");
}

function troubleshooting(kt) {
  const { c, f } = kt;
  return Object.values(c.support.fix)
    .map((item) => `<section aria-labelledby="${item.id}"><h3 id="${item.id}">${f(item.h)}</h3>${f(item.html)}</section>`)
    .join("\n");
}

function targets(kt) {
  const { c } = kt;
  const s = c.support;
  const head = s.targetsCols.map((col) => `<th scope="col">${esc(col)}</th>`).join("");
  const rows = s.targets
    .map(([level, first, goal]) => `<tr><th scope="row">${esc(level)}</th><td>${esc(first)}</td><td>${esc(goal)}</td></tr>`)
    .join("");
  return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table></div>`;
}

function migrationCards(kt, lang) {
  const names = kt.c.migrate.indexNames;
  const items = MIGRATION_SOURCES.map((source) => {
    const [name, what] = names[source.id];
    return `<li><a href="${esc(routePath(`migrate-${source.id}`, lang))}"><strong>${esc(name)}</strong><span>${esc(what)}</span></a></li>`;
  }).join("");
  return `<ul class="cards">${items}</ul>`;
}

export function renderSupport(ctx, lang) {
  const kt = kit(ctx, lang);
  const { c, f, p, ui } = kt;
  const s = c.support;
  const toc = s.toc.map(([id, label]) => `<li><a href="#${id}">${esc(label)}</a></li>`).join("");
  const body = `
    <h1>${esc(s.h1)}</h1>
    <p class="lede">${esc(s.lede)}</p>
    <nav aria-label="${esc(s.tocLabel)}"><ul class="toc">${toc}</ul></nav>
    <div class="prose">
    <h2 id="${s.toc[0][0]}">${esc(s.faqHeading)}</h2>
    ${faq(kt)}
    <h2 id="${s.toc[1][0]}">${esc(s.fixHeading)}</h2>
    ${troubleshooting(kt)}
    <h2 id="${s.toc[2][0]}">${esc(s.reportHeading)}</h2>
    <p>${f(s.reportIntro)}</p>
    <ol class="steps">${s.reportSteps.map((step) => `<li>${f(step)}</li>`).join("")}</ol>
    <p>${esc(s.reportNoGithub)}</p>
    <p>${f(s.reportNever)}</p>
    <h3>${esc(s.channelsHeading)}</h3>
    <ul>${s.channels.map((item) => `<li>${f(item)}</li>`).join("")}</ul>
    <p class="muted">${esc(s.noDm)}</p>
    <h2 id="${s.toc[3][0]}">${esc(s.targetsHeading)}</h2>
    <p>${esc(s.targetsNote)}</p>
    </div>
    ${targets(kt)}
    <p class="muted prose">${esc(s.absence)}</p>
    <h2 id="${s.toc[4][0]}">${esc(s.migrateHeading)}</h2>
    <p class="prose">${f(s.migrateLede)}</p>
    ${migrationCards(kt, lang)}`;
  return { routeId: "support", navId: "support", title: p(ui.titles.support), description: p(ui.descriptions.support), body };
}

function screenshotSlot(kt, other) {
  const m = kt.c.migrate;
  return `<figure><div class="demo-slot" role="img" aria-label="${esc(m.screenshotAlt.replace("{{Other}}", other))}"><p>${esc(m.screenshotHolder)} ${kt.f("{{verifyHtml}}")}</p></div></figure>`;
}

export function renderMigration(ctx, lang, sourceId) {
  const kt = kit(ctx, lang);
  const { c, f, p, ui } = kt;
  const m = c.migrate;
  const page = m.pages[sourceId];
  const [other] = m.indexNames[sourceId];
  const extra = { Other: other };
  const heading = p(m.title, extra);
  const list = (items) => `<ol class="steps">${items.map((item) => `<li>${f(item, extra)}</li>`).join("")}</ol>`;

  const importBlock = `<h2 id="import">${f(m.importHeading, extra)}</h2>${list(m.importSteps)}`;
  const quitSteps = page.quitSteps ?? m.quitSteps;
  const quitBlock = page.noQuit ? "" : `<h2 id="quit">${f(m.quitHeading, extra)}</h2><p>${f(m.quitIntro, extra)}</p>${list(quitSteps)}`;
  const exportBlock = page.steps
    ? `<h2 id="export">${f(m.stepsHeading, extra)}</h2>${list(page.steps)}${screenshotSlot(kt, other)}<div class="callout warn"><p>${f("{{verifyHtml}}")} ${f(m.verifyNote)}</p></div>`
    : "";
  const body = `
    <p><a href="${esc(routePath("support", lang))}#${esc(c.support.toc[4][0])}">&larr; ${esc(m.back)}</a></p>
    <h1>${esc(heading)}</h1>
    <div class="prose">
      <p class="lede">${f(page.intro, extra)}</p>
      ${page.html ? f(page.html, extra) : ""}
      ${exportBlock}
      ${importBlock}
      ${quitBlock}
    </div>`;
  return {
    routeId: `migrate-${sourceId}`,
    navId: "support",
    title: heading,
    description: p(page.intro, extra).replace(/<[^>]+>/g, ""),
    body,
  };
}
