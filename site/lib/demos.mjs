// SPDX-License-Identifier: GPL-3.0-or-later
// The home page demos (design 7.4): site/demo/frames.json, written by the engine's site-demo-frames tool from
// site/demo/script.json and committed. The site never invents a demo: the build validates the file, renders each final
// state from it and hands the frames to home.js through data-demo-frames. Never edit the file by hand; regenerate it.
import { readFile } from "node:fs/promises";

export const FRAMES_SCHEMA_VERSION = 1;
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

function validateDemo(id, demo) {
  if (!demo || typeof demo !== "object" || Array.isArray(demo)) fail(id, "is not an object");
  if (typeof demo.text !== "string") fail(id, "text is not a string");
  if (!Array.isArray(demo.frames) || demo.frames.length === 0) fail(id, "has no frames");
  demo.frames.forEach((frame, index) => {
    if (typeof frame?.key !== "string" || typeof frame?.text !== "string") fail(id, `frame ${index} needs a string key and a string text`);
  });
  if (demo.frames.at(-1).text !== demo.text) fail(id, "the last frame's text differs from the demo's text");
}

/** Reads and validates the frames file: `{ byId }`, a map from demo id to its frozen demo. Throws on any problem. */
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
 * The final text split into words and separators, in order, each `{ text, english }`. A word is English when its latest
 * state is: a commit says what a token became, and a later frame's `revised` replaces the commit of the token before it
 * (the next word fixed it, D29). Joining the pieces gives the demo's text back.
 */
export function wordsOf(demo) {
  const tokens = demo.frames.reduce((list, frame) => {
    const revisedList = frame.revised && list.length > 0 ? [...list.slice(0, -1), frame.revised] : list;
    return frame.commit ? [...revisedList, frame.commit] : revisedList;
  }, []);
  const { pieces, cursor } = tokens.reduce((state, token) => {
    const at = token.text ? findWord(demo.text, token.text, state.cursor) : -1;
    if (at < 0) return state;
    const piece = { text: token.text, english: token.english === true };
    return { pieces: [...state.pieces, ...plainPieces(demo.text.slice(state.cursor, at)), piece], cursor: at + token.text.length };
  }, { pieces: [], cursor: 0 });
  return [...pieces, ...plainPieces(demo.text.slice(cursor))];
}

/** The English words of the final text, in order: the words the hero tags as kept. */
export function englishWords(demo) {
  return wordsOf(demo).filter((piece) => piece.english).map((piece) => piece.text);
}

// Key notation of site/demo/script.json and the legend printed on a Mac keycap.
const KEY_LABELS = new Map([[" ", "space"], ["⏎", "return"], ["⎋", "esc"], ["⌫", "delete"]]);

/** The keycap legend of a frame's key. */
export function keyLabel(key) {
  return KEY_LABELS.get(key) ?? key;
}
