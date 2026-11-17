// SPDX-License-Identifier: GPL-3.0-or-later
// Home page motion (design 7.2, plan Task 6): a classic deferred script that runs after the vendored anime.js 4.5.0
// (the global `anime`, ADR 0603). The page is complete without it: every demo's final state is in the HTML
// (lib/pages/home/). With it:
// - the hero types its three sentences in rotation from data-demo-frames, the engine's frames (site/demo/frames.json):
//   the field follows each frame, the keys strip keeps the last eight keys, a tag pops in when an English word is
//   committed, and the finished message shows as sent (its bubble, reserved in the layout) before the next sentence
//   starts;
// - each behaviour demo of section 2 plays once when it scrolls into view (60 % of it, or most of what a short viewport
//   can show); its button shows as the demo starts, stops it while it plays (WCAG 2.2.2: the punctuation demo types for
//   more than five seconds) and replays it at rest; while it types, its window is hidden from screen readers (design
//   7.7), so a half-typed sentence is never read;
// - the hub threads of section 4 draw in when the hub comes into view, and a dot travels along each thread, for less
//   than five seconds per visit (WCAG 2.2.2: the hub has no pause control).
// Rules: nothing autoplays under prefers-reduced-motion and the final states stay; motion pauses off-screen and while
// the tab is hidden; the hero's button pauses and resumes it and its label says what pressing does next (a plain action
// button, no pressed state); a control shows when its owner gets data-motion-ready
// (home.css), so showing it moves nothing (design 7.8). Under the production CSP (design 4) the DOM is written with
// createElement, textContent and replaceChildren only, and styles change only through element.style (anime.js).
// The pure functions are SiteMotion, on window and for CommonJS (site/test.mjs loads them with createRequire).
(function (root, factory) {
  "use strict";
  const motion = factory();
  if (typeof module === "object" && module !== null && module.exports) module.exports = motion;
  if (!root || !root.document) return;
  root.SiteMotion = motion;
  if (root.document.readyState === "loading") root.document.addEventListener("DOMContentLoaded", () => motion.boot(root), { once: true });
  else motion.boot(root);
})(typeof window === "undefined" ? null : window, function () {
  "use strict";

  const ESCAPE = "⎋";
  const RETURN = "⏎";
  // Key notation of site/demo/script.json and the legend printed on a Mac keycap, as keyLabel of lib/demos.mjs
  // (site/test.mjs keeps the two equal, so the animated keys strip ends as the static one).
  const KEY_LABELS = new Map([[" ", "space"], [RETURN, "return"], [ESCAPE, "esc"], ["⌫", "delete"]]);
  // A key takes 80 to 110 ms (design 7.2); the key after a committed word waits a beat more, so its tag can land.
  const TIMING = Object.freeze({ keyMin: 80, keyMax: 110, commitMin: 250, commitMax: 400, escape: 700, return: 400 });
  // The keys strip keeps the last eight keycaps, as lib/pages/home/markup.mjs renders it.
  const KEYS_SHOWN = 8;
  // Hero rhythm in ms: the static first sentence stays readable before it is sent; then each sentence is typed, held,
  // sent, and the next one starts.
  const HERO = Object.freeze({ firstHold: 2200, startGap: 300, endHold: 1500, afterSend: 1100 });
  // A behaviour demo starts once 60 % of it shows, or, in a viewport too short for that, once 80 % of what the viewport
  // can show of it does (behaviourStartRatio).
  const BEHAVIOUR = Object.freeze({ startRatio: 0.6, viewportShare: 0.8, startGap: 400 });
  // The ratios the behaviour observer reports: each is at most 1.2 times the next smaller one, so the window between a
  // start ratio and the most of the figure that can show (1.25 times the start ratio) always holds one.
  const BEHAVIOUR_THRESHOLDS = Object.freeze(geometricThresholds(BEHAVIOUR.startRatio, 1.2, 0.01));
  // One visit to the hub: threads draw in, then a dot runs each thread twice; the last dot lands after about 3.5 s.
  const HUB = Object.freeze({ startRatio: 0.3, draw: 600, drawStagger: 80, dotDelay: 700, dot: 600, dotStagger: 150, dotPause: 400 });
  // UI transitions stay within 200 to 600 ms (design 7.2).
  const UI = Object.freeze({ key: 200, tag: 450, bubble: 400, fade: 200, toggle: 300 });
  const RATIO_SLACK = 0.01;
  const SVG_NS = "http://www.w3.org/2000/svg";
  const WORD_CHAR = /[\p{L}\p{M}\p{N}]/u;
  const PIECE = /[\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+/gu;

  // ---------------------------------------------------------------------------------------------------------------
  // Pure functions (site/test.mjs)

  /** A small seeded generator (mulberry32): the same seed gives the same sequence in [0, 1). */
  function seededRandom(seed) {
    let state = seed >>> 0;
    return function next() {
      state = (state + 0x6d2b79f5) >>> 0;
      let t = state;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  const between = (random, min, max) => min + Math.round(random() * (max - min));

  /** The delay in ms before each frame: 80 to 110 ms a key, 250 to 400 ms more for the key after a commit, 700 ms
   * before Escape and 400 ms before Return; the jitter comes from `seed`, so the same seed gives the same delays. */
  function schedule(frames, seed) {
    const random = seededRandom(seed);
    return frames.map((frame, index) => {
      if (frame.key === ESCAPE) return TIMING.escape;
      if (frame.key === RETURN) return TIMING.return;
      const key = between(random, TIMING.keyMin, TIMING.keyMax);
      const afterCommit = index > 0 && Boolean(frames[index - 1].commit);
      return afterCommit ? key + between(random, TIMING.commitMin, TIMING.commitMax) : key;
    });
  }

  /** The keycap legend of a key. A Mac keycap prints the same legend on both page languages, so the language argument
   * of the plan's interface (keyLabel(key, lang)) changes nothing and is not read. */
  function keyLabel(key) {
    return KEY_LABELS.has(key) ? KEY_LABELS.get(key) : key;
  }

  /** The share of a behaviour figure that starts its demo: 60 %, or less when the viewport cannot show that much of a
   * tall figure, so it still starts once mostly visible (80 % of the most that can show). */
  function behaviourStartRatio(viewportHeight, figureHeight) {
    if (!(figureHeight > 0) || !(viewportHeight > 0)) return BEHAVIOUR.startRatio;
    return Math.min(BEHAVIOUR.startRatio, (BEHAVIOUR.viewportShare * viewportHeight) / figureHeight);
  }

  /** 0 and the ratios from `top` down, each `step` times smaller than the one before, while at least `floor`. */
  function geometricThresholds(top, step, floor) {
    const ratios = [];
    for (let ratio = top; ratio >= floor; ratio /= step) ratios.push(ratio);
    return [0].concat(ratios.reverse());
  }

  /** Motion runs only for a visitor who did not ask for reduced motion, in a shown tab, on a part that is on screen. */
  function shouldAnimate({ reducedMotion, hidden, visible }) {
    return !reducedMotion && !hidden && Boolean(visible);
  }

  /** The tokens committed up to frame `index`: a commit adds one, a frame's `revised` replaces the one before it. */
  function tokensAt(frames, index) {
    return frames.slice(0, index + 1).reduce((tokens, frame) => {
      const revised = frame.revised && tokens.length > 0 ? tokens.slice(0, -1).concat([frame.revised]) : tokens;
      return frame.commit ? revised.concat([frame.commit]) : revised;
    }, []);
  }

  const isWordChar = (ch) => ch !== undefined && WORD_CHAR.test(ch);

  /** Where `word` stands as a whole word in `text` at or after `from`, or -1. */
  function findWord(text, word, from) {
    for (let at = text.indexOf(word, from); at >= 0; at = text.indexOf(word, at + 1)) {
      if (!isWordChar(text[at - 1]) && !isWordChar(text[at + word.length])) return at;
    }
    return -1;
  }

  const plainPieces = (text) => (text.match(PIECE) || []).map((piece) => ({ text: piece, english: false }));

  /** The field after frame `index`, as words and separators `{ text, english }` (with `plain` on an English word plain
   * Telex would have changed, ENG-R802, and `learned: true` on a word kept by rule learned, L9c): the words committed
   * so far carry their latest state. After the last frame this
   * is wordsOf of lib/demos.mjs, which renders the static field. */
  function fieldPieces(frames, index) {
    const text = frames[index].text;
    const placed = tokensAt(frames, index).reduce((state, token) => {
      const at = token.text ? findWord(text, token.text, state.cursor) : -1;
      if (at < 0) return state;
      const base = token.plain ? { text: token.text, english: token.english === true, plain: token.plain } : { text: token.text, english: token.english === true };
      const piece = token.rule === "learned" ? Object.assign({}, base, { learned: true }) : base;
      return { pieces: state.pieces.concat(plainPieces(text.slice(state.cursor, at)), [piece]), cursor: at + token.text.length };
    }, { pieces: [], cursor: 0 });
    return placed.pieces.concat(plainPieces(text.slice(placed.cursor)));
  }

  /** The tag state after one frame. A tag is `{ raw, at }`, `at` being the index of its token. */
  function nextTags(state, frame) {
    const last = state.tokens.length - 1;
    const revise = Boolean(frame.revised) && last >= 0;
    const was = revise && state.tokens[last].english === true;
    const now = revise && frame.revised.english === true;
    const tokens = revise ? state.tokens.slice(0, last).concat([frame.revised]) : state.tokens;
    const tags = now && !was ? state.tags.concat([{ raw: frame.revised.raw, at: last }])
      : was && !now ? state.tags.filter((tag) => tag.at !== last) : state.tags;
    if (!frame.commit) return { tokens, tags };
    const committed = frame.commit.english === true ? tags.concat([{ raw: frame.commit.raw, at: tokens.length }]) : tags;
    return { tokens: tokens.concat([frame.commit]), tags: committed };
  }

  /** The tags after each frame, in the order their words became English. */
  function tagSteps(frames) {
    let state = { tokens: [], tags: [] };
    return frames.map((frame) => {
      state = nextTags(state, frame);
      return state.tags;
    });
  }

  /** The raw keys of the English words, in the order they become English: a commit or a revision that keeps a word
   * as typed adds it, a revision that gives it back to Vietnamese takes it out. */
  function tagsFor(frames) {
    const steps = tagSteps(frames);
    return steps.length === 0 ? [] : steps[steps.length - 1].map((tag) => tag.raw);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // DOM: text nodes and elements only

  function lineNodes(doc, text) {
    return text.split("\n").flatMap((line, index) => (index > 0 ? [doc.createElement("br")] : []).concat(line ? [doc.createTextNode(line)] : []));
  }

  /** A closing Return shows on the keys strip only, as in the static field. */
  function withoutTrailingNewlines(pieces) {
    const last = pieces.length - 1;
    if (last < 0) return pieces;
    const text = pieces[last].text.replace(/\n+$/, "");
    if (text === pieces[last].text) return pieces;
    const rest = pieces.slice(0, last);
    return text ? rest.concat([{ text, english: pieces[last].english }]) : withoutTrailingNewlines(rest);
  }

  /** The field's nodes, English words in <mark> as lib/pages/home/markup.mjs writes them. */
  function fieldNodes(doc, pieces) {
    return withoutTrailingNewlines(pieces).flatMap((piece) => {
      if (!piece.english) return lineNodes(doc, piece.text);
      const mark = doc.createElement("mark");
      mark.textContent = piece.text;
      return [mark];
    });
  }

  function keycap(doc, key) {
    const cap = doc.createElement("kbd");
    cap.className = "keycap";
    cap.textContent = keyLabel(key);
    return cap;
  }

  function caretElement(doc) {
    const caret = doc.createElement("span");
    caret.className = "caret";
    caret.setAttribute("aria-hidden", "true");
    return caret;
  }

  function readFrames(el) {
    const value = JSON.parse(el.getAttribute("data-demo-frames") || "null");
    const demos = Array.isArray(value) ? value : [value];
    const valid = demos.length > 0 && demos.every((demo) => demo && Array.isArray(demo.frames) && demo.frames.length > 0);
    if (!valid) throw new Error("data-demo-frames holds no frames");
    return value;
  }

  /** Frame `index` of a demo: the field with its English words marked and the caret, and the new keycap. */
  function showFrame(view, player, frames, index) {
    const frame = frames[index];
    view.input.replaceChildren(...fieldNodes(view.doc, fieldPieces(frames, index)), view.caret);
    const cap = keycap(view.doc, frame.key);
    view.keys.append(cap);
    while (view.keys.children.length > KEYS_SHOWN) view.keys.firstElementChild.remove();
    player.animate(cap, { scale: [0.8, 1], duration: UI.key, ease: "out(3)" });
    if (frame.toggle) player.animate(view.input, { opacity: [0.35, 1], duration: UI.toggle, ease: "out(2)" });
  }

  /** The finished demo, exactly as the static page shows it. */
  function showFinal(view, frames) {
    const last = frames.length - 1;
    view.input.replaceChildren(...fieldNodes(view.doc, fieldPieces(frames, last)));
    view.keys.replaceChildren(...frames.slice(-KEYS_SHOWN).map((frame) => keycap(view.doc, frame.key)));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Players: anime.js animations and timelines that pause, resume and stop together

  /** Nothing runs until resume(). stop() cancels the timelines and completes the animations, so their elements end in
   * their final state. */
  function createPlayer(anime) {
    const live = new Map();
    let paused = true;
    function track(kind, item) {
      live.set(item, kind);
      if (!paused) item.play();
      return item;
    }
    function finished(ref, done) {
      return (self) => {
        live.delete(ref.current);
        if (done) done(self);
      };
    }
    return {
      animate(targets, params) {
        const ref = { current: null };
        ref.current = anime.animate(targets, Object.assign({}, params, { autoplay: false, onComplete: finished(ref, params.onComplete) }));
        return track("animation", ref.current);
      },
      timeline(params, build) {
        const ref = { current: null };
        ref.current = anime.createTimeline(Object.assign({}, params, { autoplay: false, onComplete: finished(ref, params.onComplete) }));
        build(ref.current);
        return track("timeline", ref.current);
      },
      pause() {
        paused = true;
        live.forEach((kind, item) => item.pause());
      },
      resume() {
        paused = false;
        live.forEach((kind, item) => item.play());
      },
      stop() {
        live.forEach((kind, item) => (kind === "timeline" ? item.cancel() : item.complete()));
        live.clear();
      },
    };
  }

  /** Reports whether `el` is on screen (any part), how much of it shows and the observer's entry, whenever the share
   * that shows crosses one of `thresholds`. */
  function watch(ctx, el, thresholds, onChange) {
    const observer = new ctx.win.IntersectionObserver((entries) => {
      entries.forEach((entry) => onChange(entry.isIntersecting, entry.intersectionRatio, entry));
    }, { threshold: thresholds });
    observer.observe(el);
  }

  const mayRun = (env, visible) => shouldAnimate({ reducedMotion: env.reducedMotion, hidden: env.hidden, visible });

  // ---------------------------------------------------------------------------------------------------------------
  // Section 1: the hero

  function tagElement(hero, raw) {
    const tag = hero.view.doc.createElement("span");
    tag.className = "tag";
    tag.textContent = `${hero.tagBefore}${raw}${hero.tagAfter}`;
    return tag;
  }

  function showTags(hero, before, after) {
    const keep = new Set(after.map((tag) => tag.at));
    const had = new Set(before.map((tag) => tag.at));
    before.filter((tag) => !keep.has(tag.at)).forEach((tag) => {
      hero.tagEls.get(tag.at).remove();
      hero.tagEls.delete(tag.at);
    });
    after.filter((tag) => !had.has(tag.at)).forEach((tag) => {
      const el = tagElement(hero, tag.raw);
      hero.tagEls.set(tag.at, el);
      hero.tags.append(el);
      hero.player.animate(el, { scale: [0.6, 1], opacity: [0, 1], duration: UI.tag, ease: "outBack(1.7)" });
    });
  }

  /** The message shows in its sent bubble, which home.css keeps in the layout, invisible, so the chat reserves the
   * tallest bubble and showing one moves nothing (design 7.8); the field empties and the tags fade for the next
   * sentence. */
  function sendMessage(hero, index) {
    const { view, player } = hero;
    hero.bubbles.forEach((bubble, at) => (bubble.style.visibility = at === index ? "visible" : ""));
    player.animate(hero.bubbles[index], { opacity: [0, 1], translateY: [12, 0], duration: UI.bubble, ease: "out(3)" });
    view.input.replaceChildren(view.caret);
    const leaving = Array.from(hero.tags.children);
    hero.tagEls.clear();
    if (leaving.length > 0) player.animate(leaving, { opacity: 0, duration: UI.fade, onComplete: () => leaving.forEach((el) => el.remove()) });
    hero.current = -1;
  }

  function heroSend(hero, index, hold) {
    const next = (index + 1) % hero.demos.length;
    hero.player.timeline({ onComplete: () => heroType(hero, next) }, (timeline) => {
      timeline.call(() => sendMessage(hero, index), hold);
      timeline.add({ duration: HERO.afterSend }, hold);
    });
  }

  function heroType(hero, index) {
    const frames = hero.demos[index].frames;
    const delays = schedule(frames, (hero.cycle += 1));
    const steps = tagSteps(frames);
    hero.current = index;
    hero.player.timeline({ onComplete: () => heroSend(hero, index, HERO.endHold) }, (timeline) => {
      frames.reduce((at, frame, i) => {
        const time = at + delays[i];
        timeline.call(() => {
          showFrame(hero.view, hero.player, frames, i);
          showTags(hero, i > 0 ? steps[i - 1] : [], steps[i]);
        }, time);
        return time;
      }, HERO.startGap);
    });
  }

  function heroUpdate(hero, env) {
    if (hero.stopped) return;
    if (hero.userPaused || !mayRun(env, hero.visible)) {
      hero.player.pause();
      return;
    }
    if (!hero.started) {
      hero.started = true;
      hero.section.setAttribute("data-motion-ready", "");
      heroSend(hero, hero.current, HERO.firstHold);
    }
    hero.player.resume();
  }

  /** Reduced motion turned on: stop, and leave the sentence in the field finished, with its keys and tags. */
  function heroSettle(hero) {
    hero.stopped = true;
    hero.player.stop();
    hero.section.removeAttribute("data-motion-ready");
    if (hero.current < 0) {
      hero.view.input.replaceChildren();
      return;
    }
    const frames = hero.demos[hero.current].frames;
    showFinal(hero.view, frames);
    hero.tagEls.clear();
    hero.tags.replaceChildren(...tagsFor(frames).map((raw) => tagElement(hero, raw)));
  }

  function wireToggle(hero, toggle, env) {
    toggle.addEventListener("click", () => {
      hero.userPaused = !hero.userPaused;
      toggle.textContent = toggle.getAttribute(hero.userPaused ? "data-label-play" : "data-label-pause");
      heroUpdate(hero, env);
    });
  }

  function setupHero(ctx) {
    const windowEl = ctx.doc.querySelector("[data-hero]");
    if (!windowEl) return null;
    const section = windowEl.closest("[data-section]");
    const tags = windowEl.querySelector("[data-tags]");
    const hero = {
      demos: readFrames(windowEl),
      section,
      view: { doc: ctx.doc, input: windowEl.querySelector("[data-input]"), keys: windowEl.querySelector("[data-keys]"), caret: caretElement(ctx.doc) },
      tags,
      tagBefore: tags.getAttribute("data-tag-before") || "",
      tagAfter: tags.getAttribute("data-tag-after") || "",
      tagEls: new Map(),
      // One sent bubble per sentence, in the order of the demos (lib/pages/home/hero.mjs).
      bubbles: Array.from(windowEl.querySelector("[data-sent]").children),
      player: createPlayer(ctx.anime),
      // The static field shows the first sentence finished; it is sent first, then the next one is typed.
      current: 0,
      cycle: 0,
      visible: false,
      userPaused: false,
      started: false,
      stopped: false,
    };
    const toggle = section.querySelector("[data-motion-toggle]");
    if (toggle) wireToggle(hero, toggle, ctx.env);
    watch(ctx, windowEl, [0], (isIntersecting) => {
      hero.visible = isIntersecting;
      heroUpdate(hero, ctx.env);
    });
    return { update: (env) => heroUpdate(hero, env), settle: () => heroSettle(hero) };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Section 2: the behaviour demos

  /** The button stops the demo while it plays and replays it at rest; its labels are in data-label-stop and
   * data-label-replay (lib/pages/home/behaviours.mjs). */
  function behaviourLabel(demo) {
    if (!demo.control) return;
    const label = demo.control.getAttribute(demo.playing ? "data-label-stop" : "data-label-replay");
    if (label) demo.control.textContent = label;
  }

  /** The finished demo as on the static page; the field gets its own height back and screen readers read it again. */
  function behaviourRest(demo) {
    demo.playing = false;
    showFinal(demo.view, demo.frames);
    demo.view.input.style.minHeight = "";
    demo.view.input.removeAttribute("aria-busy");
    if (demo.window) demo.window.removeAttribute("aria-hidden");
    behaviourLabel(demo);
  }

  function behaviourPlay(demo) {
    const { view, frames, player } = demo;
    const delays = schedule(frames, (demo.cycle += 1));
    demo.playing = true;
    // The control shows from the first frame, so the motion can be stopped (design 4, WCAG 2.2.2).
    demo.figure.setAttribute("data-motion-ready", "");
    behaviourLabel(demo);
    // The field keeps the height of its final text while it types, so nothing below it moves (design 7.8); the exact
    // height, since offsetHeight rounds.
    view.input.style.minHeight = `${view.input.getBoundingClientRect().height}px`;
    view.input.setAttribute("aria-busy", "true");
    // A screen reader never reads the half-typed sentence; the figcaption stays readable (design 7.7).
    if (demo.window) demo.window.setAttribute("aria-hidden", "true");
    view.input.replaceChildren(view.caret);
    view.keys.replaceChildren();
    player.timeline({ onComplete: () => behaviourEnd(demo) }, (timeline) => {
      frames.reduce((at, frame, index) => {
        const time = at + delays[index];
        timeline.call(() => showFrame(view, player, frames, index), time);
        return time;
      }, BEHAVIOUR.startGap);
    });
  }

  function behaviourEnd(demo) {
    demo.played = true;
    behaviourRest(demo);
  }

  /** Stop: the finished text at once; the demo does not start again by itself. */
  function behaviourStop(demo) {
    demo.player.stop();
    demo.played = true;
    behaviourRest(demo);
  }

  /** The player always mirrors the environment, playing or at rest, so a demo started later (Replay) never runs in a
   * hidden tab or off screen; the first visit that shows enough of the figure starts it. */
  function behaviourUpdate(demo, env) {
    if (demo.stopped) return;
    if (!mayRun(env, demo.visible)) {
      demo.player.pause();
      return;
    }
    if (!demo.playing && !demo.played && demo.ratio >= demo.startRatio - RATIO_SLACK) behaviourPlay(demo);
    demo.player.resume();
  }

  function behaviourPress(demo, env) {
    if (demo.stopped) return;
    if (demo.playing) behaviourStop(demo);
    else behaviourReplay(demo, env);
  }

  function behaviourReplay(demo, env) {
    demo.player.stop();
    behaviourRest(demo);
    behaviourPlay(demo);
    behaviourUpdate(demo, env);
  }

  function behaviourSettle(demo) {
    demo.stopped = true;
    demo.player.stop();
    behaviourRest(demo);
    demo.figure.removeAttribute("data-motion-ready");
  }

  function setupBehaviour(ctx, figure) {
    const demo = {
      figure,
      control: figure.querySelector("[data-replay]"),
      window: figure.querySelector(".demo-window"),
      frames: readFrames(figure).frames,
      view: { doc: ctx.doc, input: figure.querySelector("[data-input]"), keys: figure.querySelector("[data-keys]"), caret: caretElement(ctx.doc) },
      player: createPlayer(ctx.anime),
      cycle: 0,
      visible: false,
      ratio: 0,
      startRatio: BEHAVIOUR.startRatio,
      played: false,
      playing: false,
      stopped: false,
    };
    if (demo.control) demo.control.addEventListener("click", () => behaviourPress(demo, ctx.env));
    watch(ctx, figure, BEHAVIOUR_THRESHOLDS, (isIntersecting, ratio, entry) => {
      demo.visible = isIntersecting;
      demo.ratio = ratio;
      demo.startRatio = behaviourStartRatio(ctx.win.innerHeight, entry.boundingClientRect.height);
      behaviourUpdate(demo, ctx.env);
    });
    return { update: (env) => behaviourUpdate(demo, env), settle: () => behaviourSettle(demo) };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Section 4: the hub threads

  function hubDraw(hub) {
    hub.drawn = true;
    hub.player.animate(hub.drawables, { draw: ["0 0", "0 1"], duration: HUB.draw, delay: hub.anime.stagger(HUB.drawStagger), ease: "inOut(2)" });
  }

  /** A dot leaves the mark along each thread and enters its category's card, twice. */
  function hubPulse(hub, delay) {
    hub.paths.forEach((path, index) => {
      const dot = hub.doc.createElementNS(SVG_NS, "circle");
      dot.setAttribute("r", "6");
      dot.classList.add("hub-dot");
      dot.style.opacity = "0";
      hub.svg.append(dot);
      hub.dots += 1;
      const route = hub.anime.svg.createMotionPath(path);
      hub.player.animate(dot, {
        translateX: route.translateX,
        translateY: route.translateY,
        opacity: { from: 0, to: 1, duration: UI.fade },
        duration: HUB.dot,
        delay: delay + index * HUB.dotStagger,
        loop: 1,
        loopDelay: HUB.dotPause,
        ease: "inOut(2)",
        onComplete: () => {
          dot.remove();
          hub.dots -= 1;
        },
      });
    });
  }

  function hubUpdate(hub, env) {
    if (hub.stopped) return;
    if (!mayRun(env, hub.visible)) {
      hub.player.pause();
      return;
    }
    // Each visit starts one round, unless the round of the visit before is still under way (it resumes instead).
    if (hub.ratio >= HUB.startRatio - RATIO_SLACK && hub.started < hub.visits) {
      hub.started = hub.visits;
      const first = !hub.drawn;
      if (first) hubDraw(hub);
      if (hub.dots === 0) hubPulse(hub, first ? HUB.dotDelay : 0);
    }
    hub.player.resume();
  }

  /** Reduced motion turned on: the threads drawn, nothing travelling (design 7.2). */
  function hubSettle(hub) {
    hub.stopped = true;
    hub.player.stop();
    hub.drawables.forEach((path) => path.setAttribute("draw", "0 1"));
  }

  function setupHub(ctx) {
    const svg = ctx.doc.querySelector("[data-hub] .hub-threads");
    if (!svg) return null;
    const paths = Array.from(svg.querySelectorAll("[data-thread]"));
    const hub = {
      doc: ctx.doc,
      anime: ctx.anime,
      svg,
      paths,
      // createDrawable hides each thread ("0 0") until the hub comes into view and draws it in.
      drawables: ctx.anime.svg.createDrawable(paths),
      player: createPlayer(ctx.anime),
      visible: false,
      ratio: 0,
      visits: 0,
      started: 0,
      drawn: false,
      dots: 0,
      stopped: false,
    };
    // Below 900 px the drawing is not displayed (home.css), so it never comes into view and stays still.
    watch(ctx, svg, [0, HUB.startRatio], (isIntersecting, ratio) => {
      if (isIntersecting && !hub.visible) hub.visits += 1;
      hub.visible = isIntersecting;
      hub.ratio = ratio;
      hubUpdate(hub, ctx.env);
    });
    return { update: (env) => hubUpdate(hub, env), settle: () => hubSettle(hub) };
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Boot

  /** A part that fails keeps its static final state; the console names the error. */
  function safely(setup, ctx) {
    try {
      return setup(ctx);
    } catch (error) {
      ctx.win.console.error("home motion:", error);
      return null;
    }
  }

  function boot(win) {
    const doc = win.document;
    const anime = win.anime;
    if (!anime || typeof win.IntersectionObserver !== "function" || typeof win.matchMedia !== "function") return;
    const reduced = win.matchMedia("(prefers-reduced-motion: reduce)");
    // Reduced motion: no autoplay; the HTML already holds every final state and draws the threads (design 7.2).
    if (reduced.matches) return;
    const ctx = { win, doc, anime, env: { reducedMotion: false, hidden: doc.hidden } };
    const figures = Array.from(doc.querySelectorAll("figure[data-demo][data-demo-frames]"));
    const setups = [setupHero, setupHub].concat(figures.map((figure) => (c) => setupBehaviour(c, figure)));
    const parts = setups.map((setup) => safely(setup, ctx)).filter(Boolean);
    doc.addEventListener("visibilitychange", () => {
      ctx.env.hidden = doc.hidden;
      parts.forEach((part) => part.update(ctx.env));
    });
    reduced.addEventListener("change", () => {
      if (!reduced.matches) return;
      ctx.env.reducedMotion = true;
      parts.forEach((part) => part.settle());
    });
  }

  return Object.freeze({ schedule, keyLabel, shouldAnimate, tagsFor, fieldPieces, behaviourStartRatio, boot });
});
