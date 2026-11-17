// SPDX-License-Identifier: GPL-3.0-or-later
// The home page markup (design 7.3, plan Task 5) and the demo frames loader.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { keyLabel, loadDemos, wordsOf } from "../lib/demos.mjs";
import { HUB_CATEGORIES, HUB_NODES, HUB_VIEWBOX, renderApps } from "../lib/pages/home/apps.mjs";
import { LANGS, routePath } from "../lib/routes.mjs";
import { esc } from "../lib/util.mjs";
import { SITE_DIR, ROOT_DIR, attrs, section, mainOf, textOf, unescapeHtml, framesAttr, heroTag, tagsOf, tagText } from "./helpers.mjs";

/** Home page sections, compat hub and demo data. */
export async function runHomeChecks(check, fixtures) {
  const { tmp, read, framesPath, frames, homeCopy, homePages, emptyHome } = fixtures;

  // Home page (design 7.3, plan Task 5). The demo texts come from site/demo/frames.json, never from this file.
  await check("home: PRD-R73 items on / and /en/", () => {
    for (const [label, html, lang] of homePages) {
      const h = homeCopy[lang];
      const main = mainOf(html);
      assert.ok(main.includes(`<h1 id="hero-title">${esc(h.h1)}</h1>`), `${label}: the value statement is the h1`);
      const hero = section(html, "hero");
      if (label.startsWith("populated")) {
        // fixtures/populated: stable 1.0.0 with minimumSystemVersion 15.0.
        assert.match(hero, new RegExp(`<a class="btn" href="https://example\\.invalid/app-1\\.0\\.0\\.dmg">[^<]*1\\.0\\.0<small>macOS 15 Sequoia (?:trở lên|or later)</small></a>`), `${label}: download button with version and minimum macOS`);
      } else {
        assert.ok(hero.includes(`<p class="btn btn-disabled" aria-disabled="true">${esc(h.noReleaseBtn)}`), `${label}: the no-release state`);
      }
      assert.match(hero, /<code class="cmd">brew install --cask [^<\s]+\/[a-z0-9-]+<\/code>/, `${label}: brew line in the hero`);
      assert.equal((section(html, "proof").match(/<li\b/g) ?? []).length, 3, `${label}: three proof points`);
      assert.ok(main.includes(`href="${routePath("compat", lang)}"`), `${label}: a link to the compatibility page in the page body`);
      assert.ok(!/<video\b/i.test(html), `${label}: no video (design 6)`);
    }
  });

  await check("home: every demo's final text is in the static HTML (design 7.2, no JavaScript)", () => {
    for (const [label, html] of homePages) {
      const heroIds = (framesAttr(heroTag(html)) ?? []).map((demo) => demo.id);
      const used = new Set([...heroIds, ...attrs(html, "data-demo")]);
      // Demos waiting for their home section (design 9 item 4). The exception removes itself: once the page shows a
      // pending demo the check fails until the id leaves this set, and a new demo is never hidden by it.
      const pending = new Set(["learning-reset"]);
      for (const id of pending) {
        assert.ok(id in frames.demos, `${label}: pending demo ${id} is in frames.json`);
        assert.ok(!used.has(id), `${label}: ${id} is on the page now, take it out of the pending set`);
      }
      const placed = Object.keys(frames.demos).filter((id) => !pending.has(id));
      assert.deepEqual([...used].sort(), placed.sort(), `${label}: the page uses every demo of frames.json`);
      const text = textOf(mainOf(html));
      for (const id of used) {
        const final = frames.demos[id].text.replace(/\n/g, "").trim();
        assert.ok(text.includes(esc(final)), `${label}: ${id} "${final}" is not in the page text`);
      }
      // The visible demo areas themselves hold the final state, not only the visually hidden list (Review Focus 3).
      const keycaps = (demo) => demo.frames.slice(-8).map((frame) => `<kbd class="keycap">${esc(keyLabel(frame.key))}</kbd>`).join("");
      const heroWindow = html.match(/<div class="mac-window" data-hero[\s\S]*?<div class="keys-strip">[\s\S]*?<\/div>/)?.[0] ?? "";
      const chat = frames.demos["hero-chat"];
      assert.equal(unescapeHtml(textOf(heroWindow.match(/<p data-input[^>]*>([\s\S]*?)<\/p>/)?.[1] ?? "")), chat.text, `${label}: the hero field holds the first sentence`);
      assert.equal(heroWindow.match(/<span class="keys" data-keys>([\s\S]*?)<\/span><\/div>/)?.[1], keycaps(chat), `${label}: the hero keys strip holds the last 8 keys`);
      for (const figure of html.match(/<figure class="behaviour"[\s\S]*?<\/figure>/g) ?? []) {
        const demo = frames.demos[attrs(figure, "data-demo")[0]];
        assert.equal(unescapeHtml(textOf(figure.match(/<p class="demo-field" data-input[^>]*>([\s\S]*?)<\/p>/)?.[1] ?? "")), demo.text.replace(/\n+$/, ""), `${label}: ${figure.slice(0, 60)} field`);
        assert.equal(figure.match(/<p class="keys" data-keys[^>]*>([\s\S]*?)<\/p>/)?.[1], keycaps(demo), `${label}: ${figure.slice(0, 60)} keys`);
      }
    }
  });

  await check("home: motion controls hold their place without JavaScript and show only once home.js is ready (design 7.8)", async () => {
    for (const [label, html] of homePages) {
      const controls = html.match(/<button\b[^>]*\sdata-(?:motion-toggle|replay)\b[^>]*>/g) ?? [];
      assert.equal(controls.length, 4, `${label}: the pause control and three replay buttons`);
      // A hidden attribute would take the button out of the flow and move the page when home.js reveals it.
      for (const tag of controls) assert.ok(!/\shidden\b/.test(tag), `${label}: ${tag} is in the flow`);
      for (const figure of html.match(/<figure class="behaviour"[\s\S]*?<\/figure>/g) ?? []) {
        assert.match(figure, /<\/figcaption>\s*<\/figure>$/, `${label}: the figcaption is the last child of its figure`);
      }
    }
    const css = (await readFile(join(SITE_DIR, "static", "assets", "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    assert.match(css, /\.motion-toggle,\s*\.replay\s*\{\s*visibility:\s*hidden;\s*\}/, "the controls are invisible but keep their space");
    assert.match(css, /\[data-motion-ready\]\s*\.motion-toggle,\s*\[data-motion-ready\]\s*\.replay\s*\{\s*visibility:\s*visible;\s*\}/, "home.js reveals a control by marking its owner data-motion-ready");
  });

  await check("home: requirement IDs stay in data-req and never show on the page (Pa, 17/11/2026)", async () => {
    for (const [label, html, lang] of homePages) {
      const h = homeCopy[lang];
      const expected = [
        ...h.behaviours.items.filter((item) => item.note).map((item) => item.noteReq),
        ...h.cards.items.map((item) => item.req),
        h.apps.secureInput.req,
      ];
      const main = mainOf(html);
      assert.deepEqual(attrs(main, "data-req"), expected.map(esc), `${label}: the Return note, every card and the Secure Input card carry their requirement`);
      assert.ok(!/class="[^"]*\breq\b/.test(main), `${label}: no visible requirement line`);
      const visible = unescapeHtml(textOf(main));
      for (const id of new Set(expected.flatMap((req) => req.split(/,\s*/)))) {
        assert.ok(!new RegExp(`(?<![\\w-])${id}(?![\\w-])`).test(visible), `${label}: ${id} is not in the page text`);
      }
    }
    const css = (await readFile(join(SITE_DIR, "static", "assets", "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    assert.ok(!/\.req\b/.test(css), "home.css has no rule left for the removed requirement line");
  });

  await check("home: the apps intro goes through the token filler like every other intro", async () => {
    const intro = "{{AppName}} <code>Spotlight</code>";
    const apps = { ...homeCopy.vi.apps, intro };
    const ui = (await import(pathToFileURL(join(SITE_DIR, "content", "vi", "ui.mjs")).href)).default;
    const html = renderApps({ ctx: { data: { matrix: { entries: [] } } }, c: { home: { apps } }, ui, f: (text) => `[filled]${text}`, lang: "vi" });
    assert.ok(html.includes(`<p>[filled]${intro}</p>`), "apps.intro is filled, not escaped");
  });

  await check("home: data-demo-frames parses and matches frames.json", () => {
    for (const [label, html] of homePages) {
      const hero = ["hero-chat", "hero-email", "hero-note"].map((id) => ({ id, ...frames.demos[id] }));
      assert.match(heroTag(html), /^<div class="mac-window"/, `${label}: the hero window carries data-hero`);
      assert.deepEqual(framesAttr(heroTag(html)), hero, `${label}: hero frames`);
      const figures = html.match(/<figure\b[^>]*\sdata-demo="behaviour-[^"]+"[^>]*>/g) ?? [];
      assert.deepEqual(figures.map((tag) => attrs(tag, "data-demo")[0]), ["behaviour-punctuation", "behaviour-revision", "behaviour-escape"], `${label}: behaviour figures`);
      for (const tag of figures) assert.deepEqual(framesAttr(tag), frames.demos[attrs(tag, "data-demo")[0]], `${label}: ${tag.slice(0, 60)}`);
      assert.match(section(html, "behaviours"), /^<section id="(?:tinh-nang|features)"/, `${label}: the features anchor is section 2`);
    }
  });

  await check("home: tags name exactly the English words of the hero sentence", () => {
    // From frames.json: every commit adds a word; a revision replaces the word before it with its new state.
    const words = [];
    for (const frame of frames.demos["hero-chat"].frames) {
      if (frame.revised) words[words.length - 1] = frame.revised;
      if (frame.commit) words.push(frame.commit);
    }
    const english = words.filter((word) => word.english).map((word) => word.raw);
    assert.ok(english.length > 0, "the hero sentence has English words");
    for (const [label, html, lang] of homePages) {
      const row = html.match(/\sdata-tags[^>]*>([\s\S]*?)<\/p>/)?.[1] ?? "";
      const shown = tagsOf(row);
      assert.deepEqual(shown.map((tag) => unescapeHtml(textOf(tag))), english.map((raw) => tagText(homeCopy[lang].hero, words.find((word) => word.raw === raw))), label);
    }
  });

  await check("home: a kept word's tag names its plain Telex form, struck through, in words too (design 9 item 1, ENG-R802)", async () => {
    const chat = wordsOf(frames.demos["hero-chat"]).filter((piece) => piece.english);
    assert.ok(chat.length > 0 && chat.every((piece) => piece.plain), "every kept word of hero-chat has a plain form");
    for (const [label, html, lang] of homePages) {
      const copy = homeCopy[lang].hero;
      const shown = tagsOf(html.match(/\sdata-tags[^>]*>([\s\S]*?)<\/p>/)?.[1] ?? "");
      chat.forEach((piece, index) => {
        const tag = shown[index] ?? "";
        // "test, không thành tét" (en "test, not tét"): the word strong, the plain form struck through by CSS.
        assert.ok(tag.includes(`<strong>${esc(piece.text)}</strong>`), `${label}: ${piece.text} is strong in ${tag}`);
        assert.ok(tag.includes(`<span class="tag-plain">${esc(piece.plain)}</span>`), `${label}: ${piece.plain} is the struck-through plain form in ${tag}`);
        assert.equal(unescapeHtml(textOf(tag)), copy.plainTag.replace("{{word}}", piece.text).replace("{{plain}}", piece.plain), `${label}: ${piece.text}`);
      });
      // Screen readers never meet the strike alone: the scene is aria-hidden, and the hidden list says each tag in words.
      const hidden = section(html, "hero").match(/<div class="visually-hidden">([\s\S]*?)<\/div>/)?.[1] ?? "";
      for (const id of ["hero-chat", "hero-email", "hero-note"]) {
        const item = [...hidden.matchAll(/<li>([\s\S]*?)<\/li>/g)].map((m) => unescapeHtml(textOf(m[1]))).find((text) => text.startsWith(frames.demos[id].text));
        assert.ok(item, `${label}: ${id} is in the hidden list`);
        for (const piece of wordsOf(frames.demos[id]).filter((p) => p.english)) assert.ok(item.includes(tagText(copy, piece)), `${label}: ${id} says "${tagText(copy, piece)}" in words`);
      }
    }
    const css = (await readFile(join(SITE_DIR, "static", "assets", "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    assert.match(css, /\.tag-plain\s*\{[^}]*text-decoration:\s*line-through/, "home.css strikes the plain form through");
    assert.match(css, /\.tags \.tag\s*\{[^}]*color:\s*var\(--muted\)/, "the rest of the tag is muted");
    assert.match(css, /\.tags \.tag strong\s*\{[^}]*color:\s*var\(--green-text\)/, "the word stands out");
  });

  await check("home: compat hub shows categories and app names without verified wording while entries are notVerified", async () => {
    const hub = (html) => section(html, "apps");
    const nodes = (html) => [...hub(html).matchAll(/<li class="hub-node[^"]*" data-category="([^"]+)">([\s\S]*?)<\/li>/g)].map(([, category, inner]) => ({ category, inner }));
    const sample = JSON.parse(await readFile(join(SITE_DIR, "fixtures", "matrix.json"), "utf8")).entries;
    const real = JSON.parse(await readFile(join(ROOT_DIR, "compat", "matrix.json"), "utf8")).entries;
    const base = (name) => name.replace(/\s*\([^)]*\)$/, "");
    // fixtures/empty has no matrix, so its build shows the sample fixture, whose every row is notVerified.
    for (const [label, html, lang, entries] of [["empty vi", emptyHome.vi, "vi", sample], ["empty en", emptyHome.en, "en", sample], ...homePages.slice(0, 2).map(([l, h, g]) => [l, h, g, real])]) {
      // The hub names each category as the compatibility page does (ui.categories), so the two pages agree.
      const ui = (await import(pathToFileURL(join(SITE_DIR, "content", lang, "ui.mjs")).href)).default;
      assert.deepEqual(nodes(html).map((node) => node.category), [...HUB_CATEGORIES], `${label}: one node per category, in order`);
      assert.equal((hub(html).match(/<path data-thread\b/g) ?? []).length, HUB_CATEGORIES.length, `${label}: one thread per category`);
      assert.match(hub(html), /<div class="hub" data-hub>/, `${label}: the hub`);
      for (const { category, inner } of nodes(html)) {
        assert.ok(inner.startsWith(`<strong>${esc(ui.categories[category])}</strong>`), `${label}: ${category} label as on the compatibility page`);
        const names = (inner.match(/<span class="hub-apps">([^<]*)<\/span>/)?.[1] ?? "").split(", ").filter(Boolean).map(unescapeHtml);
        // The apps the maintainers ranked (tier 1 or 2) when the category has any, every app otherwise.
        const inCategory = entries.filter((entry) => entry.category === category);
        const ranked = inCategory.filter((entry) => entry.tier === 1 || entry.tier === 2);
        const pool = ranked.length > 0 ? ranked : inCategory;
        assert.ok(names.length <= 4 && names.length === Math.min(4, new Set(pool.map((entry) => base(entry.displayName))).size), `${label}: ${category} lists up to four apps`);
        for (const name of names) assert.ok(pool.some((entry) => base(entry.displayName) === name), `${label}: ${category} lists ${name}`);
        const tierOne = inCategory.filter((entry) => entry.tier === 1).map((entry) => base(entry.displayName));
        if (names.length > 0 && tierOne.length > 0) assert.ok(tierOne.includes(names[0]), `${label}: ${category} lists tier 1 first`);
      }
      if (entries.every((entry) => entry.status === "notVerified")) {
        const text = textOf(hub(html));
        assert.ok(!/kiểm tra|verif/i.test(text), `${label}: no verified wording while every entry is notVerified`);
        assert.ok(!/\d{1,2}\/\d{1,2}\/\d{4}|\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}|<time\b/.test(hub(html)), `${label}: no date`);
      }
      assert.ok(hub(html).includes(`href="${routePath("compat", lang)}"`), `${label}: link to the compatibility page`);
      assert.match(hub(html), /class="card secure-input"/, `${label}: the Secure Input card below the hub`);
    }
    assert.ok(nodes(homePages[0][1]).find((node) => node.category === "browser").inner.includes("Safari"), "the real matrix lists Safari first among browsers");
    // fixtures/populated: Safari verified on 2026-12-01 shows its date; iTerm2 (2026-06-01) is stale, so it shows none.
    const populatedHub = { vi: hub(read("index.html")), en: hub(read("en", "index.html")) };
    assert.match(populatedHub.vi, /Safari \(kiểm tra <time datetime="2026-12-01">01\/12\/2026<\/time>\)/);
    assert.match(populatedHub.en, /Safari \(verified <time datetime="2026-12-01">1 Dec 2026<\/time>\)/);
    assert.ok(!populatedHub.vi.includes("2026-06-01"), "a stale result shows no date");
  });

  await check("home: home.css places every hub node where its thread ends (design 7.3 item 4)", async () => {
    const css = (await readFile(join(SITE_DIR, "static", "assets", "home.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    assert.ok(HUB_NODES.length >= 7, "a node per category");
    HUB_NODES.forEach(({ x, y }, index) => {
      const rule = css.match(new RegExp(`\\.hub-node-${index + 1}\\s*\\{([^}]*)\\}`))?.[1] ?? "";
      const [left, top] = ["left", "top"].map((side) => Number(rule.match(new RegExp(`${side}:\\s*([\\d.]+)%`))?.[1]));
      assert.ok(Math.abs(left - (100 * x) / HUB_VIEWBOX.width) < 0.01 && Math.abs(top - (100 * y) / HUB_VIEWBOX.height) < 0.01, `.hub-node-${index + 1} sits at ${left}%, ${top}%, its thread ends at ${x}, ${y}`);
    });
    assert.match(css, new RegExp(`\\.hub\\s*\\{[^}]*aspect-ratio:\\s*${HUB_VIEWBOX.width}\\s*/\\s*${HUB_VIEWBOX.height}`), "the hub keeps the proportions of the thread drawing");
  });

  await check("home: the no-release state appears in hero and closing with site/fixtures/empty", () => {
    for (const lang of LANGS) {
      for (const name of ["hero", "closing"]) {
        const part = section(emptyHome[lang], name);
        assert.ok(part.includes(`<p class="btn btn-disabled" aria-disabled="true">${esc(homeCopy[lang].noReleaseBtn)}`), `${lang} ${name}: the disabled state`);
        assert.ok(!/<a class="btn"/.test(part), `${lang} ${name}: no download button`);
        assert.match(section(read(...(lang === "vi" ? [] : ["en"]), "index.html"), name), /<a class="btn" href="https:\/\/example\.invalid\/app-1\.0\.0\.dmg">/, `${lang} ${name}: the download button with a release`);
      }
    }
  });

  await check("demos: loadDemos rejects a frames file whose last frame differs from text", async () => {
    const loaded = await loadDemos(framesPath);
    assert.deepEqual([...loaded.byId.keys()].sort(), Object.keys(frames.demos).sort());
    const write = async (data) => { const path = join(tmp, "frames-bad.json"); await writeFile(path, JSON.stringify(data)); return path; };
    const bad = structuredClone(frames);
    bad.demos["card-telex"].text = "viet";
    await assert.rejects(async () => loadDemos(await write(bad)), /site\/demo\/frames\.json: card-telex: the last frame/);
    await assert.rejects(async () => loadDemos(await write({ ...frames, schemaVersion: 1 })), /site\/demo\/frames\.json: .*schemaVersion/, "version 1 had no teaching passes");
    const keyless = structuredClone(frames);
    delete keyless.demos["card-vni"].frames[0].key;
    await assert.rejects(async () => loadDemos(await write(keyless)), /site\/demo\/frames\.json: card-vni: /);
  });

  await check("demos: loadDemos validates the plain forms (ENG-R802) and the teaching passes (design 9)", async () => {
    const write = async (data) => { const path = join(tmp, "frames-bad.json"); await writeFile(path, JSON.stringify(data)); return path; };
    const rejects = async (message, pattern, mutate) => {
      const bad = structuredClone(frames);
      mutate(bad);
      await assert.rejects(async () => loadDemos(await write(bad)), pattern, message);
    };
    const kept = (data) => data.demos["hero-chat"].frames.find((frame) => frame.commit?.plain).commit;
    const vietnamese = (data) => data.demos["hero-chat"].frames.find((frame) => frame.commit && !frame.commit.english).commit;
    const revised = (data) => data.demos["behaviour-revision"].frames.find((frame) => frame.revised).revised;
    const learning = (data) => Object.values(data.demos).find((demo) => demo.teachPasses);
    assert.ok(kept(frames), "a hero commit names its plain form");
    assert.ok(learning(frames), "frames.json has a learning demo (design 9 item 4)");
    await rejects("plain equal to the text", /hero-chat: frame \d+: commit plain/, (data) => { kept(data).plain = kept(data).text; });
    await rejects("empty plain", /hero-chat: frame \d+: commit plain/, (data) => { kept(data).plain = ""; });
    await rejects("plain not a string", /hero-chat: frame \d+: commit plain/, (data) => { kept(data).plain = 3; });
    await rejects("plain on a word that is not English", /hero-chat: frame \d+: commit plain/, (data) => { vietnamese(data).plain = "x"; });
    await rejects("plain of a revised word", /behaviour-revision: frame \d+: revised plain/, (data) => { revised(data).plain = revised(data).text; });
    await rejects("teachPasses empty", /learning-reset: teachPasses/, (data) => { learning(data).teachPasses = []; });
    await rejects("teachPasses not an array", /learning-reset: teachPasses/, (data) => { learning(data).teachPasses = {}; });
    await rejects("teaching passes without their keys", /learning-reset: teachKeys/, (data) => { delete learning(data).teachKeys; });
    await rejects("teaching keys without the restore toggle", /learning-reset: teachKeys/, (data) => { learning(data).teachKeys = "reset"; });
    await rejects("teaching keys without passes", /learning-reset: teachKeys/, (data) => { delete learning(data).teachPasses; });
    await rejects("a pass's text differs from its last frame", /learning-reset: teaching pass 1: the last frame/, (data) => { learning(data).teachPasses[0].text = "x"; });
    await rejects("a pass without frames", /learning-reset: teaching pass 2: has no frames/, (data) => { learning(data).teachPasses[1].frames = []; });
    await rejects("a pass that is not an object", /learning-reset: teaching pass 1: is not an object/, (data) => { learning(data).teachPasses[0] = "x"; });
    await rejects("a pass frame without a key", /learning-reset: teaching pass 1: frame 0 needs/, (data) => { delete learning(data).teachPasses[0].frames[0].key; });
    // L9c: the page claims a learning only when the engine did it and every pass corrected with the restore toggle.
    await rejects("a final pass that keeps no word by rule learned", /learning-reset: .*rule learned/, (data) => {
      for (const frame of learning(data).frames) if (frame.commit?.rule === "learned") frame.commit.rule = "userChoice";
    });
    await rejects("a teaching pass without the restore toggle", /learning-reset: teaching pass 2: .*restore toggle/, (data) => {
      for (const frame of learning(data).teachPasses[1].frames) delete frame.toggle;
    });
    await rejects("a pass commit with a bad plain", /learning-reset: teaching pass 1: frame \d+: commit plain/, (data) => {
      learning(data).teachPasses[0].frames.find((frame) => frame.commit?.plain).commit.plain = "";
    });
  });

  await check("demos: wordsOf names the plain form of each kept English word; a teaching pass reads like a demo", async () => {
    const { byId } = await loadDemos(framesPath);
    // The latest state of each token, from frames.json: a commit adds one, a revision replaces the one before it.
    const latest = (demo) => demo.frames.reduce((list, frame) => {
      const revisedList = frame.revised && list.length > 0 ? [...list.slice(0, -1), frame.revised] : list;
      return frame.commit ? [...revisedList, frame.commit] : revisedList;
    }, []);
    for (const [id, demo] of byId) {
      const pieces = wordsOf(demo);
      const english = pieces.filter((piece) => piece.english).map(({ text, plain }) => ({ text, plain }));
      assert.deepEqual(english, latest(demo).filter((token) => token.english).map(({ text, plain }) => ({ text, plain })), `${id}: the plain forms of frames.json`);
      assert.ok(pieces.filter((piece) => !piece.english).every((piece) => !("plain" in piece)), `${id}: only an English word names a plain form`);
    }
    // Design 9 item 1: every kept English word of the hero sentences is one plain Telex would have changed.
    for (const id of ["hero-chat", "hero-email", "hero-note"]) {
      const english = wordsOf(byId.get(id)).filter((piece) => piece.english);
      assert.ok(english.length > 0 && english.every((piece) => piece.plain && piece.plain !== piece.text), `${id}: each English word has a plain form`);
    }
    const learners = [...byId.values()].filter((demo) => demo.teachPasses);
    assert.ok(learners.length > 0, "a learning demo");
    for (const demo of learners) {
      assert.ok(demo.teachPasses.length >= 1 && demo.teachKeys.includes("⎋"), "taught with the restore toggle");
      for (const pass of demo.teachPasses) {
        assert.equal(wordsOf(pass).map((piece) => piece.text).join(""), pass.text, "a pass goes through wordsOf like a demo");
        assert.ok(pass.frames.some((frame) => frame.toggle), "each pass corrects with Escape");
      }
      assert.ok(demo.frames.some((frame) => frame.commit?.rule === "learned"), "the final pass keeps a word by rule L9c");
      // The "remembered" mark comes from the engine (rule learned), never from the word itself.
      const learned = wordsOf(demo).filter((piece) => piece.learned);
      assert.equal(learned.length, 1, "exactly one word of the final pass is learned");
      assert.ok(learned.every((piece) => piece.learned === true && piece.english), "the learned word is kept as English");
      for (const pass of demo.teachPasses) assert.ok(wordsOf(pass).every((piece) => !("learned" in piece)), "a teaching pass learns nothing yet");
      assert.ok(Object.isFrozen(demo.teachPasses[0].frames[0]), "the passes are frozen like the demo");
    }
  });

  await check("demos: wordsOf marks the latest state of each word (a revision replaces the earlier commit)", async () => {
    const { byId } = await loadDemos(framesPath);
    const english = (demo) => wordsOf(demo).filter((piece) => piece.english).map((piece) => piece.text);
    assert.deepEqual(english(byId.get("behaviour-revision")), ["tricky", "as", "hell"], "the revision makes as English");
    assert.deepEqual(english(byId.get("card-slang")), []);
    for (const [id, demo] of byId) assert.equal(wordsOf(demo).map((piece) => piece.text).join(""), demo.text, `${id}: the pieces rebuild the text`);
    // RV4: a word restored as English that the next word gives back to Vietnamese is no longer English.
    const back = { text: "car nhà ", frames: [
      { key: " ", text: "car ", commit: { raw: "car", text: "car", english: true } },
      { key: " ", text: "cả nhà ", commit: { raw: "nhaf", text: "nhà", english: false }, revision: true, revised: { raw: "car", text: "cả", english: false } },
    ] };
    back.text = back.frames.at(-1).text;
    assert.deepEqual(english(back), []);
    assert.deepEqual(wordsOf(back).map((piece) => piece.text).join(""), "cả nhà ");
  });
}
