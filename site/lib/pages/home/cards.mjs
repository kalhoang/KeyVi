// SPDX-License-Identifier: GPL-3.0-or-later
// Section 4, "type your way" (design 7.3 item 3, design 9 item 4): four cards. Engine cards show the keys and what the
// engine made of them (site/demo/frames.json); the modern tone placement is written in <em>, the setting's example
// (site/lib/tone.mjs). Static cards (layouts here; the learned words, per-app memory, macros and word lists of the
// learning section, which renders them with cardList) are illustrations the engine does not decide, never animated as if
// typed (design 7.4). Each card carries the requirement that proves it in data-req, which the page does not show (Pa,
// 17/11/2026: a general reader cannot use the IDs; site/tests/home.mjs ties them to the content).
import { wordsOf } from "../../demos.mjs";
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

/** A row of the learned-words sheet (PRD-R78) for the word the learning demo's engine kept from memory, so the card and
 * the demo agree: the word's keys, an arrow, what it becomes (L9c keeps either side: the keys for an English choice,
 * the Vietnamese reading otherwise) and the context in words, which are the sheet's (Settings.xcstrings). */
export function learnedRowHtml(demo, context) {
  const word = wordsOf(demo).find((piece) => piece.learned);
  if (!word) throw new Error("home learning card: the learning demo keeps no word by rule learned");
  return `<p class="illustration learned-row"><code>${esc(word.raw)}</code><span class="arrow" aria-hidden="true">→</span><span class="out">${esc(word.text)}</span><small>${esc(context)}</small><span class="remove-mark" aria-hidden="true"></span></p>`;
}

const learnedRow = ({ context }, kt) => learnedRowHtml(demoById(kt.ctx, kt.c.home.learning.demo), context);

const ILLUSTRATIONS = {
  macros: ({ keys, result, caption }, kt) => `<p class="illustration macro">${keysTo(keys, esc(result), kt.lang)}<small>${esc(caption)}</small></p>`,
  layouts: ({ layouts }) => listOf("chips", layouts.map(esc)),
  perApp: ({ apps }) => listOf("app-modes", apps.map(({ app, mode }) => `<span>${esc(app)}</span><span class="mode">${esc(mode)}</span>`)),
  learned: learnedRow,
  wordLists: ({ lists }) => listOf("chips word-lists", lists.map(esc)),
};

function card(kt, item) {
  const { f } = kt;
  const illustrate = ILLUSTRATIONS[item.id];
  if (!item.demos && !(illustrate && item.illustration)) throw new Error(`home card ${item.id}: neither demos nor an illustration`);
  const visual = item.demos ? engineRows(kt, item) : illustrate(item.illustration, kt);
  return `<li class="card feature" data-card="${esc(item.id)}"${item.demos ? "" : " data-static"} data-req="${esc(item.req)}">
          <h3>${esc(item.title)}</h3>
          <p>${f(item.body)}</p>
          ${visual}
        </li>`;
}

/** A grid of cards, engine or static. */
export function cardList(kt, items) {
  return `<ul class="feature-grid">
        ${items.map((item) => card(kt, item)).join("\n        ")}
      </ul>`;
}

export function renderCards(kt) {
  const cards = kt.c.home.cards;
  return `<section class="home-section" data-section="cards" aria-labelledby="cards-title">
      <div class="section-head"><h2 id="cards-title">${esc(cards.heading)}</h2></div>
      ${cardList(kt, cards.items)}
    </section>`;
}
