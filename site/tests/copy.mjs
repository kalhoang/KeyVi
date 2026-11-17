// SPDX-License-Identifier: GPL-3.0-or-later
// Home and page copy, the donate page (PRD-R59) and copy.js.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { loadBrand } from "../lib/brand.mjs";
import { LANGS } from "../lib/routes.mjs";
import { fakeElement } from "../testing/fake-home.mjs";
import { SITE_DIR, ROOT_DIR, ASSETS_DIR, attrs, isReleaseNotesPage, mainOf, unescapeHtml, pageText, plainText } from "./helpers.mjs";

/** Content, donate and copy checks. */
export async function runCopyChecks(check, fixtures) {
  const { fallback, fallbackPages, populated, pop, read, frames } = fixtures;

  await check("content: home copy has the same keys in vi and en, vi pages use file not tệp, and home has no dash characters", async () => {
    const viPages = await import(pathToFileURL(join(SITE_DIR, "content", "vi", "pages.mjs")).href);
    const load = async (lang) => (await import(pathToFileURL(join(SITE_DIR, "content", lang, "pages.mjs")).href)).home;
    const [vi, en] = [await load("vi"), await load("en")];
    // The shape of the copy: object keys and array lengths, recursively, with the type of every leaf.
    const shape = (value) => (Array.isArray(value) ? value.map(shape)
      : value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, shape(value[key])])) : typeof value);
    assert.deepEqual(shape(en), shape(vi), "the en home copy has the keys of the vi copy");
    const strings = (value) => (typeof value === "string" ? [value] : value && typeof value === "object" ? Object.values(value).flatMap(strings) : []);
    // Every vi page of pages.mjs, so the home and download pages agree; no copy here quotes a macOS pane (PRD-R62, PRD-R64).
    assert.deepEqual(strings(viPages).filter((text) => /tệp/i.test(text)), [], "vi pages say file, never tệp");
    for (const [lang, home] of [["vi", vi], ["en", en]]) assert.deepEqual(strings(home).filter((text) => /[\u2013\u2014]/.test(text)), [], `${lang}: em or en dash`);
    assert.equal(vi.h1, "Gõ tiếng Việt lẫn tiếng Anh, không cần chuyển.");
    assert.equal(en.h1, "Type Vietnamese and English without switching.");
    // The section headings of design 7.3 and the ids the renderers and frames.json share (plan Task 4).
    assert.deepEqual([vi.behaviours.heading, vi.cards.heading, vi.apps.heading, vi.proofHeading, vi.install.heading],
      ["Một câu, hai thứ tiếng", "Gõ theo cách của bạn", "Chạy trong app bạn dùng hằng ngày", "Ba điều bạn có thể kiểm chứng", "Cài trong một phút"]);
    assert.deepEqual(vi.behaviours.items.map((item) => item.id), ["punctuation", "revision", "escape"]);
    assert.deepEqual(vi.cards.items.map((item) => item.id), ["anywhere", "slang", "method", "macros", "layouts", "perApp"]);
    assert.ok(!("categories" in vi.apps) && !("categories" in en.apps), "the hub takes its category names from ui.categories, as the compatibility page does");
    assert.deepEqual(vi.cards.items.flatMap((item) => item.demos ?? []), ["card-anywhere", "card-slang", "card-telex", "card-vni", "card-traditional", "card-modern"]);
    assert.ok(vi.hero.keepTag.includes("{{word}}") && en.hero.keepTag.includes("{{word}}"), "keepTag names the word");
    // Design 9 item 1: a kept word's tag names what plain Telex would have typed; the caption says so; the peer's message
    // is Vietnamese on both pages.
    assert.deepEqual([vi.hero.plainTag, en.hero.plainTag], ["{{word}}, không thành {{plain}}", "{{word}}, not {{plain}}"]);
    assert.equal(vi.hero.caption, "Ví dụ gõ Telex một mạch, không chuyển chế độ. Từ tiếng Anh giữ nguyên, kể cả những từ mà Telex thông thường biến thành chữ khác:");
    assert.equal(en.hero.caption, "Example typed in Telex in one go, with no mode switch. English words stay as typed, even the ones plain Telex would turn into other words:");
    assert.deepEqual([vi.hero.peerMessage, en.hero.peerMessage], ["Kế hoạch tuần này sao rồi?", "Kế hoạch tuần này sao rồi?"]);
    assert.equal(vi.install.steps.length, 3);
    // Step 2 names the permission as the download page does, with its VERIFY marker (design 7.3 item 6).
    const download = (await import(pathToFileURL(join(SITE_DIR, "content", "vi", "pages.mjs")).href)).download;
    for (const name of [...download.reqPermission.matchAll(/<strong>([^<]+)<\/strong>/g)].map((m) => m[1]).concat("{{verifyHtml}}")) assert.ok(vi.install.steps[1].includes(name), `install step 2: ${name}`);
    for (const retired of ["demoPlaceholder", "demoCaption", "demoAlt", "typed", "why"]) assert.ok(!(retired in vi) && !(retired in en), `${retired} is retired`);
  });

  // Donate page (PRD-R59, design 7.5, plan Task 7): the in-app copy, verbatim from the spec in Vietnamese and from the
  // app's catalog in English, with the bank details, the share text and the VietQR code.
  const brand = await loadBrand(join(ROOT_DIR, "scripts", "brand.env"));
  const named = brand.name + brand.trademarkSign;
  const siteUrl = `https://${brand.host}`;
  const donatePages = [["vi", read("ung-ho", "index.html")], ["en", read("en", "donate", "index.html")]];
  // The backquoted strings of PRD-R59, tokens filled as the site fills them ({{app-slug}}.kal.vn is the site host).
  const prdR59 = (await readFile(join(ROOT_DIR, "spec", "03-product.md"), "utf8")).split("\n").find((line) => line.startsWith("PRD-R59 ")) ?? "";
  const fillSpec = (text) => text.replaceAll("https://{{app-slug}}.kal.vn", siteUrl).replaceAll("{{AppNameTM}}", named).replaceAll("{{AppName}}", brand.name);
  const specQuotes = [...prdR59.matchAll(/`([^`]+)`/g)].map((m) => m[1]).filter((quote) => !quote.startsWith("/") && quote !== "sponsorsUrl").map(fillSpec);
  const specShare = { vi: specQuotes.find((quote) => quote.startsWith("Giới thiệu")), en: specQuotes.find((quote) => quote.startsWith("Check out")) };
  // The English of the in-app block: Support.xcstrings, its %@ filled as the catalog comments say.
  const supportCatalog = JSON.parse(await readFile(join(ROOT_DIR, "App", "Resources", "Localization", "Support.xcstrings"), "utf8"));
  const catalogArgs = { title: [named], body: [named], howTo: [brand.name], accountTitle: [], shareTitle: [], shareText: [named, siteUrl], copy: [], share: [] };
  const catalogEn = Object.entries(catalogArgs).map(([key, args]) => {
    const value = supportCatalog.strings[`support.donate.${key}`]?.localizations?.en?.stringUnit?.value ?? `missing support.donate.${key}`;
    return args.reduce((text, arg, index) => text.replace(/%(?:\d\$)?@/, (token) => (token === "%@" || token === `%${index + 1}$@` ? arg : token)), value);
  });

  await check("donate: PRD-R59 copy verbatim in vi, catalog copy in en, bank details, share text, VietQR, nothing else", () => {
    assert.ok(specQuotes.length >= 9 && specShare.vi && specShare.en, "PRD-R59 quotes found in spec/03-product.md");
    assert.ok(specShare.vi.endsWith(siteUrl) && specShare.en.endsWith(siteUrl), "the share text links the site");
    for (const [lang, html] of donatePages) {
      const text = pageText(html);
      const expected = lang === "vi" ? specQuotes.filter((quote) => quote !== specShare.en) : catalogEn.concat(specShare.en);
      for (const line of expected) assert.ok(text.includes(line), `${lang}: "${line}"`);
      assert.match(mainOf(html), new RegExp(`<h1>${(lang === "vi" ? `Ủng hộ ${named}` : catalogEn[0]).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}</h1>`), `${lang}: the title is the h1`);
      for (const value of ["LioBank", "688688678", "VietQR (Napas)"]) assert.ok(text.includes(value), `${lang}: ${value}`);
      const images = mainOf(html).match(/<img\b[^>]*>/g) ?? [];
      assert.equal(images.length, 1, `${lang}: one image, the VietQR code`);
      assert.match(images[0], /\ssrc="\/assets\/qr\/vietqr\.png\?v=[0-9a-f]{10}"/, `${lang}: the bundled VietQR image`);
      assert.ok(!/momo|zalopay|vnpay|shopeepay|paypal|patreon|ko-fi|stripe/i.test(html), `${lang}: no other payment method (S8)`);
      assert.ok(!/Tên tài khoản|Chủ tài khoản|Người nhận:|Account name|account holder/i.test(text), `${lang}: the holder's name is never shown (S8)`);
    }
  });

  await check("donate: copy and share buttons are hidden without JavaScript and copy.js loads only there", () => {
    for (const [lang, html] of donatePages) {
      const buttons = mainOf(html).match(/<button\b[^>]*>/g) ?? [];
      const values = (name) => buttons.filter((tag) => new RegExp(`\\s${name}="`).test(tag)).map((tag) => unescapeHtml(attrs(tag, name)[0]));
      assert.deepEqual(values("data-copy"), ["LioBank", "688688678", specShare[lang]], `${lang}: a copy button per value`);
      assert.deepEqual(values("data-share"), [specShare[lang]], `${lang}: one share button with the share text`);
      for (const tag of buttons) {
        assert.match(tag, /\stype="button"/, `${lang}: ${tag} is a plain button`);
        assert.match(tag, /\shidden[\s>]/, `${lang}: ${tag} is hidden until copy.js shows it`);
      }
      assert.match(html, /<script src="\/assets\/copy\.js\?v=[0-9a-f]{10}" defer><\/script>/, `${lang}: copy.js, deferred`);
    }
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      for (const [file, html] of pages) {
        const page = file.slice(dist.length + 1);
        const donate = page === "ung-ho/index.html" || page === "en/donate/index.html";
        assert.equal(html.includes("/assets/copy.js"), donate, `${page}: copy.js only on the donate pages`);
      }
    }
  });

  await check("copy: copy.js shows copy buttons only with the clipboard API and the share button only with navigator.share", async () => {
    const siteCopy = createRequire(import.meta.url)(join(ASSETS_DIR, "copy.js"));
    const flush = () => new Promise((resolve) => setImmediate(resolve));
    const page = ({ clipboard, share }) => {
      const log = { written: [], shared: [], selected: [], timers: [] };
      const scope = fakeElement("section", { "data-copy-scope": "" });
      const status = fakeElement("p", { "data-copy-status": "", "data-copied": "Copied." });
      const value = fakeElement("span", { "data-copy-value": "" });
      value.textContent = "688688678";
      const copyButton = Object.assign(fakeElement("button", { "data-copy": "688688678" }), { hidden: true });
      const shareButton = Object.assign(fakeElement("button", { "data-share": "Check out" }), { hidden: true });
      scope.found.set("[data-copy-status]", status);
      scope.foundAll.set("[data-copy-value]", [value]);
      for (const button of [copyButton, shareButton]) button.ancestors.set("[data-copy-scope]", scope);
      const doc = Object.assign(fakeElement("#document"), { readyState: "complete" });
      doc.foundAll.set("[data-copy]", [copyButton]);
      doc.foundAll.set("[data-share]", [shareButton]);
      const navigator = {};
      if (clipboard) navigator.clipboard = { writeText: async (text) => { log.written.push(text); if (clipboard === "denied") throw new Error("NotAllowedError"); } };
      if (share) navigator.share = async (data) => { log.shared.push(data); if (share !== true) throw Object.assign(new Error(share), { name: share }); };
      // A timer id is its index + 1 in log.timers; clearTimeout empties the slot, so a cleared timer never runs.
      const setTimeout = (fn) => log.timers.push(fn);
      const clearTimeout = (id) => { if (id > 0 && id <= log.timers.length) log.timers[id - 1] = null; };
      const win = { document: doc, navigator, setTimeout, clearTimeout, getSelection: () => ({ selectAllChildren: (el) => log.selected.push(el) }) };
      siteCopy.boot(win);
      return { log, status, value, copyButton, shareButton };
    };
    const none = page({});
    assert.deepEqual([none.copyButton.hidden, none.shareButton.hidden], [true, true], "no clipboard API, no share: both stay hidden");
    const copy = page({ clipboard: "ok" });
    assert.deepEqual([copy.copyButton.hidden, copy.shareButton.hidden], [false, true], "the clipboard API shows the copy button only");
    copy.copyButton.dispatch("click");
    await flush();
    assert.deepEqual(copy.log.written, ["688688678"], "copies the button's text");
    assert.equal(copy.status.textContent, "Copied.", "the status line says so");
    const runTimers = (log) => log.timers.splice(0).forEach((fn) => fn?.());
    runTimers(copy.log);
    assert.equal(copy.status.textContent, "", "and clears after a moment");
    // A second copy restarts the moment: the first click's timer no longer blanks the second confirmation.
    const twice = page({ clipboard: "ok" });
    twice.copyButton.dispatch("click");
    await flush();
    twice.copyButton.dispatch("click");
    await flush();
    assert.deepEqual(twice.log.written, ["688688678", "688688678"]);
    twice.log.timers[0]?.();
    assert.equal(twice.status.textContent, "Copied.", "the earlier timer was cleared");
    runTimers(twice.log);
    assert.equal(twice.status.textContent, "", "the latest timer still clears the line");
    const denied = page({ clipboard: "denied" });
    denied.copyButton.dispatch("click");
    await flush();
    assert.deepEqual(denied.log.selected, [denied.value], "a refused copy selects the value for Command+C");
    assert.equal(denied.status.textContent, "", "and says nothing was copied by keeping the status empty");
    const sharing = page({ clipboard: "ok", share: true });
    assert.equal(sharing.shareButton.hidden, false, "navigator.share shows the share button");
    sharing.shareButton.dispatch("click");
    await flush();
    assert.deepEqual([sharing.log.shared, sharing.log.written], [[{ text: "Check out" }], []], "shares the text");
    const cancelled = page({ clipboard: "ok", share: "AbortError" });
    cancelled.shareButton.dispatch("click");
    await flush();
    assert.deepEqual(cancelled.log.written, [], "closing the share sheet does nothing more");
    const failed = page({ clipboard: "ok", share: "NotAllowedError" });
    failed.shareButton.dispatch("click");
    await flush();
    assert.deepEqual(failed.log.written, ["Check out"], "a share that fails copies the text instead");
  });

  await check("copy: vi pages say file, never tệp", () => {
    // PRD-R64 and spec 03 "Name and trademark sign": the exact quotes of a macOS pane, menu or button that macOS itself
    // writes with tệp are the only exception; no vi page quotes one today. A quoted mention of the word itself (the
    // changelog records the wording change) is not copy. URLs are not copy either (/ho-tro/chuyen-tu/tep-van-ban/).
    const macosQuotes = [];
    const problems = [];
    for (const [dist, pages] of [[fallback, fallbackPages], [populated, pop]]) {
      for (const [file, raw] of pages) {
        const page = file.slice(dist.length + 1);
        if (page.startsWith("en/") || isReleaseNotesPage(page)) continue;
        let html = raw.replace(/\shref="[^"]*"/g, "").replace(/(?:&quot;|")tệp(?:&quot;|")/gi, "");
        for (const quote of macosQuotes) html = html.replaceAll(quote, "");
        for (const [context] of html.matchAll(/.{0,40}tệp.{0,40}/gis)) problems.push(`${page}: ${context.replace(/\s+/g, " ")}`);
      }
    }
    assert.deepEqual(problems, []);
  });

  // The Settings panes as the app names them (PRD-R24; Pa, 15/11/2026: Gõ phím became Kiểu gõ, Gõ tắt became Viết tắt
  // and About & Support was split), read from Settings.xcstrings so the site cannot drift from the app again.
  const settingsCatalog = JSON.parse(await readFile(join(ROOT_DIR, "App", "Resources", "Localization", "Settings.xcstrings"), "utf8"));
  const paneNames = Object.fromEntries(LANGS.map((lang) => [lang, Object.entries(settingsCatalog.strings)
    .filter(([key]) => /^settings\.pane\.[a-z]+$/.test(key))
    .map(([, entry]) => entry.localizations?.[lang]?.stringUnit?.value)
    .filter(Boolean)]));
  // Copy pages: the changelog records the old names on purpose, release notes are written by the release script.
  const copyPages = () => [[fallback, fallbackPages], [populated, pop]].flatMap(([dist, pages]) => [...pages]
    .map(([file, html]) => [file.slice(dist.length + 1), html])
    .filter(([page]) => !isReleaseNotesPage(page) && !["changelog", "nhat-ky-thay-doi"].some((name) => page.split("/").includes(name))));

  await check("content: every Settings pane the site names exists in the app, and vi copy calls macros viết tắt (PRD-R24)", () => {
    assert.ok(paneNames.vi.includes("Kiểu gõ") && paneNames.en.includes("Typing"), "pane names read from Settings.xcstrings");
    // "Cài đặt, mục X", "Cài đặt của <app>, mục X", "Cài đặt > X"; "Settings, X", "Settings, under X", "Settings > X".
    // macOS System Settings ("Cài đặt hệ thống", "System Settings") is not the app's window.
    const reference = { vi: /(?<!hệ thống )Cài đặt(?: của [^\s,]+)?(?:, mục | > )(.{0,40})/g, en: /(?<!System )Settings(?:, under |, (?=\p{Lu})| > )(.{0,40})/gu };
    const problems = [];
    let found = 0;
    for (const [page, html] of copyPages()) {
      const lang = page.startsWith("en/") ? "en" : "vi";
      const text = plainText(html);
      for (const [whole, rest] of text.matchAll(reference[lang])) {
        found += 1;
        // A pane name ends at a word boundary and is not the start of an old combined pane ("About & Support").
        const known = paneNames[lang].some((name) => rest.startsWith(name) && !/^(?:\p{L}|\s*&)/u.test(rest.slice(name.length)));
        if (!known) problems.push(`${page}: "${whole}" names no pane of ${paneNames[lang].join(", ")}`);
      }
      // The D7 non-goal keeps its spec name, "gõ tắt phụ âm nhanh"; macros are "viết tắt" everywhere in the app.
      if (lang === "vi") for (const [context] of text.matchAll(/.{0,30}gõ tắt(?! phụ âm).{0,30}/giu)) problems.push(`${page}: ${context}`);
    }
    assert.ok(found >= 10, `the check sees the pane references (${found})`);
    assert.deepEqual(problems, []);
  });

  await check("content: a migration source that is not a proper name is lowercase in the middle of the page title", () => {
    const titles = [
      [["ho-tro", "chuyen-tu", "tep-van-ban"], "Chuyển từ file văn bản hoặc CSV sang"],
      [["ho-tro", "chuyen-tu", "macos-co-san"], "Chuyển từ bộ gõ Tiếng Việt có sẵn của macOS sang"],
      [["en", "support", "migrate-from", "plain-text-file"], "Moving from a plain text or CSV file to"],
      [["en", "support", "migrate-from", "built-in-macos"], "Moving from the built-in macOS Vietnamese input to"],
    ];
    for (const [path, start] of titles) {
      const html = read(...path, "index.html");
      assert.ok(html, `${path.join("/")} built`);
      assert.ok(mainOf(html).match(/<h1>([^<]*)<\/h1>/)?.[1].startsWith(start), `${path.join("/")}: h1 starts "${start}"`);
      assert.ok(html.match(/<title>([^<]*)<\/title>/)?.[1].startsWith(start), `${path.join("/")}: title starts "${start}"`);
    }
    // The cards on the support page keep the capitalised list form.
    assert.match(read("ho-tro", "index.html"), /<strong>File văn bản hoặc CSV<\/strong>/);
    assert.match(read("en", "support", "index.html"), /<strong>Plain text or CSV file<\/strong>/);
  });

  await check("content: every key example of the tone-marks-anywhere FAQ is one the engine turns into Vietnamese (ENG-R107)", async () => {
    // The engine's words, from the demos of site/demo/frames.json (keys and text aligned word by word), then the ones
    // checked with a private site-demo-frames script (17/11/2026) for examples no demo types.
    const engine = new Map([["vieetj", "việt"], ["tieengs", "tiếng"], ["dangd", "đang"], ["caanf", "cần"]]);
    for (const demo of Object.values(frames.demos)) {
      const keys = (demo.keys ?? "").trim().split(/\s+/);
      const words = demo.text.trim().split(/\s+/);
      if (keys.length === words.length) keys.forEach((key, index) => engine.set(key, words[index]));
    }
    for (const lang of LANGS) {
      const { support } = await import(pathToFileURL(join(SITE_DIR, "content", lang, "support.mjs")).href);
      const [, answer] = support.faq.find(([question]) => /vị trí bất kỳ|anywhere in the word/.test(question)) ?? [];
      assert.ok(answer, `${lang}: the tone-marks-anywhere FAQ`);
      const examples = [...answer.matchAll(/<code>([^<]+)<\/code>/g)].map((m) => m[1]);
      assert.ok(examples.length >= 2, `${lang}: key examples in the answer`);
      for (const keys of examples.filter((example) => example !== "d")) {
        const word = engine.get(keys);
        assert.ok(word, `${lang}: ${keys} is a key sequence the engine output is known for`);
        assert.ok(word !== keys && /[^\x00-\x7f]/.test(word), `${lang}: ${keys} gives ${word}, not the keys as typed`);
      }
    }
  });

  await check("donate: each copy button is named after the value it copies, as the app's VoiceOver labels are", () => {
    const supportStrings = supportCatalog.strings;
    for (const [lang, html] of donatePages) {
      const buttons = (mainOf(html).match(/<button\b[^>]*>[^<]*<\/button>/g) ?? []).filter((tag) => /\sdata-copy="/.test(tag));
      const labels = buttons.map((tag) => unescapeHtml(attrs(tag, "aria-label")[0] ?? ""));
      const expected = ["copyBank", "copyAccount", "copyShareText"].map((key) => supportStrings[`support.control.${key}.accessibilityLabel`].localizations[lang].stringUnit.value);
      assert.deepEqual(labels, expected, `${lang}: Support.xcstrings support.control.*.accessibilityLabel`);
      // WCAG 2.5.3: the accessible name starts with the visible text.
      for (const tag of buttons) assert.ok(unescapeHtml(attrs(tag, "aria-label")[0]).startsWith(tag.match(/>([^<]*)<\/button>$/)[1]), `${lang}: ${tag}`);
    }
  });
}
