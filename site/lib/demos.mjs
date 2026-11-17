// SPDX-License-Identifier: GPL-3.0-or-later
// The home page demos (design 7.4): site/demo/frames.json, written by the engine's site-demo-frames tool from
// site/demo/script.json and committed. The site never invents a demo: the build validates the file, renders each final
// state from it and hands the frames to home.js through data-demo-frames. Never edit the file by hand; regenerate it.
//
// Schema version 2 (the generator's renderFramesFile documents it): `{ schemaVersion, generator, demos: { <id>: demo } }`.
// A demo is `{ keys, method, toneStyle, text, frames, teachKeys?, teachPasses? }`; a frame `{ key, text, commit?,
// revision?, revised?, toggle? }`; a commit `{ raw, text, outcome, rule?, english, plain? }`; a revised token `{ raw,
// text, english, plain? }`. `plain`, on an English token only and never equal to its text, is what plain Telex would
// have typed for the raw keys (auto restore off, ENG-R802): the hero tags name it (design 9 item 1). A learning demo
// (design 9 item 4) adds `teachKeys`, the keys of one teaching pass with the restore toggle, and `teachPasses`, one
// `{ text, frames }` per pass in order, typed before `keys`; its final frames keep a word by rule `learned` (L9c).
import { readFile } from "node:fs/promises";

export const FRAMES_SCHEMA_VERSION = 2;
const LABEL = "site/demo/frames.json";

function fail(id, reason) {
  throw new Error(`${LABEL}: ${id}: ${reason}`);
}

function deepFreeze(value) {
  if (value && typeof value === "object") {
    for (const child of Object.values(value)) deepFreeze(child);
    Object.freeze(value);
  }
  return value;
}

const isObject = (value) => Boolean(value) && typeof value === "object" && !Array.isArray(value);

/** ENG-R802: a plain form belongs to an English token and names what plain typing would have shown instead of it. */
function validatePlain(id, index, name, token) {
  if (!isObject(token) || !("plain" in token)) return;
  const { plain, text, english } = token;
  if (typeof plain !== "string" || plain === "" || plain === text || english !== true) {
    fail(id, `frame ${index}: ${name} plain must be a non-empty string other than the text, on an English token`);
  }
}

/** `{ text, frames }`: the frames in order, the last one showing `text`. A demo and a teaching pass share it. */
function validateFrames(id, run) {
  if (!isObject(run)) fail(id, "is not an object");
  if (typeof run.text !== "string") fail(id, "text is not a string");
  if (!Array.isArray(run.frames) || run.frames.length === 0) fail(id, "has no frames");
  run.frames.forEach((frame, index) => {
    if (typeof frame?.key !== "string" || typeof frame?.text !== "string") fail(id, `frame ${index} needs a string key and a string text`);
    validatePlain(id, index, "commit", frame.commit);
    validatePlain(id, index, "revised", frame.revised);
  });
  if (run.frames.at(-1).text !== run.text) fail(id, "the last frame's text differs from the demo's text");
}

/** A learning demo's teaching keys (with the restore toggle ⎋, a correction) and passes come together. The site
 * re-checks what the generator enforces, as the only guard of the Site workflow (design 9 item 4): each pass corrects
 * with the restore toggle, and the final frames keep a word by rule `learned` (L9c, ENG-R863), so the page never
 * claims a learning the engine did not do. */
function validateTeaching(id, demo) {
  if (!("teachKeys" in demo) && !("teachPasses" in demo)) return;
  if (typeof demo.teachKeys !== "string" || !demo.teachKeys.includes("⎋") || !("teachPasses" in demo)) {
    fail(id, "teachKeys must hold the restore toggle ⎋ and come with teachPasses");
  }
  if (!Array.isArray(demo.teachPasses) || demo.teachPasses.length === 0) fail(id, "teachPasses must be a non-empty array");
  demo.teachPasses.forEach((pass, index) => {
    const label = `${id}: teaching pass ${index + 1}`;
    validateFrames(label, pass);
    if (!pass.frames.some((frame) => frame.toggle === true)) fail(label, "a teaching pass must contain the restore toggle frame");
  });
  if (!demo.frames.some((frame) => frame.commit?.rule === "learned")) {
    fail(id, "a learning demo's final frames must keep a word by rule learned (L9c)");
  }
}

function validateDemo(id, demo) {
  validateFrames(id, demo);
  validateTeaching(id, demo);
}

/** Reads and validates the frames file: `{ byId }`, a map from demo id to its frozen demo (with its teaching passes, if
 * any). Throws on any problem. */
