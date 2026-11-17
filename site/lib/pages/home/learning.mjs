// SPDX-License-Identifier: GPL-3.0-or-later
// Section 3, "the more you type, the better it fits" (design 9 item 4): how the app learns from the user's corrections.
// The demo is learning-reset of site/demo/frames.json, which the engine wrote: two teaching passes, each corrected with
// Escape (the restore toggle), fed to the learned memory (ENG-R863), then the pass the engine types from memory (rule
// learned, L9c). Three rows show the passes in order, each finished, with its keys strip ending at the key it is about
// (keysEnd: Escape in a teaching row, the learned word in the last); the last row marks the learned word with a badge
// read from the frames, never from the word itself. The caption names the correction with the words of the frames
// (correctionOf). Without JavaScript, or under reduced motion, the three finished rows are the whole demo; home.js plays
// them one after the other with the behaviour player when the figure scrolls into view, and the replay button works as
// in section 2 (data-label-stop while it plays, data-label-replay at rest), described by the caption. Four static cards
// follow: the learned words (PRD-R78), per-app memory and macros (PRD-R2) and the user's word lists (ENG-R860).
import { correctionOf } from "../../demos.mjs";
import { esc } from "../../util.mjs";
import { cardList } from "./cards.mjs";
import { demoById, framesAttr, keycapsHtml, viLang, wordsHtml } from "./markup.mjs";

const CAPTION_ID = "learning-caption";

/** The badge after the learned word. The parentheses are for screen readers only, so the sentence still reads as one
 * ("reset (Đã nhớ) lại máy nha"); the badge is in the page language inside the Vietnamese field. home.js moves this very
 * element along while the last row types. */
function badgeHtml(kt) {
  const lang = kt.lang === "vi" ? "" : ` lang="${esc(kt.lang)}"`;
  return `<span class="learned-badge"${lang}><span class="visually-hidden"> (</span>${esc(kt.c.home.learning.learned)}<span class="visually-hidden">)</span></span>`;
}

/** One row per pass: its label, its finished text and its keys strip. */
function rows(kt, demo, passes) {
  const { lang } = kt;
  const labels = kt.c.home.learning.rows;
  if (labels.length !== passes.length) throw new Error(`home learning: ${labels.length} row labels for ${passes.length} passes of ${kt.c.home.learning.demo}`);
  return passes.map((pass, index) => {
    const badge = index === passes.length - 1 ? badgeHtml(kt) : "";
    return `<li class="learning-row" data-run><span class="learning-label">${esc(labels[index])}</span><p class="demo-field" data-input${viLang(lang)}>${wordsHtml(pass, badge)}</p><p class="keys" data-keys aria-hidden="true">${keycapsHtml(pass)}</p></li>`;
  }).join("\n            ");
}

function figure(kt) {
  const { ctx, f } = kt;
  const copy = kt.c.home.learning;
  const demo = demoById(ctx, copy.demo);
  if (!demo.teachPasses) throw new Error(`home learning: ${copy.demo} has no teaching passes`);
  const passes = [...demo.teachPasses, demo];
  const { raw, vi } = correctionOf(demo.teachPasses[0]);
  const labels = kt.c.home.behaviours;
  return `<figure class="learning-demo" data-demo="${esc(copy.demo)}" data-demo-frames="${framesAttr(demo)}" data-req="${esc(copy.req)}">
        <div class="demo-window">
          <ol class="learning-rows">
            ${rows(kt, demo, passes)}
          </ol>
        </div>
        <button type="button" class="btn btn-ghost replay" data-replay data-label-replay="${esc(labels.replay)}" data-label-stop="${esc(labels.stop)}" aria-describedby="${CAPTION_ID}">${esc(labels.replay)}</button>
        <figcaption><p id="${CAPTION_ID}">${f(copy.caption, { raw, vi })}</p></figcaption>
      </figure>`;
}

export function renderLearning(kt) {
  const { f } = kt;
  const copy = kt.c.home.learning;
  return `<section class="home-section" data-section="learning" aria-labelledby="learning-title">
      <div class="section-head"><h2 id="learning-title">${esc(copy.heading)}</h2><p>${f(copy.intro)}</p></div>
      ${figure(kt)}
      ${cardList(kt, copy.cards)}
    </section>`;
}
