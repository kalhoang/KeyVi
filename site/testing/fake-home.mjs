// SPDX-License-Identifier: GPL-3.0-or-later
// A small stand-in for the browser, so site/test.mjs can run the DOM wiring of site/static/assets/home.js in Node: the
// elements home.js queries (found by selector from a table, not parsed), a recording anime.js whose timelines the test
// runs by hand, an IntersectionObserver the test triggers and a matchMedia that asks for reduced motion only once the
// test turns it on. Only what home.js uses is here; a call to anything else throws, so a new dependency shows up as a
// failing check.

const TEXT_NODE = 3;

/** An element with attributes, children, listeners, an inline style and selector tables for querySelector(All) and
 * closest(). */
export function fakeElement(tagName, attributes = {}) {
  const el = {
    tagName: tagName.toUpperCase(),
    attributes: new Map(Object.entries(attributes)),
    children: [],
    parent: null,
    style: {},
    listeners: new Map(),
    classes: new Set(),
    className: "",
    found: new Map(),
    foundAll: new Map(),
    ancestors: new Map(),
    ownText: "",
    getAttribute: (name) => (el.attributes.has(name) ? el.attributes.get(name) : null),
    setAttribute: (name, value) => el.attributes.set(name, String(value)),
    removeAttribute: (name) => el.attributes.delete(name),
    hasAttribute: (name) => el.attributes.has(name),
    addEventListener: (type, listener) => el.listeners.set(type, (el.listeners.get(type) ?? []).concat([listener])),
    dispatch: (type) => (el.listeners.get(type) ?? []).forEach((listener) => listener({ type, target: el })),
    append: (...nodes) => nodes.forEach((node) => adopt(el, node)),
    replaceChildren: (...nodes) => {
      el.children.forEach((child) => (child.parent = null));
      el.children = [];
      el.ownText = "";
      el.append(...nodes);
    },
    remove: () => {
      if (el.parent) el.parent.children = el.parent.children.filter((child) => child !== el);
      el.parent = null;
    },
    querySelector: (selector) => el.found.get(selector) ?? null,
    querySelectorAll: (selector) => el.foundAll.get(selector) ?? [],
    closest: (selector) => el.ancestors.get(selector) ?? null,
    getBoundingClientRect: () => ({ height: 58, width: 300, top: 0, left: 0 }),
    classList: { add: (name) => el.classes.add(name) },
    get firstElementChild() {
      return el.children.find((child) => child.nodeType !== TEXT_NODE) ?? null;
    },
    get textContent() {
      return el.children.length > 0 ? el.children.map(textOf).join("") : el.ownText;
    },
    set textContent(value) {
      el.replaceChildren();
      el.ownText = String(value);
    },
  };
  return el;
}

function adopt(parent, node) {
  if (node.parent) node.remove();
  node.parent = parent;
  parent.children.push(node);
}

function textNode(data) {
  const node = { nodeType: TEXT_NODE, data, parent: null };
  node.remove = () => {
    if (node.parent) node.parent.children = node.parent.children.filter((child) => child !== node);
    node.parent = null;
  };
  return node;
}

/** The text a node shows, a <br> as a line break. */
export function textOf(node) {
  if (node.nodeType === TEXT_NODE) return node.data;
  if (node.tagName === "BR") return "\n";
  return node.textContent;
}

/** A recording anime.js: animate() and createTimeline() return items that do nothing until the test calls run(). */
export function fakeAnime() {
  const timelines = [];
  const animations = [];
  const item = (params) => ({ params, playing: false, cancelled: false, completed: false, play() { this.playing = true; }, pause() { this.playing = false; } });
  const anime = {
    timelines,
    animations,
    animate(targets, params) {
      const animation = Object.assign(item(params), {
        targets,
        complete() {
          this.completed = true;
          if (params.onComplete) params.onComplete(this);
        },
      });
      animations.push(animation);
      return animation;
    },
    createTimeline(params) {
      const calls = [];
      const timeline = Object.assign(item(params), {
        calls,
        call(fn, at) {
          calls.push({ fn, at });
          return this;
        },
        add() {
          return this;
        },
        cancel() {
          this.cancelled = true;
        },
        /** Runs the timeline's callbacks in time order, then its onComplete, unless it was cancelled meanwhile. */
        run(count = calls.length) {
          const ordered = calls.slice().sort((a, b) => a.at - b.at);
          for (const { fn } of ordered.slice(this.done ?? 0, count)) {
            if (this.cancelled) return;
            fn();
          }
          this.done = count;
          if (count >= calls.length && !this.cancelled && params.onComplete) params.onComplete(this);
        },
      });
      timelines.push(timeline);
      return timeline;
    },
    stagger: (step) => (target, index) => index * step,
    svg: {
      createDrawable: (paths) => paths,
      createMotionPath: () => ({ translateX: 0, translateY: 0 }),
    },
  };
  return anime;
}

