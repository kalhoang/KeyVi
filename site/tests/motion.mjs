// SPDX-License-Identifier: GPL-3.0-or-later
// The motion layer of the home page: the pure functions of site/static/assets/home.js and its DOM wiring against
// site/testing/fake-home.mjs.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { englishWords, keyLabel, loadDemos, wordsOf } from "../lib/demos.mjs";
import { LANGS } from "../lib/routes.mjs";
import { esc } from "../lib/util.mjs";
import { fakeAnime, fakeBehaviour, fakeElement, fakeHero, fakeTagText, fakeWindow, textOf as fakeTextOf } from "../testing/fake-home.mjs";
import { SITE_DIR, ROOT_DIR, ASSETS_DIR, siteMotion, walk, attrs, section, unescapeHtml, framesAttr, heroTag, tagsOf, tagText, textOf } from "./helpers.mjs";

// deploy/site/nginx.conf compresses at this level; the 60 KB budget of design 7.8 is measured at it.
const GZIP_LEVEL = 6;

/** Motion checks (plan Task 6, design 7.8). */
export async function runMotionChecks(check, fixtures) {
  const { fallback, fallbackPages, populated, pop, framesPath, frames, homeCopy, homePages } = fixtures;

  // Motion (plan Task 6): the pure functions of site/static/assets/home.js. Its DOM wiring is checked in a browser
  // under the production CSP (plan Task 9).
  await check("motion: schedule is deterministic and inside the timing rules", () => {
    const { schedule } = siteMotion();
    const keys = Object.values(frames.demos).flatMap((demo) => demo.frames.map((frame) => frame.key));
    assert.ok(keys.includes("⎋") && keys.includes("⏎"), "frames.json exercises the Escape and Return rules");
    for (const [id, demo] of Object.entries(frames.demos)) {
      const delays = schedule(demo.frames, 7);
      assert.deepEqual(schedule(demo.frames, 7), delays, `${id}: the same seed gives the same delays`);
      assert.equal(delays.length, demo.frames.length, `${id}: one delay per frame`);
      demo.frames.forEach((frame, index) => {
        const delay = delays[index];
        const label = `${id} frame ${index} (${JSON.stringify(frame.key)}): ${delay} ms`;
        assert.ok(Number.isInteger(delay), label);
        if (frame.key === "⎋") assert.equal(delay, 700, `${label}: Escape waits 700 ms`);
        else if (frame.key === "⏎") assert.equal(delay, 400, `${label}: Return waits 400 ms`);
        else if (demo.frames[index - 1]?.commit) assert.ok(delay >= 80 + 250 && delay <= 110 + 400, `${label}: the key after a commit waits 250 to 400 ms more`);
        else assert.ok(delay >= 80 && delay <= 110, `${label}: a key takes 80 to 110 ms`);
      });
    }
    const chat = frames.demos["hero-chat"].frames;
    assert.notDeepEqual(schedule(chat, 1), schedule(chat, 2), "the seed varies the jitter");
  });

  await check("motion: keyLabel and tagsFor", async () => {
    const { keyLabel: motionKeyLabel, tagsFor } = siteMotion();
    for (const lang of LANGS) {
      assert.deepEqual([" ", "⏎", "⎋", "a", "6"].map((key) => motionKeyLabel(key, lang)), ["space", "return", "esc", "a", "6"], lang);
      // The animated keys strip ends as the static one: the legend of lib/demos.mjs for every key of frames.json.
      for (const demo of Object.values(frames.demos)) for (const { key } of demo.frames) assert.equal(motionKeyLabel(key, lang), keyLabel(key), `${lang}: ${key}`);
    }
    const chat = frames.demos["hero-chat"].frames;
    const english = chat.filter((frame) => frame.commit?.english).map((frame) => frame.commit.raw);
    assert.ok(english.length > 0, "the hero sentence has English words");
    assert.deepEqual(tagsFor(chat), english, "hero-chat: its English commits, in order");
    // Every demo's tags end as the static page's (englishWords, the words in <mark> and the hero tags).
    const { byId } = await loadDemos(framesPath);
    for (const [id, demo] of byId) assert.deepEqual(tagsFor(demo.frames), englishWords(demo), id);
    assert.deepEqual(tagsFor(byId.get("behaviour-revision").frames), ["tricky", "as", "hell"], "a revision that restores adds its word");
    // RV4: the next word gives a restored word back to Vietnamese, so its tag goes.
    const back = [
      { key: " ", text: "car ", commit: { raw: "car", text: "car", english: true } },
      { key: " ", text: "cả nhà ", commit: { raw: "nhaf", text: "nhà", english: false }, revision: true, revised: { raw: "car", text: "cả", english: false } },
    ];
    assert.deepEqual(tagsFor(back.slice(0, 1)), ["car"]);
    assert.deepEqual(tagsFor(back), []);
  });

  await check("motion: shouldAnimate is false under reduced motion, hidden tab or off-screen", () => {
    const { shouldAnimate } = siteMotion();
    for (const reducedMotion of [false, true]) {
      for (const hidden of [false, true]) {
        for (const visible of [false, true]) {
          const state = { reducedMotion, hidden, visible };
          assert.equal(shouldAnimate(state), !reducedMotion && !hidden && visible, JSON.stringify(state));
        }
      }
    }
  });

  await check("motion: the animated field ends as the static field (fieldPieces and wordsOf)", async () => {
    const { fieldPieces } = siteMotion();
    const { byId } = await loadDemos(framesPath);
    for (const [id, demo] of byId) assert.deepEqual(fieldPieces(demo.frames, demo.frames.length - 1), wordsOf(demo), id);
    // Before the revision the field shows what the commit of `as` made of it; the revision makes it English.
    const revision = byId.get("behaviour-revision").frames;
    const at = revision.findIndex((frame) => frame.revision);
    assert.ok(fieldPieces(revision, at - 1).some((piece) => piece.text === "á" && !piece.english), "á before the revision");
    assert.ok(fieldPieces(revision, at).some((piece) => piece.text === "as" && piece.english), "as, English, after it");
    for (const [id, demo] of byId) {
      demo.frames.forEach((frame, index) => assert.equal(fieldPieces(demo.frames, index).map((piece) => piece.text).join(""), frame.text, `${id} frame ${index}`));
    }
  });

  await check("motion: first-party scripts never write markup or style attributes", async () => {
    // Review Focus 1: the production CSP drops such writes silently. Every script of site/static/assets but the
    // vendored anime.js: home.js, matrix.js and the donate page's copy.js (plan Task 7).
    const forbidden = ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", 'setAttribute("style"', "setAttribute('style'", "cssText", "eval(", "new Function", "splitText", "scrambleText"];
    const scripts = (await walk(ASSETS_DIR)).filter((file) => file.endsWith(".js") && !file.startsWith(join(ASSETS_DIR, "vendor") + "/"));
    for (const name of ["home.js", "copy.js"]) assert.ok(scripts.some((file) => file.endsWith(`/${name}`)), `${name} is among them`);
    for (const file of scripts) {
      const text = await readFile(file, "utf8");
      assert.deepEqual(forbidden.filter((name) => text.includes(name)), [], file.slice(SITE_DIR.length + 1));
    }
  });

  await check("motion: home.js uses only what the vendored anime.js 4.5.0 exports", async () => {
    const bundle = await readFile(join(ASSETS_DIR, "vendor", "anime.umd.min.js"), "utf8");
    // The code only: comments name the library as "anime.js".
    const home = (await readFile(join(ASSETS_DIR, "home.js"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    const svgName = bundle.match(/\bt\.svg=(\w+)/)?.[1];
    const svgKeys = (bundle.match(new RegExp(`\\b${svgName}=Object\\.freeze\\(\\{__proto__:null,([^}]*)\\}`))?.[1] ?? "").split(",").map((pair) => pair.split(":")[0]);
    const used = [...home.matchAll(/\banime\.(\w+)(?:\.(\w+))?/g)];
    assert.ok(used.length > 0, "home.js calls anime.js");
    for (const [whole, name, member] of used) {
      assert.ok(bundle.includes(`t.${name}=`), `${whole}: anime.${name} is not exported`);
      if (name === "svg") assert.ok(svgKeys.includes(member), `${whole}: anime.svg.${member} is not exported`);
    }
  });

  await check("motion: the markup home.js drives is on both home pages (plan Task 5 contract)", () => {
    for (const [label, html, lang] of homePages) {
      const hero = section(html, "hero");
      const copy = homeCopy[lang].hero;
      for (const hook of ["data-input", "data-keys", "data-tags"]) assert.match(hero, new RegExp(`\\s${hook}[\\s>]`), `${label}: hero ${hook}`);
      // One sent bubble per hero sentence, stacked in one cell, so the window reserves the tallest (design 7.8).
      const sent = hero.match(/<div class="chat-sent" data-sent>([\s\S]*?)<\/div>/)?.[1] ?? "";
      const bubbles = [...sent.matchAll(/<p class="bubble bubble-out"><span\b[^>]*>([^<]*)<\/span><span class="chat-status">/g)].map((m) => unescapeHtml(m[1]));
      assert.deepEqual(bubbles, (framesAttr(heroTag(html)) ?? []).map((demo) => demo.text), `${label}: a sent bubble for each hero sentence, in order`);
      assert.ok(!/\shidden[\s>]/.test(sent), `${label}: the sent bubbles keep their place in the flow`);
      // The tags row reserves the most rows any sentence needs: an invisible copy of each sentence's tags shares its cell.
      const cell = hero.match(/<div class="tags-cell">([\s\S]*?)<\/div>/)?.[1] ?? "";
      const sizers = [...cell.matchAll(/<p class="tags tags-sizer">([\s\S]*?)<\/p>/g)].map((m) => tagsOf(m[1]).map((tag) => unescapeHtml(textOf(tag))));
      const expected = (framesAttr(heroTag(html)) ?? []).map((demo) => wordsOf(demo).filter((piece) => piece.english).map((piece) => tagText(copy, piece)));
      assert.deepEqual(sizers, expected, `${label}: a tag sizer for each hero sentence`);
      assert.match(cell, /<p class="tags" data-tags\b/, `${label}: the live tags share the sizers' cell`);
      const toggle = hero.match(/<button\b[^>]*\sdata-motion-toggle\b[^>]*>/)?.[0] ?? "";
      assert.deepEqual([attrs(toggle, "data-label-pause")[0], attrs(toggle, "data-label-play")[0]], [esc(copy.pause), esc(copy.play)], `${label}: the toggle carries both labels`);
      // A plain action button: its label says what pressing does, so a pressed state would contradict it (WCAG 4.1.2);
      // it is described by the hidden caption, so it says what it pauses.
      assert.ok(!/\saria-pressed=/.test(toggle), `${label}: the pause button has no aria-pressed`);
      const describedBy = attrs(toggle, "aria-describedby")[0] ?? "";
      assert.match(hero, new RegExp(`<div class="visually-hidden"><p id="${describedBy}">${esc(copy.caption)}</p>`), `${label}: the pause button is described by the hero caption`);
      // The two tag templates as parts, literal text at even indexes and a slot at odd ones, so a tag home.js writes reads
      // like a static one (design 9 item 1).
      const tags = hero.match(/<p class="tags" data-tags[^>]*>/)?.[0] ?? "";
      const [keep, plain] = ["data-tag-keep", "data-tag-plain"].map((name) => JSON.parse(unescapeHtml(attrs(tags, name)[0] ?? "null")));
      const fill = (parts, values) => (parts ?? []).map((part, index) => (index % 2 === 0 ? part : values[part])).join("");
      assert.equal(fill(keep, { word: "online" }), copy.keepTag.replace("{{word}}", "online"), `${label}: data-tag-keep`);
      assert.equal(fill(plain, { word: "test", plain: "tét" }), copy.plainTag.replace("{{word}}", "test").replace("{{plain}}", "tét"), `${label}: data-tag-plain`);
      assert.deepEqual([keep.filter((part, index) => index % 2 === 1), plain.filter((part, index) => index % 2 === 1)], [["word"], ["word", "plain"]], `${label}: the slots of each template`);
      for (const figure of html.match(/<figure class="behaviour"[\s\S]*?<\/figure>/g) ?? []) {
        for (const hook of ["data-input", "data-keys", "data-replay"]) assert.match(figure, new RegExp(`\\s${hook}[\\s>]`), `${label}: ${figure.slice(0, 60)} ${hook}`);
        // The button is the demo's stop control while it plays and its replay button at rest (WCAG 2.2.2).
        const button = figure.match(/<button\b[^>]*\sdata-replay\b[^>]*>/)?.[0] ?? "";
        const behaviours = homeCopy[lang].behaviours;
        assert.deepEqual([attrs(button, "data-label-replay")[0], attrs(button, "data-label-stop")[0]], [esc(behaviours.replay), esc(behaviours.stop)], `${label}: ${figure.slice(0, 60)} replay and stop labels`);
        // The three buttons share their label; each is described by its figure's title, so they read apart.
        const titleId = figure.match(/<h3 id="([^"]+)">/)?.[1];
        assert.ok(titleId && attrs(button, "aria-describedby")[0] === titleId, `${label}: ${figure.slice(0, 60)} the button is described by its title`);
        // home.js hides the demo window from screen readers while it types (design 7.7).
        assert.match(figure, /<div class="demo-window">/, `${label}: ${figure.slice(0, 60)} the demo window`);
      }
      assert.match(section(html, "apps"), /<svg class="hub-threads"[^>]*>(?:<path data-thread d="[^"]+"\/>){7}<\/svg>/, `${label}: the hub threads`);
    }
  });

  // The DOM wiring of home.js, run against site/testing/fake-home.mjs: a recording anime.js whose timelines run by hand.
  const bootFake = (setup) => {
    const anime = fakeAnime();
    const win = fakeWindow(anime);
    setup(win);
    siteMotion().boot(win);
    return { anime, win };
  };

  await check("motion: a behaviour demo shows a stop control from its first frame and stops at once (WCAG 2.2.2)", () => {
    const { schedule } = siteMotion();
    // The punctuation demo types for more than 5 s (design 4, WCAG 2.2.2), so its figure needs the control while it plays.
    const punctuation = frames.demos["behaviour-punctuation"];
    const longest = Math.max(...Array.from({ length: 50 }, (unused, seed) => schedule(punctuation.frames, seed + 1).reduce((sum, delay) => sum + delay, 0)));
    assert.ok(longest > 5000, `behaviour-punctuation types for ${longest} ms`);
    for (const id of ["behaviour-punctuation", "behaviour-revision", "behaviour-escape"]) {
      const demo = { id, ...frames.demos[id] };
      const final = demo.text.replace(/\n+$/, "");
      const parts = fakeBehaviour(demo, { "data-label-replay": "Replay", "data-label-stop": "Stop" });
      const { anime, win } = bootFake((w) => w.document.foundAll.set("figure[data-demo][data-demo-frames]", [parts.figure]));
      win.show(parts.figure, 1);
      assert.equal(anime.timelines.length, 1, `${id}: plays when it scrolls into view`);
      assert.ok(parts.figure.hasAttribute("data-motion-ready"), `${id}: the control shows as the demo starts`);
      assert.equal(parts.replay.textContent, "Stop", `${id}: and it reads Stop while the demo plays`);
      anime.timelines[0].run(2);
      assert.notEqual(parts.input.children.map(fakeTextOf).join(""), final, `${id}: typing`);
      // Design 7.7: a screen reader never reads the half-typed sentence; the figcaption stays readable.
      assert.equal(parts.demoWindow.getAttribute("aria-hidden"), "true", `${id}: the demo window is hidden from screen readers while it types`);
      parts.replay.dispatch("click");
      assert.ok(anime.timelines[0].cancelled, `${id}: Stop cancels the typing`);
      assert.equal(parts.input.children.map(fakeTextOf).join(""), final, `${id}: Stop leaves the finished text`);
      assert.ok(!parts.demoWindow.hasAttribute("aria-hidden"), `${id}: the finished text is readable again`);
      assert.equal(parts.replay.textContent, "Replay", `${id}: then the button replays`);
      win.show(parts.figure, 0);
      win.show(parts.figure, 1);
      assert.equal(anime.timelines.length, 1, `${id}: a stopped demo does not start again by itself`);
      parts.replay.dispatch("click");
      assert.equal(anime.timelines.length, 2, `${id}: Replay plays it again`);
      assert.equal(parts.replay.textContent, "Stop", `${id}: Stop while it replays`);
      assert.equal(parts.demoWindow.getAttribute("aria-hidden"), "true", `${id}: hidden again while it replays`);
      anime.timelines[1].run();
      assert.equal(parts.input.children.map(fakeTextOf).join(""), final, `${id}: ends on the finished text`);
      assert.ok(!parts.demoWindow.hasAttribute("aria-hidden"), `${id}: readable once it rests`);
      assert.equal(parts.replay.textContent, "Replay", `${id}: Replay once it has played`);
      assert.ok(parts.figure.hasAttribute("data-motion-ready"), `${id}: the control stays`);
    }
  });

  await check("motion: Replay in a hidden tab waits until the tab shows again (design 7.2)", () => {
    const demo = { id: "behaviour-revision", ...frames.demos["behaviour-revision"] };
    const parts = fakeBehaviour(demo, { "data-label-replay": "Replay", "data-label-stop": "Stop" });
    const { anime, win } = bootFake((w) => w.document.foundAll.set("figure[data-demo][data-demo-frames]", [parts.figure]));
    win.show(parts.figure, 1);
    anime.timelines[0].run();
    assert.equal(parts.replay.textContent, "Replay", "the demo played and rests");
    win.setHidden(true);
    parts.replay.dispatch("click");
    assert.equal(anime.timelines.length, 2, "Replay makes a new timeline");
    assert.equal(anime.timelines[1].playing, false, "it does not play while the tab is hidden");
    win.setHidden(false);
    assert.equal(anime.timelines[1].playing, true, "it plays once the tab shows again");
    win.show(parts.figure, 0);
    assert.equal(anime.timelines[1].playing, false, "and pauses off screen");
  });

  await check("motion: a behaviour demo taller than the viewport still starts once mostly visible", () => {
    const { behaviourStartRatio } = siteMotion();
    assert.equal(behaviourStartRatio(800, 300), 0.6, "a figure that fits starts at 60 % visible");
    assert.equal(behaviourStartRatio(800, 0), 0.6, "an unmeasured figure keeps 60 %");
    const demo = { id: "behaviour-escape", ...frames.demos["behaviour-escape"] };
    const parts = fakeBehaviour(demo, { "data-label-replay": "Replay", "data-label-stop": "Stop" });
    // 800 px of viewport over a 2000 px figure: at most 40 % of it ever shows, so it starts at 0.8 * 0.4 = 32 %.
    parts.figure.getBoundingClientRect = () => ({ height: 2000, width: 300, top: 0, left: 0 });
    const { anime, win } = bootFake((w) => w.document.foundAll.set("figure[data-demo][data-demo-frames]", [parts.figure]));
    const thresholds = win.observersOf(parts.figure).flatMap((observer) => observer.options.threshold ?? []);
    assert.ok(thresholds.some((t) => t >= 0.32 && t <= 0.4), `the observer reports a ratio between 32 % and 40 %: ${thresholds.join(", ")}`);
    win.show(parts.figure, 0.3);
    assert.equal(anime.timelines.length, 0, "not yet at 30 %");
    win.show(parts.figure, 0.35);
    assert.equal(anime.timelines.length, 1, "starts at 35 % of a figure that never shows more than 40 %");
    assert.equal(anime.timelines[0].playing, true, "and plays");
  });

  await check("motion: the hero pause button swaps its label, has no pressed state and names what it pauses", () => {
    const demos = ["hero-chat", "hero-email", "hero-note"].map((id) => ({ id, ...frames.demos[id] }));
    const parts = fakeHero(demos);
    const { anime, win } = bootFake((w) => w.document.found.set("[data-hero]", parts.windowEl));
    win.show(parts.windowEl, 1);
    assert.equal(anime.timelines.at(-1).playing, true, "the hero plays");
    parts.toggle.dispatch("click");
    assert.equal(parts.toggle.textContent, "Play", "paused: the label says what pressing does next");
    assert.ok(!parts.toggle.hasAttribute("aria-pressed"), "no pressed state to contradict the label");
    assert.equal(anime.timelines.at(-1).playing, false, "the hero pauses");
    parts.toggle.dispatch("click");
    assert.equal(parts.toggle.textContent, "Pause", "playing again: Pause");
    assert.ok(!parts.toggle.hasAttribute("aria-pressed"), "still no pressed state");
    assert.equal(anime.timelines.at(-1).playing, true, "the hero resumes");
  });

  await check("motion: reduced motion turned on mid-sentence settles the hero on the finished sentence (design 7.2)", () => {
    const demos = ["hero-chat", "hero-email", "hero-note"].map((id) => ({ id, ...frames.demos[id] }));
    const parts = fakeHero(demos);
    const { anime, win } = bootFake((w) => w.document.found.set("[data-hero]", parts.windowEl));
    win.show(parts.windowEl, 1);
    anime.timelines.at(-1).run();
    const typing = anime.timelines.at(-1);
    typing.run(Math.floor(typing.calls.length / 2));
    const live = anime.animations.filter((animation) => !animation.completed);
    assert.ok(live.length > 0, "animations are under way mid-sentence");
    win.reduceMotion();
    assert.ok(typing.cancelled, "the typing stops");
    assert.ok(live.every((animation) => animation.completed), "stop() completes every live animation, so each element ends in its final state");
    const second = demos[1];
    assert.equal(parts.input.children.map(fakeTextOf).join(""), second.text.replace(/\n+$/, ""), "the field shows the finished sentence");
    assert.deepEqual(parts.tags.children.map(fakeTextOf), wordsOf(second).filter((piece) => piece.english).map(fakeTagText), "the tags name the sentence's English words and their plain forms");
    // Design 9 item 1: the word strong, the plain form in its own struck-through span, as the static tags.
    for (const [index, piece] of wordsOf(second).filter((p) => p.english).entries()) {
      const tag = parts.tags.children[index];
      assert.equal(tag.children.find((child) => child.tagName === "STRONG")?.textContent, piece.text, `${piece.text} is strong`);
      assert.equal(tag.children.find((child) => child.className === "tag-plain")?.textContent, piece.plain, `${piece.plain} is the plain form`);
    }
    assert.ok(!parts.section.hasAttribute("data-motion-ready"), "the pause button goes, nothing moves any more");
  });

  await check("motion: sending a hero message shows a reserved bubble and moves nothing (design 7.8)", async () => {
    const demos = ["hero-chat", "hero-email", "hero-note"].map((id) => ({ id, ...frames.demos[id] }));
    const parts = fakeHero(demos);
    // The static tags of the first sentence, as lib/pages/home/hero.mjs renders them.
    const staticTags = wordsOf(demos[0]).filter((piece) => piece.english).map((piece) => Object.assign(fakeElement("span", { class: "tag" }), { textContent: fakeTagText(piece) }));
    parts.tags.append(...staticTags);
    const { anime, win } = bootFake((w) => w.document.found.set("[data-hero]", parts.windowEl));
    win.show(parts.windowEl, 1);
    const shown = () => parts.bubbles.map((bubble) => bubble.style.visibility === "visible");
    assert.deepEqual(shown(), [false, false, false], "nothing sent before the first send");
    anime.timelines.at(-1).run();
    assert.deepEqual(shown(), [true, false, false], "the first sentence is sent");
    assert.ok(staticTags.length > 0 && staticTags.every((tag) => tag.parent === parts.tags), "the first sentence's tags fade out first");
    anime.animations.filter((animation) => !animation.completed).forEach((animation) => animation.complete());
    assert.ok(staticTags.every((tag) => tag.parent === null), "the faded tags are removed once their fade completes");
    assert.deepEqual(parts.tags.children, [], "the next sentence starts with no tag");
    anime.timelines.at(-1).run();
    anime.timelines.at(-1).run();
    assert.deepEqual(shown(), [false, true, false], "the second sentence replaces it in the same place");
    assert.equal(parts.sent.hidden, undefined, "home.js never takes the sent cell out of the flow");
    assert.ok(parts.bubbles.every((bubble) => bubble.hidden === undefined && bubble.textContent === demos[parts.bubbles.indexOf(bubble)].text), "the bubbles keep their sentences");
    // home.css: the chat grows to hold the tallest bubble instead of clipping the peer's message at a fixed height.
    const css = (await readFile(join(ASSETS_DIR, "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    const chat = css.match(/\.chat\s*\{([^}]*)\}/)?.[1] ?? "";
    assert.ok(!/(?:^|;)\s*height:/.test(chat) && !/overflow:\s*hidden/.test(chat), `.chat has no fixed height and clips nothing: ${chat}`);
    assert.match(css, /\.chat-sent\s*>\s*\.bubble-out\s*\{[^}]*grid-area:\s*1\s*\/\s*1;[^}]*visibility:\s*hidden;/, "the bubbles share one cell, invisible until sent");
    assert.match(css, /\.tags-cell\s*>\s*\.tags\s*\{[^}]*grid-area:\s*1\s*\/\s*1;/, "the tags share one cell with their sizers");
    assert.match(css, /\.tags-sizer\s*\{[^}]*visibility:\s*hidden;/, "the sizers reserve space without showing");
  });

  await check("motion: the keys strip fades its clipped left edge, so a cut keycap never shows as a sliver", async () => {
    const css = (await readFile(join(ASSETS_DIR, "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    const keys = css.match(/(?:^|\})\s*\.keys\s*\{([^}]*)\}/)?.[1] ?? "";
    assert.match(keys, /justify-content:\s*flex-end;[^]*overflow:\s*hidden;/, "the strip keeps the newest keys and clips the oldest at the left");
    for (const property of ["-webkit-mask-image", "mask-image"]) {
      assert.match(keys, new RegExp(`(?:^|;)\\s*${property}:\\s*linear-gradient\\(to right, transparent( [0-9.]+rem)?, #000 [0-9.]+rem\\);`), `.keys ${property}: a fade from the left edge`);
    }
  });

  await check("motion: home page JavaScript is at most 60 KB gzipped (design 7.8)", async () => {
    // The fallback build, whose config has no analytics; the Umami tag of site/config.json is not part of the page.
    // Measured at the gzip_comp_level of deploy/site/nginx.conf, the level the container serves.
    const nginx = await readFile(join(ROOT_DIR, "deploy", "site", "nginx.conf"), "utf8");
    assert.match(nginx, new RegExp(`^\\s*gzip_comp_level ${GZIP_LEVEL};`, "m"), `nginx compresses at level ${GZIP_LEVEL}`);
    for (const page of ["index.html", join("en", "index.html")]) {
      const html = await readFile(join(fallback, page), "utf8");
      const tags = html.match(/<script\b[^>]*>/g) ?? [];
      const sources = tags.map((tag) => attrs(tag, "src")[0] ?? "");
      assert.deepEqual(sources.map((src) => src.split("?")[0]), ["/assets/vendor/anime.umd.min.js", "/assets/home.js"], `${page}: anime.js, then home.js`);
      for (const tag of tags) assert.match(tag, /\sdefer[\s>]/, `${page}: ${tag} is deferred`);
      const sizes = await Promise.all(sources.map(async (src) => gzipSync(await readFile(join(fallback, src.split("?")[0])), { level: GZIP_LEVEL }).length));
      const total = sizes.reduce((sum, size) => sum + size, 0);
      assert.ok(total <= 61440, `${page}: ${total} bytes gzipped (${sizes.join(" + ")})`);
    }
  });

  await check("motion: scripts only on the home pages", () => {
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      for (const [file, html] of pages) {
        const page = file.slice(dist.length + 1);
        const home = page === "index.html" || page === "en/index.html";
        const found = ["/assets/vendor/anime.umd.min.js", "/assets/home.js"].filter((src) => html.includes(src));
        assert.deepEqual(found, home ? ["/assets/vendor/anime.umd.min.js", "/assets/home.js"] : [], page);
      }
    }
  });
}
