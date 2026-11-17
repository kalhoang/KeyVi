// SPDX-License-Identifier: GPL-3.0-or-later
// Markup shared by the home sections that show engine demos (design 7.2, 7.4): the final text with its English words
// highlighted, the keys strip and the data-demo-frames payload that home.js animates. Text only through esc(); the
// payload is JSON in an attribute, never an inline script (design 4).
import { keyLabel, wordsOf } from "../../demos.mjs";
import { esc } from "../../util.mjs";

// The keys strip keeps the last eight keycaps (plan Task 6).
export const KEYS_SHOWN = 8;

/** The demo of `id` from site/demo/frames.json; a missing id fails the build. */
export function demoById(ctx, id) {
  const demo = ctx.demos.byId.get(id);
  if (!demo) throw new Error(`site/demo/frames.json: no demo "${id}" (add it to site/demo/script.json and regenerate)`);
  return demo;
}

/** The final text, English words in <mark> (design 7.1: a soft green highlight). The field shows the line; a closing
 * Return shows on the keys strip only. */
export function wordsHtml(demo) {
  return wordsOf(demo)
    .map(({ text, english }) => (english ? `<mark>${esc(text)}</mark>` : esc(text)))
    .join("")
    .replace(/\n+$/, "")
    .replace(/\n/g, "<br>");
}

/** The last keys of a demo as keycaps. */
export function keycapsHtml(demo, count = KEYS_SHOWN) {
  return demo.frames.slice(-count).map((frame) => `<kbd class="keycap">${esc(keyLabel(frame.key))}</kbd>`).join("");
}

/** A data-demo-frames attribute value. */
export function framesAttr(value) {
  return esc(JSON.stringify(value));
}

/** ` lang="vi"` for Vietnamese text on a page in another language (design 7.6: the demos type Vietnamese). */
export function viLang(lang) {
  return lang === "vi" ? "" : ' lang="vi"';
}