/** A window for home.js: `doc.found` and `doc.foundAll` say what the document's queries return. */
export function fakeWindow(anime) {
  const observers = [];
  const doc = fakeElement("#document");
  Object.assign(doc, {
    hidden: false,
    readyState: "complete",
    createElement: (tagName) => fakeElement(tagName),
    createElementNS: (ns, tagName) => fakeElement(tagName),
    createTextNode: (data) => textNode(data),
  });
  class IntersectionObserver {
    constructor(callback, options = {}) {
      this.callback = callback;
      this.options = options;
      observers.push(this);
    }
    observe(el) {
      this.el = el;
    }
  }
  const reducedListeners = [];
  const reduced = {
    matches: false,
    addEventListener: (type, listener) => reducedListeners.push(listener),
  };
  const win = {
    document: doc,
    anime,
    innerHeight: 800,
    IntersectionObserver,
    matchMedia: () => reduced,
    console: { error: (...args) => { throw new Error(`home.js reported an error: ${args.join(" ")}`); } },
    /** The observers watching `el`, with the options home.js gave them. */
    observersOf: (el) => observers.filter((observer) => observer.el === el),
    /** Tells every observer of `el` that it shows, with `ratio` of it on screen. */
    show(el, ratio = 1) {
      const entry = { isIntersecting: ratio > 0, intersectionRatio: ratio, boundingClientRect: el.getBoundingClientRect() };
      win.observersOf(el).forEach((observer) => observer.callback([entry]));
    },
    /** Hides or shows the tab, as the browser does: document.hidden, then visibilitychange. */
    setHidden(hidden) {
      doc.hidden = hidden;
      doc.dispatch("visibilitychange");
    },
    /** The visitor turns on reduced motion while the page is open. */
    reduceMotion() {
      reduced.matches = true;
      reducedListeners.forEach((listener) => listener({ type: "change", matches: true }));
    },
  };
  return win;
}

/** A behaviour figure as lib/pages/home/behaviours.mjs renders it, with the given replay button attributes. */
export function fakeBehaviour(demo, buttonAttributes) {
  const figure = fakeElement("figure", { "data-demo": demo.id, "data-demo-frames": JSON.stringify(demo) });
  const demoWindow = fakeElement("div", { class: "demo-window" });
  const input = fakeElement("p", { "data-input": "" });
  const keys = fakeElement("p", { "data-keys": "" });
  const replay = fakeElement("button", { "data-replay": "", ...buttonAttributes });
  replay.textContent = buttonAttributes["data-label-replay"] ?? "";
  figure.found = new Map([[".demo-window", demoWindow], ["[data-input]", input], ["[data-keys]", keys], ["[data-replay]", replay]]);
  return { figure, demoWindow, input, keys, replay };
}

/** The tag templates of fakeHero and what a tag of each says (fakeTagText). */
export const FAKE_TAGS = Object.freeze({ keep: ["", "word", ": kept"], plain: ["", "word", ", not ", "plain", ""] });
export const fakeTagText = ({ text, plain }) => (plain ? `${text}, not ${plain}` : `${text}: kept`);

/** The hero as lib/pages/home/hero.mjs renders it: one sent bubble per sentence inside [data-sent]. */
export function fakeHero(demos) {
  const section = fakeElement("section", { "data-section": "hero" });
  const windowEl = fakeElement("div", { "data-hero": "", "data-demo-frames": JSON.stringify(demos) });
  const input = fakeElement("p", { "data-input": "" });
  const keys = fakeElement("span", { "data-keys": "" });
  // The tag templates as lib/pages/home/hero.mjs writes them: literal text at even indexes, a slot at odd ones.
  const tags = fakeElement("p", { "data-tags": "", "data-tag-keep": JSON.stringify(FAKE_TAGS.keep), "data-tag-plain": JSON.stringify(FAKE_TAGS.plain) });
  const sent = fakeElement("div", { "data-sent": "" });
  const bubbles = demos.map((demo) => {
    const bubble = fakeElement("p");
    bubble.textContent = demo.text;
    return bubble;
  });
  sent.append(...bubbles);
  const toggle = fakeElement("button", { "data-motion-toggle": "", "data-label-pause": "Pause", "data-label-play": "Play" });
  windowEl.ancestors = new Map([["[data-section]", section]]);
  windowEl.found = new Map([["[data-tags]", tags], ["[data-sent]", sent], ["[data-input]", input], ["[data-keys]", keys]]);
  section.found = new Map([["[data-motion-toggle]", toggle]]);
  return { section, windowEl, input, keys, tags, sent, bubbles, toggle };
}

/** The learning demo as lib/pages/home/learning.mjs renders it: one row per pass, each with its field and keys strip,
 * and the learned badge in the last row's field, which home.js moves along as that row types. */
export function fakeLearning(demo, buttonAttributes) {
  const figure = fakeElement("figure", { "data-demo": demo.id, "data-demo-frames": JSON.stringify(demo) });
  const demoWindow = fakeElement("div", { class: "demo-window" });
  const replay = fakeElement("button", { "data-replay": "", ...buttonAttributes });
  replay.textContent = buttonAttributes["data-label-replay"] ?? "";
  const badge = fakeElement("span", { class: "learned-badge" });
  badge.textContent = "Learned";
  const rows = [...(demo.teachPasses ?? []), demo].map((pass, index, all) => {
    const row = fakeElement("li", { "data-run": "" });
    const input = fakeElement("p", { "data-input": "" });
    const keys = fakeElement("p", { "data-keys": "" });
    row.found = new Map([["[data-input]", input], ["[data-keys]", keys], ...(index === all.length - 1 ? [[".learned-badge", badge]] : [])]);
    return { row, input, keys };
  });
  rows.at(-1).input.append(badge);
  figure.found = new Map([[".demo-window", demoWindow], ["[data-replay]", replay]]);
  figure.foundAll = new Map([["[data-run]", rows.map(({ row }) => row)]]);
  return { figure, demoWindow, replay, badge, rows };
}
