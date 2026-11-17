// SPDX-License-Identifier: GPL-3.0-or-later
// Section 1, the hero (design 6, 7.3 item 1): the value statement and the download call on the left; on the right a
// generic chat window showing the first hero sentence finished, with the keys strip and a tag per English word, under a
// mini menu bar whose mark stays in the Vietnamese state. A tag names what plain Telex would have typed when the engine
// recorded a plain form (design 9 item 1, ENG-R802): "test, không thành tét", the word strong and the plain form struck
// through by home.css; the hidden list says every tag in words, so no meaning rests on the strike. home.js (plan Task
// 6) types the three hero demos in rotation from data-demo-frames, shows the sent bubble of each finished sentence and
// marks the section data-motion-ready to show the pause button; without JavaScript, or under reduced motion, this final
// state is the whole demo (design 7.2).
// The sent bubbles, one per sentence, share one cell and stay invisible until sent (home.css), so the chat reserves the
// tallest at every width and sending one moves nothing (design 7.8). The window is aria-hidden; the sentences are also
// in a visually hidden list (design 7.7).
import { DEFAULT_MIN_MACOS } from "../../context.mjs";
import { wordsOf } from "../../demos.mjs";
import { markSvg } from "../../layout.mjs";
import { esc } from "../../util.mjs";
import { downloadBlock } from "./download.mjs";
import { demoById, framesAttr, keycapsHtml, viLang, wordsHtml } from "./markup.mjs";

export const HERO_DEMOS = Object.freeze(["hero-chat", "hero-email", "hero-note"]);
// Marks a slot while a tag template is split into its parts.
const SLOT = "\u0000";

function minMacos(ctx) {
  return String(ctx.data.releases.stable?.minimumSystemVersion || DEFAULT_MIN_MACOS).replace(/\.0+$/, "");
}

/** A tag template as parts, literal text at even indexes and a slot name at odd ones (`["", "word", ", không thành ",
 * "plain", ""]`), each of `slots` exactly once. home.js writes the tags of the next sentences from the same parts (data
 * attributes), so the content needs no token in the page and every tag reads like the static ones. */
function tagParts(kt, name, slots) {
  const template = kt.c.home.hero[name];
  const parts = kt.p(template, Object.fromEntries(slots.map((slot) => [slot, `${SLOT}${slot}${SLOT}`]))).split(SLOT);
  const found = parts.filter((part, index) => index % 2 === 1);
  if (found.length !== slots.length || slots.some((slot) => !found.includes(slot))) {
    throw new Error(`home hero.${name} needs ${slots.map((slot) => `{{${slot}}}`).join(" and ")} once each: ${template}`);
  }
  return parts;
}

/** The two templates of a hero: plainTag for a word with a plain form, keepTag otherwise. */
const tagTemplates = (kt) => ({ keep: tagParts(kt, "keepTag", ["word"]), plain: tagParts(kt, "plainTag", ["word", "plain"]) });

const templateOf = (templates, piece) => (piece.plain ? templates.plain : templates.keep);

/** A tag in HTML: the word strong, the plain form in a span that home.css strikes through, the rest muted text. */
function tagHtml(templates, piece) {
  const slot = { word: () => `<strong>${esc(piece.text)}</strong>`, plain: () => `<span class="tag-plain">${esc(piece.plain)}</span>` };
  return `<span class="tag">${templateOf(templates, piece).map((part, index) => (index % 2 === 0 ? esc(part) : slot[part]())).join("")}</span>`;
}

/** What a tag says, as plain text for the hidden list. */
const tagText = (templates, piece) => templateOf(templates, piece).map((part, index) => (index % 2 === 0 ? part : piece[part === "word" ? "text" : "plain"])).join("");

const keptWords = (demo) => wordsOf(demo).filter((piece) => piece.english);

function scene(kt, demos, templates) {
  const { c, lang } = kt;
  const hero = c.home.hero;
  const [first] = demos;
  const vi = viLang(lang);
  const tagsOf = (demo) => keptWords(demo).map((piece) => tagHtml(templates, piece)).join("");
  const templateAttrs = `data-tag-keep="${esc(JSON.stringify(templates.keep))}" data-tag-plain="${esc(JSON.stringify(templates.plain))}"`;
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
              <div class="tags-cell">${sizers}<p class="tags" data-tags ${templateAttrs}>${tagsOf(first)}</p></div>
            </div>
            <div class="keys-strip"><span class="keys-label">${esc(hero.keysLabel)}</span><span class="keys" data-keys>${keycapsHtml(first)}</span></div>
          </div>
        </div>`;
}

// The visually hidden caption of the demo, which also describes the pause button.
const CAPTION_ID = "hero-caption";

/** The pause and play control (WCAG 2.2.2). It keeps its place in the flow, invisible (home.css) until home.js animates
 * and marks the hero data-motion-ready, so it never shows where nothing moves and showing it shifts nothing (design 7.8).
 * A plain action button: home.js swaps its label between the two in the data attributes, so the label always says what
 * pressing does, and it has no pressed state that could contradict the label. The hidden caption describes it, so it
 * also says what it pauses. */
function motionToggle({ pause, play }) {
  const labels = `data-label-pause="${esc(pause)}" data-label-play="${esc(play)}"`;
  return `<button type="button" class="btn btn-ghost motion-toggle" data-motion-toggle aria-describedby="${CAPTION_ID}" ${labels}>${esc(pause)}</button>`;
}

/** A sentence of the hidden list, then its tags in words: "(test, không thành tét; ...)". */
function sentenceItem(kt, templates, demo) {
  const tags = keptWords(demo).map((piece) => tagText(templates, piece));
  return `<li><span${viLang(kt.lang)}>${esc(demo.text)}</span>${tags.length > 0 ? ` (${esc(tags.join("; "))})` : ""}</li>`;
}

export function renderHero(kt) {
  const { ctx, c, f } = kt;
  const h = c.home;
  const demos = HERO_DEMOS.map((id) => ({ id, ...demoById(ctx, id) }));
  const templates = tagTemplates(kt);
  const sentences = demos.map((demo) => sentenceItem(kt, templates, demo)).join("");
  return `<section class="hero" data-section="hero" aria-labelledby="hero-title">
      <div class="hero-copy">
        <h1 id="hero-title">${esc(h.h1)}</h1>
        <p class="lede">${f(h.lede)}</p>
        ${downloadBlock(kt)}
        <p class="hero-meta">${f(h.meta, { minMacos: minMacos(ctx) })}</p>
      </div>
      <div class="hero-demo">
        ${scene(kt, demos, templates)}
        ${motionToggle(h.hero)}
        <div class="visually-hidden"><p id="${CAPTION_ID}">${esc(h.hero.caption)}</p><ul>${sentences}</ul></div>
      </div>
    </section>`;
}