export async function loadDemos(path) {
  let data;
  try {
    data = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    throw new Error(`${LABEL}: ${error.message} (regenerate it with site-demo-frames)`);
  }
  if (data?.schemaVersion !== FRAMES_SCHEMA_VERSION) fail("schemaVersion", `expected ${FRAMES_SCHEMA_VERSION}, found ${JSON.stringify(data?.schemaVersion)}`);
  if (!data.demos || typeof data.demos !== "object" || Array.isArray(data.demos)) fail("demos", "is not an object");
  const byId = new Map();
  for (const [id, demo] of Object.entries(data.demos)) {
    validateDemo(id, demo);
    byId.set(id, deepFreeze(demo));
  }
  return { byId };
}

const WORD_CHAR = /[\p{L}\p{M}\p{N}]/u;
const isWordChar = (ch) => ch !== undefined && WORD_CHAR.test(ch);

/** Where `word` stands as a whole word in `text` at or after `from`, or -1. */
function findWord(text, word, from) {
  for (let at = text.indexOf(word, from); at >= 0; at = text.indexOf(word, at + 1)) {
    if (!isWordChar(text[at - 1]) && !isWordChar(text[at + word.length])) return at;
  }
  return -1;
}

/** Words and separators of text no commit decided (the word still being composed, punctuation, spaces). */
const plainPieces = (text) => (text.match(/[\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+/gu) ?? []).map((piece) => ({ text: piece, english: false }));

/**
 * The final text split into words and separators, in order, each `{ text, english }`, and `plain` on an English word
 * that plain Telex would have typed otherwise (ENG-R802). A word is English when its latest state is: a commit says what
 * a token became, and a later frame's `revised` replaces the commit of the token before it (the next word fixed it,
 * D29). `learned: true` marks a word the engine kept from memory (commit rule `learned`, L9c), with its keys in `raw`:
 * the learning section's "remembered" badge and learned-words card read them, never the word itself; a revised token
 * has no rule, so a revision drops the mark.
 * Joining the pieces gives the demo's text back. A teaching pass (`{ text, frames }`) is read the same way.
 */
export function wordsOf(demo) {
  const tokens = demo.frames.reduce((list, frame) => {
    const revisedList = frame.revised && list.length > 0 ? [...list.slice(0, -1), frame.revised] : list;
    return frame.commit ? [...revisedList, frame.commit] : revisedList;
  }, []);
  const { pieces, cursor } = tokens.reduce((state, token) => {
    const at = token.text ? findWord(demo.text, token.text, state.cursor) : -1;
    if (at < 0) return state;
    const piece = {
      text: token.text,
      english: token.english === true,
      ...(token.plain ? { plain: token.plain } : {}),
      ...(token.rule === "learned" ? { learned: true, raw: token.raw } : {}),
    };
    return { pieces: [...state.pieces, ...plainPieces(demo.text.slice(state.cursor, at)), piece], cursor: at + token.text.length };
  }, { pieces: [], cursor: 0 });
  return [...pieces, ...plainPieces(demo.text.slice(cursor))];
}

/** The English words of the final text, in order: the words the hero tags as kept (their plain forms: wordsOf). */
export function englishWords(demo) {
  return wordsOf(demo).filter((piece) => piece.english).map((piece) => piece.text);
}

/** The index of the frame a learning row's keys strip ends at: the key the pass is about, which is the restore toggle of
 * a teaching pass or the commit the engine took from memory (rule learned, L9c), the last one of either; otherwise the
 * last frame. The teaching rows end on Escape and the last row on the learned word (design 9 item 4). Only the learning
 * section uses it: every other demo's strip ends on its last key, even a correction that types on after Escape.
 * home.js mirrors it for the learning rows, so the animated strip ends as the static one. */
export function keysEnd(frames) {
  const focus = frames.findLastIndex((frame) => frame.toggle === true || frame.commit?.rule === "learned");
  return focus >= 0 ? focus : frames.length - 1;
}

const TRAILING_WORD = /[\p{L}\p{M}\p{N}]+$/u;

/** The correction a teaching pass makes with the restore toggle (design 9 item 4): `vi`, the word the engine showed
 * before the toggle, and `raw`, the keys the toggle gave back. The learning caption names both, so its words always
 * come from the engine. Throws when the pass has no toggle after a word. */
export function correctionOf(pass) {
  const at = pass.frames.findIndex((frame) => frame.toggle === true);
  const raw = at > 0 ? pass.frames[at].text.match(TRAILING_WORD)?.[0] : undefined;
  const vi = at > 0 ? pass.frames[at - 1].text.match(TRAILING_WORD)?.[0] : undefined;
  if (!raw || !vi) throw new Error(`${LABEL}: a teaching pass has no restore toggle after a word`);
  return { raw, vi };
}

// Key notation of site/demo/script.json and the legend printed on a Mac keycap.
const KEY_LABELS = new Map([[" ", "space"], ["⏎", "return"], ["⎋", "esc"], ["⌫", "delete"]]);

/** The keycap legend of a frame's key. */
export function keyLabel(key) {
  return KEY_LABELS.get(key) ?? key;
}
