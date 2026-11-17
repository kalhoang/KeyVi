// SPDX-License-Identifier: GPL-3.0-or-later
// Section 5, "works in all the popular apps" (design 7.3 item 4 as amended by design 9 item 2): the mark in the middle
// and a thread to each category of compat/matrix.json, over a list of the categories with up to four app names each
// (ranked apps, tier 1 first, then the order of the file). The list is the content: from 900 px home.css places each
// item where its thread ends; below that the threads hide and the list stays. The hub names apps only: no status, no
// date and no link to the compatibility page, which is unlisted (routes.mjs), whatever the matrix says. home.js draws
// the threads and moves dots along them (plan Task 6). The Secure Input card closes the section (P0-1, PLT-R395 to
// PLT-R398D); its requirement stays in data-req, not on the page (Pa, 17/11/2026).
import { markSvg } from "../../layout.mjs";
import { esc } from "../../util.mjs";

// The categories on the hub, in node order. Their names are those of the compatibility page (ui.categories), so the two
// pages always agree.
export const HUB_CATEGORIES = Object.freeze(["browser", "chat", "office", "notes", "launcher", "terminal", "developer"]);
// The thread drawing: the mark at the centre of a 1000 x 600 box, four nodes on the top row and three on the bottom row,
// in the order of HUB_CATEGORIES. home.css puts .hub-node-1 to -7 at the same points (site/test.mjs checks).
export const HUB_VIEWBOX = Object.freeze({ width: 1000, height: 600 });
const CENTRE = Object.freeze({ x: 500, y: 300 });
export const HUB_NODES = Object.freeze([
  { x: 125, y: 80 }, { x: 375, y: 80 }, { x: 625, y: 80 }, { x: 875, y: 80 },
  { x: 200, y: 520 }, { x: 500, y: 520 }, { x: 800, y: 520 },
].map(Object.freeze));
const MAX_APPS = 4;

const threadPath = ({ x, y }) => {
  const middle = (CENTRE.y + y) / 2;
  return `M${CENTRE.x} ${CENTRE.y}C${CENTRE.x} ${middle} ${x} ${middle} ${x} ${y}`;
};

// "Messenger (web, Chrome)" and "Messenger" are one app on the hub.
const baseName = (name) => name.replace(/\s*\([^)]*\)$/, "");

/** Up to four apps of a category, each with the entry that ranks first under its name: the apps the maintainers ranked
 * (tier 1, then 2) when the category has any, every app otherwise; then the order of the file. */
export function hubApps(entries, category) {
  const inCategory = entries.filter((entry) => entry.category === category);
  const tiered = inCategory.filter((entry) => entry.tier > 0);
  const ranked = (tiered.length > 0 ? tiered : inCategory).sort((a, b) => (a.tier || 9) - (b.tier || 9) || a.order - b.order);
  const names = [...new Set(ranked.map((entry) => baseName(entry.name)))].slice(0, MAX_APPS);
  return names.map((name) => ({ name, entry: ranked.find((entry) => baseName(entry.name) === name) }));
}

function node(kt, category, index) {
  const label = `<strong>${esc(kt.ui.categories[category])}</strong>`;
  const apps = hubApps(kt.ctx.data.matrix.entries, category).map(({ name }) => esc(name)).join(", ");
  return `<li class="hub-node hub-node-${index + 1}" data-category="${esc(category)}">${label}${apps ? `<span class="hub-apps">${apps}</span>` : ""}</li>`;
}

export function renderApps(kt) {
  const { c, f } = kt;
  const apps = c.home.apps;
  if (HUB_CATEGORIES.length !== HUB_NODES.length) throw new Error(`home apps: ${HUB_CATEGORIES.length} categories for ${HUB_NODES.length} hub nodes`);
  const threads = HUB_NODES.map((point) => `<path data-thread d="${threadPath(point)}"/>`).join("");
  return `<section class="home-section" data-section="apps" aria-labelledby="apps-title">
      <div class="section-head"><h2 id="apps-title">${esc(apps.heading)}</h2><p>${f(apps.intro)}</p></div>
      <div class="hub" data-hub>
        <svg class="hub-threads" viewBox="0 0 ${HUB_VIEWBOX.width} ${HUB_VIEWBOX.height}" aria-hidden="true" focusable="false">${threads}</svg>
        <div class="hub-centre" aria-hidden="true">${markSvg("mark hub-mark")}</div>
        <ul class="hub-list">${HUB_CATEGORIES.map((category, index) => node(kt, category, index)).join("")}</ul>
      </div>
      <div class="card secure-input" data-req="${esc(apps.secureInput.req)}">
        <h3>${esc(apps.secureInput.title)}</h3>
        <p>${f(apps.secureInput.body)}</p>
      </div>
    </section>`;
}
