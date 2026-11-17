// SPDX-License-Identifier: GPL-3.0-or-later
// Section 3, "type your way" (design 7.3 item 3): six cards. Engine cards show the keys and what the engine made of them
// (site/demo/frames.json); the modern tone placement is written in <em>, the setting's example (site/lib/tone.mjs).
// Static cards (macros, layouts, per-app memory) are illustrations the engine does not decide, never animated as if
// typed (design 7.4). Each card carries the requirement that proves it in data-req, which the page does not show (Pa,
// 17/11/2026: a general reader cannot use the IDs; site/tests/home.mjs ties them to the content).
import { esc } from "../../util.mjs";
import { demoById, viLang } from "./markup.mjs";

/** Keys, an arrow and what they give; `resultHtml` is already escaped. */
const keysTo = (keys, resultHtml, lang) =>
  `<code>${esc(keys)}</code><span class="arrow" aria-hidden="true">→</span><span class="out"${viLang(lang)}>${resultHtml}</span>`;

function engineRows(kt, item) {
  const { ctx, lang } = kt;
  const rows = item.demos.map((id) => {
    const demo = demoById(ctx, id);
    const label = item.labels?.[id] ? `<span class="demo-label">${esc(item.labels[id])}</span>` : "";
    const result = demo.toneStyle === "modern" ? `<em>${esc(demo.text)}</em>` : esc(demo.text);
    return `<li class="demo-row" data-demo="${esc(id)}">${label}${keysTo(demo.keys, result, lang)}</li>`;
  });
  return `<ul class="demo-rows">${rows.join("")}</ul>`;
}

const listOf = (className, items) => `<ul class="illustration ${className}">${items.map((html) => `<li>${html}</li>`).join("")}</ul>`;

const ILLUSTRATIONS = {
  macros: ({ keys, result, caption }, lang) => `<p class="illustration macro">${keysTo(keys, esc(result), lang)}<small>${esc(caption)}</small></p>`,
  layouts: ({ layouts }) => listOf("chips", layouts.map(esc)),
  perApp: ({ apps }) => listOf("app-modes", apps.map(({ app, mode }) => `<span>${esc(app)}</span><span class="mode">${esc(mode)}</span>`)),
};

function card(kt, item) {
  const { f, lang } = kt;
  const illustrate = ILLUSTRATIONS[item.id];
  if (!item.demos && !(illustrate && item.illustration)) throw new Error(`home card ${item.id}: neither demos nor an illustration`);
  const visual = item.demos ? engineRows(kt, item) : illustrate(item.illustration, lang);
  return `<li class="card feature" data-card="${esc(item.id)}"${item.demos ? "" : " data-static"} data-req="${esc(item.req)}">
          <h3>${esc(item.title)}</h3>
          <p>${f(item.body)}</p>
          ${visual}
        </li>`;
}

export function renderCards(kt) {
  const cards = kt.c.home.cards;
  return `<section class="home-section" data-section="cards" aria-labelledby="cards-title">
      <div class="section-head"><h2 id="cards-title">${esc(cards.heading)}</h2></div>
      <ul class="feature-grid">
        ${cards.items.map((item) => card(kt, item)).join("\n        ")}
      </ul>
    </section>`;
}
