// SPDX-License-Identifier: GPL-3.0-or-later
// Section 2, "one sentence, two languages" (design 7.3 item 2), the features anchor of the header: the three core
// behaviours as engine demos (behaviour-punctuation, -revision, -escape) with their final text in the page. The Return
// note of the punctuation item is a static statement, never animated (design 7.4, P0-3, ENG-R910). home.js plays each
// demo once when it scrolls into view and marks its figure data-motion-ready, which shows the replay button; the button
// keeps its place in the flow until then (home.css, design 7.8) and comes before the figcaption, which stays the last
// child of the figure (plan Task 6).
import { FEATURES_ANCHOR } from "../../layout.mjs";
import { esc } from "../../util.mjs";
import { demoById, framesAttr, keycapsHtml, viLang, wordsHtml } from "./markup.mjs";

function figure(kt, item, replay) {
  const { ctx, f, lang } = kt;
  const id = `behaviour-${item.id}`;
  const demo = demoById(ctx, id);
  const note = item.note ? `<p class="behaviour-note">${f(item.note)} <small class="req">${esc(item.noteReq)}</small></p>` : "";
  return `<figure class="behaviour" data-demo="${esc(id)}" data-demo-frames="${framesAttr(demo)}">
          <div class="demo-window">
            <p class="demo-field" data-input${viLang(lang)}>${wordsHtml(demo)}</p>
            <p class="keys" data-keys aria-hidden="true">${keycapsHtml(demo)}</p>
          </div>
          <button type="button" class="btn btn-ghost replay" data-replay>${esc(replay)}</button>
          <figcaption><h3>${esc(item.title)}</h3><p>${f(item.body)}</p>${note}</figcaption>
        </figure>`;
}

export function renderBehaviours(kt) {
  const { c, f, lang } = kt;
  const b = c.home.behaviours;
  return `<section id="${FEATURES_ANCHOR[lang]}" class="home-section" data-section="behaviours" aria-labelledby="behaviours-title">
      <div class="section-head"><h2 id="behaviours-title">${esc(b.heading)}</h2><p>${f(b.intro)}</p></div>
      <div class="behaviours">
        ${b.items.map((item) => figure(kt, item, b.replay)).join("\n        ")}
      </div>
    </section>`;
}
