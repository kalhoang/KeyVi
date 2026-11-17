// SPDX-License-Identifier: GPL-3.0-or-later
// The site checks of the fallback and populated builds, then the data-driven pages: download, compatibility matrix,
// changelog, donate block, privacy, support and migration pages.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { build } from "../build.mjs";
import { CATEGORIES, STATUSES } from "../lib/data.mjs";
import { SITE_DIR, ROOT_DIR, appHelpTargets, section } from "./helpers.mjs";
import { checkSite } from "./site.mjs";

/** Fallback build (no releases.json) and populated fixtures: shared site checks, then the data the pages render. */
export async function runDataChecks(check, fixtures) {
  const { tmp, shipped, fallback, fallbackPages, populated, read } = fixtures;

  // 1. Fallback data (no releases.json, sample matrix fixture).
  await checkSite(check, "fallback", fallback);

  await check("fallback: shows 'no release yet' and no invented versions", () => {
    const home = fallbackPages.get(join(fallback, "index.html"));
    const homeEn = fallbackPages.get(join(fallback, "en", "index.html"));
    assert.match(home, /Chưa có bản phát hành/);
    assert.match(homeEn, /No release yet/);
    assert.ok(!/<a class="btn"/.test(home), "no download button without a release");
    const download = fallbackPages.get(join(fallback, "tai-ve", "index.html"));
    assert.match(download, /Chưa có bản phát hành/);
    assert.ok(!/\b\d+\.\d+\.\d+\b/.test(download.replace(/macOS \d+(\.\d+)*/g, "")), "no version numbers on the download page");
  });

  // 2. Populated fixtures: releases, matrix statuses, staleness, changelog.
  await checkSite(check, "populated", populated);

  await check("populated: download page lists stable, beta, archive; unsafe URLs dropped", () => {
    const home = read("index.html");
    assert.match(home, /Tải .* 1\.0\.0/);
    const dl = read("tai-ve", "index.html");
    assert.match(dl, /1\.1\.0-beta\.1/);
    assert.match(dl, /id="archive"/);
    assert.match(dl, /0\.9\.0/);
    assert.match(dl, /a{64}/);
    assert.ok(!/javascript:/i.test(dl) && !/0\.5\.0/.test(dl), "entry with unsafe URL is skipped");
    assert.match(dl, /macOS 15 Sequoia trở lên/);
  });

  await check("populated: the open-source proof point names both licences (ADR 0006)", () => {
    assert.match(read("index.html"), /MPL-2\.0\)[^<]*GPL-3\.0-or-later/);
    assert.match(read("en", "index.html"), /Mozilla Public License 2\.0[^<]*GPL-3\.0-or-later/);
  });

  await check("populated: matrix statuses, 120-day staleness (QA-R19), escaping, filters hook", () => {
    const m = read("tuong-thich", "index.html");
    for (const label of ["Hoạt động tốt", "Hoạt động, có lưu ý", "Chưa kiểm tra", "Hạn chế đã biết"]) assert.ok(m.includes(label), label);
    assert.match(m, /iTerm2[\s\S]*?status-notVerified[\s\S]*?quá 120 ngày/);
    assert.ok(!m.includes("<script>alert"), "matrix notes are escaped");
    assert.match(m, /data-matrix-filters/);
    assert.match(m, /<script src="\/assets\/matrix\.js\?v=[0-9a-f]{10}" defer><\/script>/);
    assert.ok(!/Mystery app[\s\S]{0,200}status-works/.test(m), "unknown status falls back to notVerified");
    assert.match(read("en", "compatibility", "index.html"), /Works with notes/);
  });

  await check("populated: matrix uses the field names of compat/schema/matrix.schema.json", async () => {
    const schema = JSON.parse(await readFile(join(ROOT_DIR, "compat", "schema", "matrix.schema.json"), "utf8"));
    const entry = schema.$defs.entry.properties;
    assert.deepEqual(STATUSES, entry.status.enum, "status values");
    assert.deepEqual(CATEGORIES, entry.category.enum, "category values");
    for (const field of ["displayName", "bundleId", "ruleId", "note", "tier", "lastVerified", "appVersion", "macOS", "issues"]) {
      assert.ok(entry[field], `schema field ${field}`);
    }
    const m = read("tuong-thich", "index.html");
    assert.match(m, /<tr data-status="worksWithNotes" data-rule-id="browser\.chromium\.addressBar">\s*<th scope="row">Chrome/);
    assert.match(m, /Chrome[\s\S]*?<td>26\.1<\/td>/, "macOS column reads macOS");
    assert.match(m, /status-knownLimitation[\s\S]*?<a href="https:\/\/github\.com\/[^"]+\/issues\/3" rel="noopener">#3<\/a>, <a href="[^"]+\/issues\/7"/);
    assert.match(m, /data-category-group="other"[\s\S]*?Mystery app/, "unknown category falls back to other");
    for (const lang of ["vi", "en"]) {
      const ui = (await import(pathToFileURL(join(SITE_DIR, "content", lang, "ui.mjs")).href)).default;
      assert.deepEqual(Object.keys(ui.status), STATUSES, `${lang} status labels`);
      assert.deepEqual(Object.keys(ui.categories).sort(), [...CATEGORIES].sort(), `${lang} category labels`);
    }
  });

  await check("populated: changelog rendered from CHANGELOG.md, release headings have id v<version>", () => {
    const c = read("nhat-ky-thay-doi", "index.html");
    // ADR 0504: release-notes pages link /nhat-ky-thay-doi/#v<version> and /en/changelog/#v<version>.
    assert.match(c, /<h2 id="v1\.0\.0">\[1\.0\.0\] - 2026-12-01<\/h2>/);
    assert.match(c, /<h2 id="v0\.9\.0">/);
    assert.match(read("en", "changelog", "index.html"), /<h2 id="v1\.0\.0">/);
    assert.match(c, /<strong>iTerm2<\/strong>/);
    assert.match(c, /href="\/ung-ho\/"/);
  });

  await check("populated: donate block per PRD-R59 and S8 (bank VietQR only, bank and account number, no holder name)", async () => {
    // The wording of the block is checked against spec/03-product.md and the app's catalog further down ("donate: ...").
    for (const [lang, path, bankLabel, accountLabel] of [["vi", ["ung-ho", "index.html"], "Ngân hàng", "Số tài khoản"], ["en", ["en", "donate", "index.html"], "Bank", "Account number"]]) {
      const d = read(...path);
      assert.match(d, /<img src="\/assets\/qr\/vietqr\.png(?:\?v=[0-9a-f]+)?" width="\d+" height="\d+" alt="[^"]+">/, `${lang}: bundled VietQR image`);
      assert.ok(d.includes(`<dt>${bankLabel}</dt><dd><span data-copy-value>LioBank</span>`), `${lang}: bank name`);
      assert.ok(d.includes(`<dt>${accountLabel}</dt><dd><span data-copy-value>688688678</span>`), `${lang}: account number`);
      assert.ok(!/momo/i.test(d), `${lang}: no MoMo (S8)`);
      assert.ok(!/Tên tài khoản|Chủ tài khoản|Account name|account holder/i.test(d), `${lang}: the holder's name is never shown (S8)`);
      assert.ok(!d.includes('class="verify"'), `${lang}: real details, nothing left to verify`);
      assert.ok(!d.includes("donate-sponsors"), `${lang}: no sponsor card while there is no sponsor page`);
    }
    assert.ok(existsSync(join(populated, "assets", "qr", "vietqr.png")), "QR image shipped");
    assert.ok(!existsSync(join(populated, "assets", "qr", "momo.svg")), "MoMo image removed");
    // An empty sponsorsUrl means no sponsor page: no card, no placeholder, nothing for --strict to refuse (PRD-R59).
    assert.equal(shipped.sponsorsUrl, "", "no GitHub Sponsors page exists yet");
    const emptyConfig = join(tmp, "sponsors-empty.json");
    await writeFile(emptyConfig, JSON.stringify({ ...shipped, sponsorsUrl: "" }));
    const emptyOut = join(tmp, "sponsors-empty");
    const summary = await build({ outDir: emptyOut, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath: emptyConfig });
    assert.ok(!summary.placeholders.includes("sponsorsUrl"), "an empty sponsorsUrl is not a placeholder");
    for (const page of ["ung-ho/index.html", "en/donate/index.html"]) {
      const html = await readFile(join(emptyOut, page), "utf8");
      assert.ok(!html.includes("donate-sponsors") && !/github\.com\/sponsors/.test(html), `${page}: no sponsor card`);
    }
    // A real sponsor page in site/config.json brings the GitHub Sponsors card back (PRD-R57).
    const configPath = join(tmp, "sponsors-config.json");
    const base = JSON.parse(await readFile(join(SITE_DIR, "config.json"), "utf8"));
    await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: "https://github.com/sponsors/example" }));
    const out = join(tmp, "sponsors");
    await build({ outDir: out, today: "2026-11-13", dataDir: join(SITE_DIR, "fixtures", "populated"), configPath });
    const sponsored = await readFile(join(out, "ung-ho", "index.html"), "utf8");
    assert.match(sponsored, /id="donate-sponsors"[\s\S]*href="https:\/\/github\.com\/sponsors\/example"/);
    for (const bad of ["javascript:alert(1)", "http://github.com/sponsors/x", 42]) {
      await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: bad }));
      await assert.rejects(() => build({ outDir: join(tmp, "sponsors-bad"), today: "2026-11-13", configPath }), /sponsorsUrl/, String(bad));
    }
    await writeFile(configPath, JSON.stringify({ ...base, sponsorsUrl: "https://github.com/sponsors/OWNER" }));
    assert.ok((await build({ outDir: join(tmp, "sponsors-placeholder"), today: "2026-11-13", configPath })).placeholders.includes("sponsorsUrl"), "a placeholder is still reported for --strict");
  });

  await check("populated: favicon, touch icon and the header mark come from the app icon (CLR-R7)", async () => {
    for (const file of ["favicon.svg", "favicon.ico", "apple-touch-icon.png"]) {
      assert.ok(existsSync(join(populated, file)), `${file} shipped`);
    }
    // The raster logo files went with the 2026-11-17 redesign: no page used them, so they are no longer made or shipped.
    assert.ok(!existsSync(join(populated, "assets", "brand")), "no unused raster logo files");
    const favicon = await readFile(join(populated, "favicon.svg"), "utf8");
    assert.match(favicon, /Source: derived from Pa's own artwork/);
    assert.match(read("index.html"), /<link rel="icon" href="\/favicon\.svg" type="image\/svg\+xml">/);
    // The header mark is the KV of favicon.svg as an inline symbol (design 7.1); the shell check compares the shapes.
    assert.match(read("index.html"), /<a class="brand" href="\/"><svg class="mark"[^>]*><use href="#mark"><\/use><\/svg>/, "header mark");
    for (const sheet of ["style.css", "home.css"]) {
      const css = await readFile(join(populated, "assets", sheet), "utf8");
      for (const [, src] of css.matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(populated, src)), `${sheet}: ${src} exists`);
    }
  });

  await check("populated: privacy page covers storage, network, diagnostics, analytics none", () => {
    const p = read("rieng-tu", "index.html");
    for (const id of ["luu-tren-may", "gui-di", "chan-doan", "ban-ghi", "trang-web", "xoa-du-lieu"]) assert.ok(p.includes(`id="${id}"`), id);
    assert.match(p, /Phân tích truy cập: không có/);
    assert.match(read("en", "privacy", "index.html"), /Visitor analytics: none/);
    // Without analytics every script comes from the site itself, and the page says so without exception.
    assert.match(p, /mã, hình ảnh, bản cập nhật và file cài đặt \(DMG\) đều phục vụ từ chính máy chủ của trang này/);
    assert.ok(!p.includes("Umami"), "vi privacy: no Umami without analytics");
    assert.match(read("en", "privacy", "index.html"), /Fonts are the ones already on your device; code, images, updates and the installer \(DMG\) are all served from this site's own server/);
  });

  await check("populated: the iTerm2 Secure Input line is the app's one sentence of Q38 (no VERIFY left)", async () => {
    const line = (html) => html.match(/<li><strong>iTerm2<\/strong>: ([\s\S]*?)<\/li>/)[1];
    assert.equal(line(read("en", "support", "index.html")), "iTerm2 has Secure Keyboard Entry turned on. Turn off <em>iTerm2 &gt; Secure Keyboard Entry</em>, or finish or cancel the password prompt it is waiting for.");
    assert.equal(line(read("ho-tro", "index.html")), "iTerm2 đang bật Nhập bàn phím an toàn. Hãy tắt mục <em>iTerm2 &gt; Secure Keyboard Entry</em>, hoặc nhập xong (hay hủy) lời nhắc mật khẩu đang chờ.");
    // ADR 0400 item 15: the support page and the app's status line (Status.xcstrings) use the same sentence.
    const catalog = JSON.parse(await readFile(join(ROOT_DIR, "App", "Resources", "Localization", "Status.xcstrings"), "utf8"));
    const hint = catalog.strings["secureInputHint.iterm2.secureKeyboardEntry"].localizations;
    const plain = (html) => line(html).replace(/<\/?em>/g, "").replaceAll("&gt;", ">");
    assert.equal(plain(read("en", "support", "index.html")), hint.en.stringUnit.value);
    assert.equal(plain(read("ho-tro", "index.html")), hint.vi.stringUnit.value);
  });

  await check("populated: the FAQ names every app family where Escape restore is off (compat/rules.json, D8)", async () => {
    const rules = JSON.parse(await readFile(join(ROOT_DIR, "compat", "rules.json"), "utf8"));
    const off = rules.rules.filter((rule) => rule.action?.features?.restoreHotkey === false).map((rule) => rule.id).sort();
    // Every rule that turns Escape restore off, with the names the FAQ gives it: app families, never bundle IDs.
    const both = (...names) => ({ en: names, vi: names });
    const families = {
      "terminal.default": { en: ["terminals", "Terminal", "iTerm2"], vi: ["Terminal", "iTerm2"] },
      "editor.vscode.integratedTerminal": { en: ["the terminal inside code editors"], vi: ["cửa sổ dòng lệnh trong trình soạn mã"] },
      "editor.vscodeFamily": both("Visual Studio Code", "VSCodium", "Cursor"),
      "editor.jetbrains": both("JetBrains", "Android Studio"),
      "editor.nativeCodeEditors": both("Xcode", "Nova", "BBEdit"),
      "editor.customTextViews": both("Sublime Text", "Zed", "Emacs", "MacVim"),
      "remote.passThrough": { en: ["remote desktop and virtual machine apps"], vi: ["ứng dụng điều khiển máy từ xa và máy ảo"] },
      "remote.chromeRemoteDesktop.web": both("Chrome Remote Desktop"),
      "games.passThrough": { en: ["games"], vi: ["trò chơi"] },
      "launcher.spotlight": both("Spotlight"),
      "launcher.overlayPanels": both("Raycast", "Alfred"),
    };
    assert.deepEqual(off, Object.keys(families).sort(), "a rule turns Escape restore off or on again: update the FAQ entry and this map");
    const entry = (html) => {
      const found = html.split("<details>").find((chunk) => /<summary>[^]*?Escape[^]*?<\/summary>/.test(chunk));
      assert.ok(found, "no FAQ entry about Escape");
      return found.split("</details>")[0];
    };
    for (const [lang, html] of [["en", read("en", "support", "index.html")], ["vi", read("ho-tro", "index.html")]]) {
      const text = entry(html);
      for (const [id, names] of Object.entries(families)) for (const name of names[lang]) assert.ok(text.includes(name), `${lang}: ${id} needs "${name}"`);
      assert.doesNotMatch(text, /\b(?:com|org|dev|net|tv|io)\.[A-Za-z0-9-]+\.[A-Za-z]/, `${lang}: no bundle IDs`);
    }
  });

  await check("populated: support page has permission (macOS 27 naming), Secure Input, targets", () => {
    const s = read("ho-tro", "index.html");
    assert.match(s, /Điều khiển thiết bị và truy cập dữ liệu/);
    assert.match(s, /iTerm2/);
    assert.match(s, /24 giờ/);
    assert.match(read("en", "support", "index.html"), /Device Control and Data Access/);
  });

  await check("populated: every help anchor the app opens exists (PRD-R16 hotkey guide, SupportLinks topics)", async () => {
    const targets = await appHelpTargets();
    assert.ok(targets.some((t) => t.source.includes("settings.hotkey.conflict.helpPath")), "PRD-R16 help path found");
    assert.ok(targets.filter((t) => t.source.startsWith("SupportLinks")).length >= 8, "SupportLinks topics found");
    const problems = [];
    for (const target of targets) {
      const file = join(populated, target.path, "index.html");
      if (!existsSync(file)) problems.push(`${target.source}: no page ${target.path}`);
      else if (!(await readFile(file, "utf8")).includes(`id="${target.fragment}"`)) problems.push(`${target.source}: no #${target.fragment} on ${target.path}`);
    }
    assert.deepEqual(problems, []);
  });

  await check("populated: the macOS shortcut guide covers every combination the recorder warns about (PRD-R16)", () => {
    const section = (html, id) => html.split(`id="${id}"`)[1]?.split("</section>")[0] ?? "";
    const vi = section(read("ho-tro", "index.html"), "phim-tat-macos");
    const en = section(read("en", "support", "index.html"), "macos-shortcuts");
    for (const [label, html, keyboard, spotlight] of [["vi", vi, "Bàn phím", "Spotlight"], ["en", en, "Keyboard", "Spotlight"]]) {
      assert.ok(html.includes(keyboard) && html.includes(spotlight), `${label}: System Settings path`);
      for (const keys of [["Command", "Space"], ["Control", "Space"], ["Control", "Option", "Space"], ["Control", "Command", "Space"], ["Command", "Tab"], ["Command", "Q"], ["Command", "W"]]) {
        const combo = keys.map((key) => `<kbd>${key}</kbd>`).join(" + ");
        assert.ok(html.includes(combo), `${label}: ${keys.join("+")}`);
      }
    }
  });

  await check("populated: the FAQ explains the pause for non-Latin input sources (D22, PRD-R7)", () => {
    const summaries = (html) => [...html.matchAll(/<summary>([\s\S]*?)<\/summary>/g)].map((m) => m[1]).join("\n");
    assert.match(summaries(read("ho-tro", "index.html")), /tiếng Nhật, Trung hay Hàn/);
    assert.match(summaries(read("en", "support", "index.html")), /Japanese, Chinese or Korean/);
  });

  await check("populated: migration pages promise only the importers that ship (PRD-R69, contracts.md 7.3)", () => {
    // The app imports macros from TSV or CSV, the Text Replacements plist and its own export; importers for other
    // input methods' files come only after their formats are observed in real exports (CLR-R5).
    const external = ["xkey", "openkey", "evkey", "go-nhanh", "phtv"];
    const overpromise = { vi: /nhập được|có thể nhập|nhập gõ tắt và|nhập phần gõ tắt/i, en: /can import|imports (?:the )?macros|imports? (?:its|their) settings/i };
    const template = { vi: 'href="/ho-tro/chuyen-tu/tep-van-ban/"', en: 'href="/en/support/migrate-from/plain-text-file/"' };
    for (const id of external) {
      for (const [lang, html] of [["vi", read("ho-tro", "chuyen-tu", id, "index.html")], ["en", read("en", "support", "migrate-from", id, "index.html")]]) {
        const lede = html.match(/<p class="lede">([\s\S]*?)<\/p>/)[1];
        assert.ok(lede.includes(template[lang]), `${lang} ${id}: the intro points at the plain text template`);
        const text = html.split('<main id="main"')[1].replace(/<[^>]+>/g, " ");
        assert.ok(!overpromise[lang].test(text), `${lang} ${id}: promises an importer that does not exist`);
      }
    }
    const cards = (html) => html.match(/<ul class="cards">[\s\S]*?<\/ul>/)[0];
    assert.ok(!/kiểu gõ|loại trừ|theo ứng dụng/.test(cards(read("ho-tro", "index.html"))), "vi index cards");
    assert.ok(!/typing method|excluded apps|per-app/.test(cards(read("en", "support", "index.html"))), "en index cards");
  });

  await check("populated: the settings export example has the keys the app writes and reads (PRD-R72)", async () => {
    const swift = await readFile(join(ROOT_DIR, "Packages", "AppCore", "Sources", "SettingsStore", "ExportImport.swift"), "utf8");
    const header = [...swift.match(/headerKeys: Set<String> = \[([^\]]+)\]/)[1].matchAll(/"(\w+)"/g)].map((m) => m[1]);
    const sections = [...swift.match(/static let settings = "settings",[^\n]*/)[0].matchAll(/"(\w+)"/g)].map((m) => m[1]);
    const kind = swift.match(/static let kind = "([^"]+)"/)[1];
    const documents = await readFile(join(ROOT_DIR, "Packages", "AppCore", "Sources", "SettingsStore", "Documents.swift"), "utf8");
    const macroBlock = documents.split("public struct StoredMacro")[1].split("public init")[0];
    const macroKeys = [...macroBlock.matchAll(/public var (\w+):/g)].map((m) => m[1]);
    for (const page of [read("ho-tro", "chuyen-tu", "tep-van-ban", "index.html"), read("en", "support", "migrate-from", "plain-text-file", "index.html")]) {
      const code = [...page.matchAll(/<pre><code>([\s\S]*?)<\/code><\/pre>/g)].map((m) => m[1]).find((c) => c.includes('"schemaVersion"'));
      const example = JSON.parse(code);
      assert.deepEqual(Object.keys(example).sort(), [...header, ...sections].sort());
      assert.equal(example.kind, kind);
      assert.deepEqual(Object.keys(example.macros[0]).sort(), [...macroKeys].sort());
      assert.equal(typeof example.appModes, "object");
      assert.ok(!Array.isArray(example.appModes), "appModes is an object");
    }
  });
}
