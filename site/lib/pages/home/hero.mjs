// SPDX-License-Identifier: GPL-3.0-or-later
// Section 1, the hero (design 6, 7.3 item 1): the value statement and the download call on the left; on the right a
// generic chat window showing the first hero sentence finished, with the keys strip and a tag per English word, under a
// mini menu bar whose mark stays in the Vietnamese state. home.js (plan Task 6) types the three hero demos in rotation
// from data-demo-frames and reveals the pause button and the sent bubble; without JavaScript, or under reduced motion,
// this final state is the whole demo (design 7.2). The window is aria-hidden; the sentences are also in a visually
// hidden list (design 7.7).
import { DEFAULT_MIN_MACOS } from "../../context.mjs";
import { englishWords } from "../../demos.mjs";
import { markSvg } from "../../layout.mjs";
import { esc } from "../../util.mjs";
import { downloadBlock } from "./download.mjs";
import { demoById, framesAttr, keycapsHtml, viLang, wordsHtml } from "./markup.mjs";

export const HERO_DEMOS = Object.freeze(["hero-chat", "hero-email", "hero-note"]);

function minMacos(ctx) {
  return String(ctx.data.releases.stable?.minimumSystemVersion || DEFAULT_MIN_MACOS).replace(/\.0+$/, "");
}

function scene(kt, demos) {
  const { c, f, lang } = kt;
  const hero = c.home.hero;
  const [first] = demos;
  const vi = viLang(lang);
  const tags = englishWords(first).map((word) => `<span class="tag">${f(hero.keepTag, { word })}</span>`).join("");
  return `<div class="hero-scene" aria-hidden="true">
          <div class="menubar"><span class="menubar-item">${markSvg("mark menubar-mark")}<span>${esc(hero.menuBarLabel)}</span></span></div>
          <div class="mac-window" data-hero data-demo-frames="${framesAttr(demos)}">
            <div class="mac-window-bar"><span>${esc(hero.windowTitle)}</span></div>
            <div class="mac-window-body chat">
              <p class="chat-peer"><span class="chat-name">${esc(hero.peerName)}</span><span class="bubble bubble-in"${vi}>${esc(hero.peerMessage)}</span></p>
              <p class="bubble bubble-out" data-sent hidden><span${vi}>${esc(first.text)}</span><span class="chat-status">${esc(hero.sentLabel)}</span></p>
              <div class="chat-input"><p data-input${vi}>${wordsHtml(first)}</p></div>
              <p class="tags" data-tags>${tags}</p>
            </div>
            <div class="keys-strip"><span class="keys-label">${esc(hero.keysLabel)}</span><span class="keys" data-keys>${keycapsHtml(first)}</span></div>
          </div>
        </div>`;
}

/** The pause and play control (WCAG 2.2.2). Hidden until home.js animates, so it never shows where nothing moves; the
 * data attributes carry both labels for its toggle. */
function motionToggle({ pause, play }) {
  const labels = `data-label-pause="${esc(pause)}" data-label-play="${esc(play)}"`;
  return `<button type="button" class="btn btn-ghost motion-toggle" data-motion-toggle aria-pressed="false" ${labels} hidden>${esc(pause)}</button>`;
}

export function renderHero(kt) {
  const { ctx, c, f, lang } = kt;
  const h = c.home;
  const demos = HERO_DEMOS.map((id) => ({ id, ...demoById(ctx, id) }));
  const sentences = demos.map((demo) => `<li>${esc(demo.text)}</li>`).join("");
  return `<section class="hero" data-section="hero" aria-labelledby="hero-title">
      <div class="hero-copy">
        <h1 id="hero-title">${esc(h.h1)}</h1>
        <p class="lede">${f(h.lede)}</p>
        ${downloadBlock(kt)}
        <p class="hero-meta">${f(h.meta, { minMacos: minMacos(ctx) })}</p>
      </div>
      <div class="hero-demo">
        ${scene(kt, demos)}
        ${motionToggle(h.hero)}
        <div class="visually-hidden"><p>${esc(h.hero.caption)}</p><ul${viLang(lang)}>${sentences}</ul></div>
      </div>
    </section>`;
}
