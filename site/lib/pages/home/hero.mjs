// SPDX-License-Identifier: GPL-3.0-or-later
// Section 1, the hero (design 6, 7.3 item 1): the value statement and the download call on the left; on the right a
// generic chat window showing the first hero sentence finished, with the keys strip and a tag per English word, under a
// mini menu bar whose mark stays in the Vietnamese state. home.js (plan Task 6) types the three hero demos in rotation
// from data-demo-frames, shows the sent bubble of each finished sentence and marks the section data-motion-ready to
// show the pause button; without JavaScript, or under reduced motion, this final state is the whole demo (design 7.2).
// The sent bubbles, one per sentence, share one cell and stay invisible until sent (home.css), so the chat reserves the
// tallest at every width and sending one moves nothing (design 7.8). The window is aria-hidden; the sentences are also
// in a visually hidden list (design 7.7).
import { DEFAULT_MIN_MACOS } from "../../context.mjs";
import { englishWords } from "../../demos.mjs";
import { markSvg } from "../../layout.mjs";
import { esc } from "../../util.mjs";
import { downloadBlock } from "./download.mjs";
import { demoById, framesAttr, keycapsHtml, viLang, wordsHtml } from "./markup.mjs";

export const HERO_DEMOS = Object.freeze(["hero-chat", "hero-email", "hero-note"]);
// Stands for the word while keepTag is split into the plain text before and after it.
const WORD_SLOT = "\u0000";

function minMacos(ctx) {
  return String(ctx.data.releases.stable?.minimumSystemVersion || DEFAULT_MIN_MACOS).replace(/\.0+$/, "");
}

/** keepTag around its word, as data-tag-before and data-tag-after: home.js writes the tags of the next sentences as
 * text with them, so the content needs no token in the page and the tags read like the static ones. */
function tagTemplate(kt, keepTag) {
  const parts = kt.p(keepTag, { word: WORD_SLOT }).split(WORD_SLOT);
  if (parts.length !== 2) throw new Error(`home hero.keepTag needs {{word}} once: ${keepTag}`);
  return `data-tag-before="${esc(parts[0])}" data-tag-after="${esc(parts[1])}"`;
}

function scene(kt, demos) {
  const { c, f, lang } = kt;
  const hero = c.home.hero;
  const [first] = demos;
  const vi = viLang(lang);
  const tagsOf = (demo) => englishWords(demo).map((word) => `<span class="tag">${f(hero.keepTag, { word })}</span>`).join("");
  // An invisible copy of each sentence's tags in the cell of the live tags, so the row reserves the most rows any
  // sentence needs at every width (home.css, design 7.8).
  const sizers = demos.map((demo) => `<p class="tags tags-sizer">${tagsOf(demo)}</p>`).join("");
  return `<div class="hero-scene" aria-hidden="true">
          <div class="menubar"><span class="menubar-item">${markSvg("mark menubar-mark")}<span>${esc(hero.menuBarLabel)}</span></span></div>
          <div class="mac-window" data-hero data-demo-frames="${framesAttr(demos)}">
            <div class="mac-window-bar"><span>${esc(hero.windowTitle)}</span></div>
            <div class="mac-window-body chat">
              <p class="chat-peer"><span class="chat-name">${esc(hero.peerName)}</span><span class="bubble bubble-in"${vi}>${esc(hero.peerMessage)}</span></p>
              <div class="chat-sent" data-sent>${demos.map((demo) => `<p class="bubble bubble-out"><span${vi}>${esc(demo.text)}</span><span class="chat-status">${esc(hero.sentLabel)}</span></p>`).join("")}</div>
              <div class="chat-input"><p data-input${vi}>${wordsHtml(first)}</p></div>
              <div class="tags-cell">${sizers}<p class="tags" data-tags ${tagTemplate(kt, hero.keepTag)}>${tagsOf(first)}</p></div>
            </div>
            <div class="keys-strip"><span class="keys-label">${esc(hero.keysLabel)}</span><span class="keys" data-keys>${keycapsHtml(first)}</span></div>
          </div>
        </div>`;
}

/** The pause and play control (WCAG 2.2.2). It keeps its place in the flow, invisible (home.css) until home.js animates
 * and marks the hero data-motion-ready, so it never shows where nothing moves and showing it shifts nothing (design 7.8);
 * the data attributes carry both labels for its toggle. */
function motionToggle({ pause, play }) {
  const labels = `data-label-pause="${esc(pause)}" data-label-play="${esc(play)}"`;
  return `<button type="button" class="btn btn-ghost motion-toggle" data-motion-toggle aria-pressed="false" ${labels}>${esc(pause)}</button>`;
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
