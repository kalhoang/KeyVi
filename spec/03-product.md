# 03. Product specification

Prefix: PRD-R

This file defines what {{AppName}} is for, who it serves, how it looks and behaves from the user's point of view, and which defaults it ships with. Typing rules live in `01-engine.md` (ENG-R), macOS integration (event tap, injection, permissions, per-app compatibility rules) in `02-platform.md` (PLT-R), quality and release in `04-quality-release.md` (QA-R), provenance in `05-clean-room.md` (CLR-R). Where this file states a behaviour that another file implements, the other file owns the mechanism and this file owns the user-visible outcome. Status: draft, 2026-11-13, adversarial review applied (defaults aligned with `01-engine.md`, minimum macOS aligned with `02-platform.md`).

Placeholders: `{{AppName}}` (display name), `{{app-slug}}` (ASCII slug: bundle ID `vn.kal.{{app-slug}}`, Homebrew cask `{{app-slug}}`, site `{{app-slug}}.kal.vn`). Do not invent a name.

---

## 1. Product principles

These are tie-breakers. When two requirements conflict, the earlier principle wins.

1. **Typing never breaks.** No key sequence may crash the app, freeze the machine, eat characters or leave stray characters. When unsure, pass the key through unchanged (fail open). A missed tone mark is a small annoyance; a lost word or a frozen Mac is a reason to uninstall.
2. **Right by default.** A new user who never opens Settings must get the best behaviour for typical Vietnamese writing mixed with English. A support answer of the form "turn on setting X" is a bug in the defaults, not a fix.
3. **Invisible when it works, honest when it does not.** No popups, nags or animations during normal typing. When something is wrong (missing permission, Secure Input held by another app, an app that cannot be supported), say exactly what, which app, and what the user can do.
4. **Private by construction.** Typed content never leaves the Mac and is never written to disk, with one exception the user starts by hand: a typing trace for a bug report (section 11.2), limited to 60 to 180 seconds, shown with a visible countdown, reviewed by the user before sharing, deleted after 24 hours and never sent automatically. The only automatic network traffic is the update check. No telemetry, no analytics SDK, no "anonymous usage data".
5. **Few settings.** Every setting is a maintenance cost and a support question. A setting exists only if real users need both values. Per-app special cases are data, not settings.
6. **Restore exactly what was typed.** Undo and English restore reproduce the user's own keystrokes (digits stay digits in VNI, doubled letters stay doubled), never a re-encoded guess.

---

## 2. Personas and top jobs

| Persona | Typical apps | Top jobs | What breaks today (from public bug reports) |
|---|---|---|---|
| **Office worker (Linh)** | Excel, Google Sheets, Word, Outlook, Chrome/Edge/Safari, Zalo, Messenger, Teams | Type long Vietnamese text fast in documents, spreadsheet cells, chat and web forms; search in the browser address bar | Duplicated or swallowed letters in Sheets/Excel cells and sheet names, address-bar autocomplete duplicating letters, first letter lost in Safari on Sheets |
| **Developer (Minh)** | Terminal, iTerm2, Ghostty, tmux, VS Code, Cursor, JetBrains IDEs, Claude Code / CLI agents, Slack, browser | Write code and commands in English all day, switch to Vietnamese for chat and commit messages, never get `đ` from `dd` or `tét` from `test` | English words getting marks (text, user, case, wifi, USB), lost characters in terminals and CLI agents, ESC being hijacked, IDE lag |
| **Designer (Trang)** | Figma (app and web), Adobe Illustrator/Photoshop/InDesign, Affinity, Canva, DaVinci Resolve | Type Vietnamese in text layers; use single-key tool shortcuts (V, T, Backspace to delete a shape) without interference | Backspace or Delete on a selected shape interpreted as text editing, lag in Illustrator, tool shortcuts swallowed |
| **Gamer (Khoa)** | Steam games, League of Legends, Valorant chat, Discord | WASD and hotkeys must never be touched or delayed; Vietnamese only in chat | Game input lag when the IME queries apps per keystroke |
| **Bilingual writer (Hà)** | Notion, Obsidian, Google Docs, Pages, Telegram, Messenger, X/Facebook in the browser | Mix Vietnamese and English inside one sentence without switching; edit a word after moving back with Backspace; type proper nouns and place names (Buôn Ma Thuột, Krông Pắc) | Restore damaging valid words and names, losing the edit context after `, ` or `. `, jitter in Notion |

PRD-R1 Every release MUST be checked against the top jobs above for the apps listed in the "Tier 1" column of the compatibility matrix (section 9, QA-R in `04-quality-release.md`).

---

## 3. Scope

### 3.0 P0: the product owner's daily annoyances (must be fixed before anything else ships)

Pa uses the predecessor (XKey) every day. These three problems are the reason this product exists; each one is a release blocker for v0.1 and has an automated test.

| ID | What happens today | What {{AppName}} does | Requirements |
|---|---|---|---|
| P0-1 | Vietnamese typing is blocked "at random" in some apps, most often iTerm2, as if a password were being typed. Cause: iTerm2 turns on secure keyboard entry by itself when it thinks a password prompt is showing; while any app holds secure input, macOS stops delivering keys to every keyboard tool (Apple TN2150), so no event-tap input method can work. | Never pause on guesses, only on the OS secure-input state or a real password field; say in the menu which app holds secure input and how to turn it off (iTerm2 included); resume on the very first key after it is released; spike whether an IMKit input source keeps working in terminals under secure input. | PLT-R395 to PLT-R398D |
| P0-2 | Slang cannot be typed: the `dz` onset (`dzô`, `dzậy`) is impossible because only one-letter extra onsets were allowed; `hẹo` works "sometimes". Cause of the second: a dictionary without `hẹo` restored it to `heoj`, but only when Space ended the word. | Validity comes from the rules of Vietnamese spelling, not a dictionary, so any valid syllable (`hẹo`) is kept; `dz` and `z` are accepted slang onsets; the result never depends on which key ends the word. | 01-engine.md 3.3, ENG-R316, REG-28, REG-29 |
| P0-3 | Automatic return to English works only with Space; `, . ; : ! ?` leave `tẽt`, so the user types Space then Backspace. | Every boundary key (all punctuation, Return, Tab, whitespace) runs the same commit as Space; the punctuation reaches the app after the correction; Return is delivered only after the correction, so a chat app never sends the wrong word. | ENG-R910, ENG-R803, 13.9.1 (B053-B064), REG-30 |

- **PRD-R0** A build that fails any P0 test MUST NOT be released, including private alphas.

### 3.1 v1.0 scope (MUST)

PRD-R2 v1.0 MUST include:
- Telex and VNI typing methods with the full Vietnamese syllable inventory (`01-engine.md`).
- Automatic English restore, on by default, with no download.
- Traditional and modern tone placement styles.
- One global VI/EN toggle hotkey plus per-app VI/EN memory.
- Per-app rules (always English, always Vietnamese, remember, ignore app).
- Macros (text expansion) with import and export.
- Menu bar status indicator and menu.
- Onboarding with permission guidance and a practice field.
- Settings window (small, section 7).
- Apps page with compatibility status and per-app rules (section 9).
- Diagnostics and one-click bug report without typed content (section 11).
- Sparkle 2 updates with stable and beta channels (section 12).
- Vietnamese and English UI (section 14).
- Settings export, import and reset to defaults.
- Layout-independent key mapping (QWERTY, QWERTZ, AZERTY, Dvorak, Colemak).
- Universal binary (Apple silicon and Intel).

### 3.2 Non-goals for v1.0

PRD-R3 The following MUST NOT ship in v1.0. Each line has the reason so nobody re-adds it casually.
- Legacy encodings (TCVN3, VNI-Windows, CP1258) for typing output: rarely used, were broken in XKey, and every encoding multiplies test cases. Unicode precomposed (NFC) only.
- Text conversion tool between encodings: roadmap candidate, separate window, not part of the typing path.
- Translation, AI rewriting, word suggestions, autocomplete: requires network or large models and conflicts with principle 4.
- Clipboard history, emoji pickers, themes: out of product focus.
- Window-title regex rules: XKey's global title rules misfired across apps. Per-app rules plus compatibility profiles cover the need.
- iCloud sync: export/import covers it for v1; sync is on the roadmap (1.x) as opt-in.
- Mac App Store or sandboxed edition: an event-tap input method needs Accessibility, which the sandbox does not allow. VERIFY whether an IMKit-only sandboxed edition is worth a separate product later (PHTV is attempting one).
- Windows, Linux, iOS, Android.
- Custom user-defined typing methods.
- Quick Telex consonant shortcuts (`cc` to `ch`, `kk` to `kh`, `nn` to `ng`, `tt` to `th`, `gg` to `gi`, `f`/`j`/`w` as `ph`/`gi`/`qu` at word start): on by default in XKey they mangled ordinary typing (`cc` became `ch`, `kkk` became `khk`); not offered even as an option (ENG-R121).
- A switch for "type tone marks anywhere in the word": tone, modifier and `đ` keys always work after later letters (`vietj`, `caanf`, `dangd`), so there is nothing to switch (ENG-R107). XKey's most common support answer was "turn this on", which means it should never have been off.
- Auto-capitalisation of sentences: intrusive and frequently reported as broken; macOS and most apps already offer it.

### 3.3 Roadmap

| Stage | Audience | Entry criteria | Exit criteria |
|---|---|---|---|
| **Private alpha** (0.1.x) | Pa plus up to 10 invited testers, direct DMG | Engine corpus green, fuzz clean, onboarding usable | 2 weeks of daily use by Pa with zero lost-text incidents; all Tier 1 apps pass the compatibility script; no crash reports |
| **Closed beta** (0.5.x) | 50 to 150 testers from a signup form, beta appcast | Bug report flow works end to end; Apps page shows real profiles | Reopen rate under 15%; no P0 open; median time to fix P1 under 7 days; migration import tested from XKey and OpenKey exports |
| **Public beta** (0.9.x) | Anyone, website + Homebrew tap, beta channel default for this stage | Notarized, signed updates proven across 3 consecutive releases without settings loss | 4 weeks without a P0; compatibility matrix covers Tier 1 and Tier 2 with verified dates; provenance review done (CLR-R13) |
| **1.0** | Everyone, stable channel | All PRD-R and QA-R MUST items met | n/a |
| **1.x candidates** | | | Opt-in iCloud sync of settings and macros; per-website memory in browsers (VERIFY feasibility without per-keystroke Accessibility calls); encoding converter; Telex+VNI combined method; optional IMKit marked-text mode for apps that cannot accept injected backspaces |

PRD-R4 Each stage transition MUST be recorded as a decision in `docs/decisions/` with the exit criteria evidence.

---

## 4. Defaults

PRD-R5 The app MUST ship with exactly the defaults below. Changing a default after 1.0 requires a decision record and a release-note entry; existing users keep their explicit choices.

PRD-R6 A setting the user never touched MUST follow future default changes; a setting the user changed MUST be preserved across updates forever (store "unset" distinctly from "set to the default value").

| # | Setting (UI label vi / en) | Default | Why |
|---|---|---|---|
| D1 | Kiểu gõ / Typing method | **Telex** | Most common method among Vietnamese Mac users; VNI one click away in onboarding and menu |
| D2 | Kiểu đặt dấu / Tone placement | **Traditional (hòa, thủy, khỏe)** | Matches what most Vietnamese readers see in press, law and the long-standing default of popular Windows IMEs, so text "looks normal" to recipients. Modern (hoà, thuỷ, khoẻ) is one toggle away. Evidence recorded in ENG-R510: Decision 1989/QĐ-BGDĐT (25 May 2018), Article 8, prescribes the modern placement for curricula and textbooks only, so readers taught after 2018 may prefer modern. Confirmed by the product owner on 13/11/2026; the setting stays |
| D3 | Đặt dấu tự do / Type tone marks anywhere in the word | **Always on, not a setting** | Users type the tone key after the final consonant (`vietj`, `tieengs`), in the middle, or the `đ` key at the end (`dangd`); the engine's viability rule makes this safe for every valid syllable (ENG-R107). XKey's most common support answer was "turn this on", which is why it is not a switch here |
| D4 | Tự khôi phục từ tiếng Anh / Automatic English restore | **On** | #1 request; words like text, user, case, wifi, USB, with, this must come out unchanged. Bundled data, no download (data licence per CLR-R6) |
| D5 | Telex: `w` đứng riêng thành `ư` / Telex: lone `w` becomes `ư` | **On** | Standard Telex; English restore reverts `w` in English words. Off for users who never want it |
| D6 | Telex: phím `[` `]` thành `ơ` `ư` / Bracket keys produce ơ, ư | **Off** | Mangles code and Markdown (`[`, `]` typed twice produced `?`-like output in XKey reports) |
| D7 | Gõ tắt phụ âm nhanh / Quick consonant shortcuts | **Not offered** (non-goal, section 3.2) | Mangles normal typing (cc becomes ch, kkk becomes khk); the engine does not implement it (ENG-R121) |
| D8 | Phím khôi phục từ vừa gõ / Restore-last-word hotkey | **Escape**, with an on/off setting (decision of the product owner, 13/11/2026) | One key that users of other input methods know, free inside a word in ordinary text fields. The key is consumed only if the current word contains a transformation; a second consecutive press always passes through (ENG-R701, ENG-R702), so Escape still closes Spotlight and dialogs. Compatibility rules turn it off automatically in terminals, IDEs and code editors, games and remote desktop clients, where Escape has its own meaning (PLT-R353) |
| D9 | Gõ tắt (macro) / Macros | **On, empty list** | Costs nothing until the user adds an entry |
| D10 | Gõ tắt khi ở chế độ tiếng Anh / Expand macros in English mode | **Off** | Prevents surprise expansions while coding |
| D11 | Phím chuyển Việt/Anh / VI/EN toggle hotkey | **Tap Control+Shift** (press and release both modifiers, no other key or click in between, within 500 ms) | Same muscle memory as Unikey/EVKey on Windows; no clash with macOS input-source shortcuts (Control+Space, Control+Option+Space), Spotlight (Command+Space), Character Viewer (Control+Command+Space) or the Globe key. Holding the chord for other shortcuts does not toggle |
| D12 | Nhớ Việt/Anh theo ứng dụng / Remember VI/EN per app | **On** | Developers live in English in terminals and Vietnamese in chat; one switch per app teaches the app forever |
| D13 | Chế độ cho ứng dụng mới / Mode for an app seen for the first time | **Inherit current mode** | Least surprise |
| D14 | Hiện thông báo nhỏ khi chuyển / Show switch indicator | **On**, only on manual toggle | Silent mode errors are a top annoyance; no indicator on automatic per-app switches |
| D15 | Âm thanh khi chuyển / Sound on switch | **Off** | Noise in shared spaces |
| D16 | Bấm biểu tượng để chuyển Việt/Anh / Click menu bar icon to toggle | **Off** | macOS convention is click to open menu; offered because users asked |
| D17 | Mở khi đăng nhập / Open at login | **On** (shown pre-checked in onboarding) | An IME that does not start is a broken IME |
| D18 | Ngôn ngữ giao diện / Interface language | **Vietnamese** | Target users are Vietnamese, many run macOS in English; English selectable |
| D19 | Tự động kiểm tra cập nhật / Check for updates automatically | **On**, daily | Fixes for app compatibility must reach users |
| D20 | Tự động cài cập nhật / Install updates automatically | **On**, installs on next quit or restart, never mid-typing | Users should not run stale builds; install timing never interrupts |
| D21 | Kênh cập nhật / Update channel | **Stable** | Beta is opt-in |
| D22 | Tạm dừng khi dùng bộ gõ khác (Nhật, Trung, Hàn...) / Pause while a non-Latin input source is active | **Always on, not a setting** | Typing `kore` in a Japanese IME must not become `kỏe` |
| D23 | Ô mật khẩu / Secure Input | **Always pass through, not a setting** | Security |
| D24 | Bố cục bàn phím / Keyboard layout | **Follow the active macOS layout, not a setting** | Layout independence is automatic |
| D25 | Bảng mã / Output encoding | **Unicode NFC, not a setting** | Legacy encodings are a non-goal |
| D26 | Ghi lại thao tác gõ để báo lỗi / Typing trace for a bug report | **Not a setting: on-demand action** (60 s, at most 180 s, visible countdown, deleted after 24 h) | The only case where typed content touches the disk, under the user's eyes (section 11.2, PLT-R905). Everything else in diagnostics is content-free at all times |
| D27 | Đồng bộ iCloud / iCloud sync | n/a in v1 | Roadmap, opt-in |

PRD-R7 Settings that are "not a setting" above MUST NOT appear in the UI. They are documented on the website FAQ.

PRD-R8 Minimum macOS: **macOS 15 Sequoia** (aligned with PLT-R106 on review). Rationale: Apple's update window at the time of writing covers macOS 15, 26 and 27; GitHub retired its hosted macOS 14 runners on 2 November 2026, so macOS 14 could only be tested on self-owned hardware; the Swift `Synchronization` module (`Mutex`, `Atomic`) needs macOS 15 and gives the hot path lock-free primitives without third-party code. Cost: Macs that stop at Sonoma (MacBook Air 2018 and 2019, some 2017 models) are excluded; the website states this plainly. macOS 27 runs on Apple silicon only (Intel stays on macOS 26), so the universal binary MUST be kept until Intel usage reported in bug reports drops below 5%. Open decision 7 for Pa: accept 15, or pay for 14 with own test hardware and without the `Synchronization` module. Until Pa decides, no API newer than macOS 14 is used outside that module (PLT-R106).

---

## 5. Menu bar UI and status indicator

PRD-R9 The app MUST show a monochrome template icon in the menu bar at all times while running. The user cannot hide it (status is safety-relevant), but MAY quit the app.

PRD-R10 Icon states (all monochrome, distinguishable without colour, each with a VoiceOver label):

| State | Glyph | VoiceOver label (vi / en) |
|---|---|---|
| Vietnamese active | `V` in a rounded square | "Đang gõ tiếng Việt" / "Vietnamese typing on" |
| English active | `E` in a rounded square | "Đang gõ tiếng Anh" / "English typing" |
| Ignored app (rule) | `E` with a small dot | "Bỏ qua ứng dụng này" / "Ignored in this app" |
| Secure Input active | `V` or `E` with a lock badge | "Ô bảo mật đang bật" / "Secure input active" |
| Paused (non-Latin input source) | dimmed glyph | "Tạm dừng: đang dùng bộ gõ khác" / "Paused: another input source is active" |
| Permission missing or tap failed | glyph with a slash | "Chưa gõ được: cần cấp quyền" / "Not working: permission needed" |

PRD-R11 Menu layout (top to bottom). Items marked "conditional" appear only in that state.

1. Status line (conditional): plain sentence explaining the current problem, clickable to the fix. Examples: "Chưa có quyền điều khiển thiết bị. Bấm để cấp quyền." / "1Password đang giữ chế độ nhập bảo mật." (with app name and icon).
2. `Tiếng Việt` / `Tiếng Anh` radio pair, with the hotkey shown on the right.
3. Separator. `Telex` / `VNI` radio pair.
4. Submenu `Với <App name>` (frontmost app before the menu opened): `Nhớ lựa chọn` (default), `Luôn tiếng Anh`, `Luôn tiếng Việt`, `Bỏ qua ứng dụng này`, then `Báo lỗi với ứng dụng này...`.
5. Separator. `Gõ tắt...`, `Cài đặt...` (Command+,).
6. Separator. `Báo lỗi...`, `Kiểm tra cập nhật...`.
7. `Ủng hộ {{AppName}}...` (opens the About & Support pane; no badge, no counter).
8. `Thoát {{AppName}}` (Command+Q).

PRD-R12 The switch indicator (D14) is a small non-activating HUD near the screen centre bottom showing `V` or `E` for 600 ms, MUST NOT take focus, MUST respect Reduce Motion (no animation, plain fade off), and MUST NOT appear for automatic per-app switches.

PRD-R13 The menu MUST open within 100 ms and MUST NOT block typing while open.

Acceptance: a tester can tell the current mode, the reason for any problem, and the fix, from the menu bar alone, with VoiceOver on and with Increase Contrast on.

---

## 6. Hotkeys and per-app memory

### 6.1 Hotkeys

PRD-R14 The VI/EN toggle default is the Control+Shift tap (D11). The recogniser MUST: fire on release of the last modifier; cancel if any other key, mouse button or scroll occurs between press and release; cancel if the chord is held longer than 500 ms; ignore auto-repeat.

PRD-R15 Users MAY choose a different toggle from a recorder that accepts: modifier-only taps (Control+Shift, Command+Shift, Option+Shift, Control+Option, right Command alone, right Option alone), and modifier+key combos (at least one modifier plus one key). The recorder MUST capture the combo in any press order (fixes "must press Space before Control").

PRD-R16 If the user records a combo that macOS already uses (Command+Space, Control+Space, Control+Option+Space, Control+Command+Space, Command+Tab, Command+Q, Command+W), the recorder MUST accept it but show an inline warning naming the macOS feature and a link to the help page explaining how to free it in System Settings > Keyboard > Keyboard Shortcuts. Never silently refuse.

PRD-R17 Globe/fn as a toggle: MAY be offered as an option only if the platform spec confirms it can be detected reliably without conflicting with the macOS "Press Globe key to" setting; when held with another key it MUST NOT toggle. VERIFY.

PRD-R18 Only two configurable global hotkeys exist in v1: VI/EN toggle (default set, D11) and "Restore last word" (default Escape, D8; it can be turned off or recorded as another key, and the setting explains the second-press rule). No other default global hotkeys.

### 6.2 Per-app VI/EN memory and rules

PRD-R19 With D12 on, when the frontmost app changes, the mode MUST switch to the remembered mode for that app within one keystroke (the first key typed after activation already uses the right mode).

PRD-R20 The remembered mode for an app updates whenever the user toggles manually while that app is frontmost.

PRD-R21 Explicit per-app rules take precedence over memory, in this order: `Bỏ qua ứng dụng này` (ignore: the app sees raw keys, nothing is transformed, toggle does nothing and shows the ignored indicator) > `Luôn tiếng Anh` > `Luôn tiếng Việt` > remembered mode > D13. A rule MUST win on every activation (XKey bug: excluded apps re-enabled Vietnamese from stale memory).

PRD-R22 Rules are keyed by bundle identifier. Apps without a bundle identifier (command-line tools inside a terminal) inherit the host app's rule. Overlay panels (Spotlight, Raycast, Alfred, menu bar popovers) are identified by the system-wide accessibility focus (PLT-R381, PLT-R390), so the rule and the memory follow the panel the user is typing into, not the app that was frontmost before the overlay opened. Acceptance: open Spotlight over Terminal (remembered EN), type `vieetj`: Spotlight's own memory (default: inherit) applies, Terminal's EN does not.

PRD-R23 Memory MUST survive app restarts and updates and MUST be included in settings export.

Acceptance: switch to Terminal, toggle to EN, switch to Zalo (VI), back to Terminal: first keystroke is English. Set VS Code to "Bỏ qua": no transformation regardless of history.

---

## 7. Settings information architecture

PRD-R24 The Settings window MUST have at most five panes, in this order. Rarely used options sit behind a `Tùy chọn nâng cao` disclosure at the bottom of a pane, collapsed by default and remembered once expanded.

| Pane (vi / en) | Contents |
|---|---|
| **Chung / General** | Open at login (D17); toggle hotkey (D11); remember per app (D12); switch indicator (D14); interface language (D18). Advanced: sound on switch (D15), click icon to toggle (D16) |
| **Gõ phím / Typing** | Method Telex/VNI (D1) with a live practice field; tone placement traditional/modern (D2) showing `hòa`/`hoà` side by side; English restore (D4) with its two user lists (keep as typed, keep Vietnamese; ENG-R860); each learned entry shows the app it was learned in and can be removed or made global (ENG-R862). Advanced: lone `w` (D5), brackets (D6), restore-last-word hotkey (D8) |
| **Ứng dụng / Apps** | Section 9 |
| **Gõ tắt / Macros** | Section 8 |
| **Giới thiệu & Hỗ trợ / About & Support** | Version, channel, update controls (D19 to D21), diagnostics (D26), Report a problem, Export/Import/Reset settings, licences and acknowledgements, privacy summary, donation block (section 13) |

PRD-R25 Every setting MUST have a one-line explanation under it in plain language, with an example where relevant (e.g. "Ví dụ: gõ `text` vẫn ra `text`, không thành `tẽt`.").

PRD-R26 `Khôi phục mặc định` (reset) MUST exist per pane and globally, MUST ask for confirmation, and MUST offer to export current settings first. Reset does not delete macros unless the user ticks a separate checkbox.

PRD-R27 Settings changes MUST apply immediately without restart and without losing the current word.

PRD-R28 The Settings window is a normal window: it does not float above other apps, and its size and position are remembered.

Acceptance: a new user finds and changes Telex to VNI in under 15 seconds in a moderated test; no pane scrolls on a 13-inch display at default text size except Apps and Macros lists.

---

## 8. Macros (text expansion)

PRD-R29 A macro is `shortcut -> expansion` (engine contract: `01-engine.md` section 11). Shortcut: 1 to 32 printable ASCII characters without spaces (letters, digits and punctuation such as `@`, `;`, `.`, `~`); Vietnamese letters are not allowed because the shortcut is matched on the keys as typed (`dc`, not `đc`), and the editor says so. Expansion: up to 4,000 characters, multi-line allowed. The editor rejects a shortcut that equals an existing shortcut plus trailing punctuation or a trailing main-row digit (the shorter one would always fire first) and explains why (digit added on 13/11/2026, ENG-R1103).

PRD-R30 Expansion triggers when the shortcut is typed followed by space, Return, Tab or a punctuation character; the terminator is kept (`vn.` gives `Việt Nam.`). Case adapts: `vn` -> `Việt Nam`, `Vn` -> `Việt Nam`, `VN` -> `VIỆT NAM` (adaptive casing MAY be turned off per macro; it is skipped for shortcuts without letters, such as `@@`). Backspace right after an expansion followed by the restore hotkey brings the shortcut back as typed.

PRD-R31 Each macro has an enable checkbox; the list has search, sort, add, edit, duplicate, delete, and "enable all / disable all".

PRD-R32 Import MUST accept: the app's own JSON export; plain text with one `shortcut<TAB>expansion` per line; CSV with two columns; macOS Text Replacements plist (the file produced by dragging entries out of System Settings > Keyboard > Text Replacements). Import shows a preview with counts of new, duplicate and invalid rows and lets the user choose "keep mine" or "use imported" for duplicates.

PRD-R33 Macros are never sent anywhere and are excluded from diagnostics bundles (only the count is reported).

---

## 9. Apps page and compatibility

PRD-R34 The Apps pane lists apps the user has typed in (most recent first) plus apps with explicit rules. Columns: icon and name, rule (`Nhớ lựa chọn` / `Luôn tiếng Anh` / `Luôn tiếng Việt` / `Bỏ qua`), remembered mode, compatibility status.

PRD-R35 Compatibility status comes from the shipped verification file `compat/matrix.json` (owned by `02-platform.md` section 13.3 and `04-quality-release.md` QA-R17; distinct from the behaviour rules in `compat-rules.json`). Status values shown to users:
- `Hoạt động tốt` / Works: verified on a recent version.
- `Hoạt động, có lưu ý` / Works with notes: one-line note, e.g. "Trong ô địa chỉ, gợi ý tự động có thể bị tắt khi đang gõ dấu."
- `Chưa kiểm tra` / Not yet verified.
- `Hạn chế đã biết` / Known limitation: plain explanation and a workaround, e.g. "iPhone Mirroring: macOS không cho bộ gõ gửi phím vô ứng dụng này." (VERIFY each limitation before publishing).

PRD-R36 Users MUST NOT be asked to pick an "injection method" in normal use. An `Chế độ tương thích` override per app MAY exist under Advanced in the app's detail sheet, with at most three plain choices whose effect is explained in one sentence each; choosing one attaches it automatically to the next bug report for that app.

PRD-R37 Each app row has `Báo lỗi với ứng dụng này...` which opens the bug report flow pre-filled with the app's bundle ID, version and active profile.

PRD-R38 Both compatibility files (`compat-rules.json` for behaviour, `compat/matrix.json` for verification status) ship inside the app and update only with app updates (no separate download in v1, PLT-R504). The website compatibility matrix is generated from `compat/matrix.json`.

PRD-R39 Tier lists (initial; maintained per QA-R):
- Tier 1 (re-verified for every stable release candidate; every row at most 90 days old at release time, PLT-R531, QA-R19): Safari, Chrome, Edge, Firefox, Arc or its successor, Notes, TextEdit, Pages, Word, Excel, PowerPoint, Outlook, Google Docs and Sheets (in Chrome and Safari), Zalo, Messenger (web and app), Telegram, Slack, Discord, Notion, Obsidian, VS Code, Cursor, Terminal, iTerm2, JetBrains IDE (one), Spotlight, Finder rename, Figma.
- Tier 2 (verified every minor release): Raycast, Alfred, Ghostty, WezTerm, Warp, tmux in a terminal, Teams, Zoom chat, LibreOffice, OneNote, Anki, Adobe Illustrator, Photoshop, InDesign, Affinity, Canva, DaVinci Resolve, Logi Options+ coexistence, Microsoft Remote Desktop / Windows App, Chrome Remote Desktop, a full-screen game, iPhone Mirroring.

---

## 10. Onboarding

PRD-R40 Onboarding runs on first launch and can be reopened from About & Support. It MUST be completable in under 90 seconds by a user who already knows Telex. Every screen has `Quay lại` and, except permissions, `Bỏ qua`. Window: 640 x 480 pt, centred, not floating. Copy below is a draft for the Vietnamese UI (English UI uses an equivalent translation); tone is neutral and friendly, uses "bạn", no slang, no exclamation marks except the final screen.

**Screen 1: Welcome**
- Title: `Chào mừng bạn đến với {{AppName}}`
- Body: `Bộ gõ tiếng Việt cho Mac. Cài đặt chỉ mất khoảng một phút, sau đó bạn cứ gõ như bình thường.`
- Footnote: `{{AppName}} không gửi nội dung bạn gõ đi đâu cả và không lưu lại những gì bạn gõ.`
- Button: `Bắt đầu`

**Screen 2: Permission**
- Title: `Cho phép {{AppName}} nhận phím gõ`
- Body: `Để thêm dấu khi bạn gõ, macOS cần bạn cho phép {{AppName}} trong mục Quyền riêng tư & Bảo mật.`
- Bullets: `{{AppName}} chỉ xử lý phím khi bạn gõ chữ.` / `Ô mật khẩu luôn được bỏ qua.` / `Không có dữ liệu nào rời khỏi máy của bạn.`
- Dynamic instruction (by macOS version): on macOS 27 and later `Mở Cài đặt hệ thống > Quyền riêng tư & Bảo mật > Điều khiển thiết bị và truy cập dữ liệu, rồi bật {{AppName}}.`; on macOS 15 and 26 the same with `Trợ năng`. VERIFY the exact Vietnamese pane names on each macOS version from a Vietnamese-language system before release; the English names are "Device Control and Data Access" (macOS 27) and "Accessibility" (earlier). Names come from the OS-version table of PLT-R704, never from code.
- Button: `Mở Cài đặt hệ thống`. A short looping illustration (static image when Reduce Motion is on) shows the toggle.
- Live state: the screen polls permission state and advances automatically within 1 s of the grant, showing `Đã cấp quyền` with a check mark. Accessibility is the only permission requested up front (PLT-R701); Input Monitoring is requested only if macOS demands it for the tap (PLT-R702), and in that case the screen says so explicitly and offers `Mở lại {{AppName}}` if a relaunch is needed. If the app was launched from the DMG or another temporary location, the move-to-Applications offer (PLT-R710) comes before this screen.
- Help link: `Không thấy {{AppName}} trong danh sách?` opens a sheet: remove and re-add steps, and a `Đặt lại quyền` button that resets only this app's entry after confirmation.

**Screen 3: Typing method**
- Title: `Bạn gõ kiểu nào?`
- Two cards: `Telex` (example `tieengs Vieetj -> tiếng Việt`), `VNI` (example `tie61ng Vie65t -> tiếng Việt`). Telex preselected.
- Practice field under the cards, live.
- Button: `Tiếp tục`

**Screen 4: Switching between Vietnamese and English**
- Title: `Chuyển Việt / Anh`
- Body: `Nhấn rồi thả Control + Shift để chuyển. Biểu tượng trên thanh menu hiện V khi gõ tiếng Việt, E khi gõ tiếng Anh.`
- Second paragraph: `{{AppName}} nhớ lựa chọn của bạn cho từng ứng dụng. Ví dụ: Terminal luôn tiếng Anh, Zalo luôn tiếng Việt.`
- Third paragraph: `Từ tiếng Anh như text, user, wifi sẽ tự giữ nguyên, nên phần lớn thời gian bạn không cần chuyển.`
- Link: `Đổi phím chuyển` opens the recorder inline.
- Button: `Tiếp tục`

**Screen 5: Conflicts (conditional)**
- Shown only if another Vietnamese input method is running (XKey, OpenKey, EVKey, Gõ Nhanh, PHTV, GoTiengViet, or others listed in the platform spec) or a built-in Vietnamese input source is enabled.
- Title: `Có bộ gõ khác đang chạy`
- Body: `Hai bộ gõ cùng lúc sẽ làm lặp hoặc mất chữ. Bạn nên thoát {{OtherApp}} và tắt nó khi đăng nhập.`
- Buttons: `Hướng dẫn thoát {{OtherApp}}` (help page), `Kiểm tra lại`. The app MUST NOT quit or modify other apps itself.
- For the built-in input source: `Bạn có thể giữ hoặc gỡ bộ gõ Tiếng Việt của macOS. Khi dùng {{AppName}}, hãy chọn bàn phím ABC hoặc U.S.` with a button to open Keyboard settings.

**Screen 6: Import (conditional)**
- Shown if a known export file or a known competitor app is detected (section 15). Title: `Mang gõ tắt và cài đặt từ {{OtherApp}}`. Body: `Bạn có thể chuyển danh sách gõ tắt từ {{OtherApp}} sang bằng tệp văn bản theo mẫu.` Buttons: `Chọn tệp...`, `Để sau`. (No importer reads another input method's own files yet: the user exports or retypes the list in the text template of PRD-R32. Body changed by the product owner on 13/11/2026.)

**Screen 7: Try it**
- Title: `Thử gõ một chút`
- Three checklist items in a text field, each ticks when done: type `Tiếng Việt có dấu`; type `text user wifi` and see it unchanged; press the toggle hotkey once and back.
- Button: `Xong`

**Screen 8: Done**
- Title: `Xong rồi!`
- Body: `{{AppName}} nằm trên thanh menu, góc trên bên phải màn hình.` An arrow points at the icon.
- Checkbox (checked): `Mở {{AppName}} khi đăng nhập`
- Button: `Bắt đầu gõ`
- No donation prompt, no newsletter, no rating request.

PRD-R41 If the user closes onboarding before granting permission, the menu bar icon shows the slashed state and the status line offers to resume onboarding at screen 2.

PRD-R42 Onboarding MUST NOT show again after completion, including after updates, unless permissions are lost (then only screen 2 is shown, with the line `macOS đã tắt quyền của {{AppName}}, thường sau khi cập nhật hệ điều hành. Bật lại là gõ được ngay.`).

Acceptance: 5 moderated first-time users (at least 2 non-technical) complete onboarding unaided; time to first correct Vietnamese word under 2 minutes for all.

---

## 11. Error states, empty states, diagnostics and bug reports

### 11.1 Error and empty states

PRD-R43 Every error message MUST state what happened, which app or component is involved, and one concrete action. No error codes alone, no "unknown error".

| Situation | Where shown | Copy draft (vi) | Action |
|---|---|---|---|
| Permission missing or revoked | Menu status line, icon slashed | `Chưa có quyền nhận phím gõ. {{AppName}} đang tạm dừng để không ảnh hưởng bàn phím.` | `Cấp quyền...` |
| Secure Input held by another app | Menu status line, lock badge | `{{HolderApp}} đang bật chế độ nhập bảo mật, nên mọi bộ gõ đều tạm dừng. Thường do một ô mật khẩu còn mở.` | `Hiện {{HolderApp}}`; if unknown holder: `Không xác định được ứng dụng. Hướng dẫn...` |
| Tap disabled by the system and re-enabled | Nothing visible if recovered within 1 s; otherwise status line | `Bộ gõ vừa bị macOS tạm ngắt và đã chạy lại.` | `Báo lỗi...` |
| Non-Latin input source active | Dimmed icon, status line | `Đang dùng bàn phím {{SourceName}}. {{AppName}} tạm dừng.` | none |
| App in Known limitation list | Status line when that app is frontmost | one-line limitation text | `Tìm hiểu thêm` |
| Update failed | Update window | `Không tải được bản cập nhật. Bạn vẫn đang dùng bản {{Version}}, mọi thứ hoạt động bình thường.` | `Thử lại`, `Tải từ trang web` |
| Import file invalid | Import sheet | `Tệp này không đúng định dạng. Dòng 12: thiếu phần nội dung gõ tắt.` | `Chọn tệp khác` |
| Macros empty | Macros pane | `Chưa có gõ tắt nào. Ví dụ: gõ "vn" để ra "Việt Nam".` | `Thêm gõ tắt`, `Nhập từ tệp...` |
| Apps list empty | Apps pane | `Các ứng dụng bạn gõ sẽ hiện ở đây để bạn đặt quy tắc riêng.` | none |

PRD-R44 When permission is missing or the tap is not running, keyboard input MUST pass through unchanged (fail open). The app MUST never leave the keyboard unusable.

### 11.2 Diagnostics

PRD-R45 Diagnostics MUST NOT contain typed characters, words, macro contents, clipboard contents or window titles. Allowed fields: app version and build, macOS version, hardware class (Apple silicon / Intel), keyboard layout ID, enabled input sources (IDs only), settings snapshot (values, no macro text), permission states, Secure Input state and holder app name, frontmost app bundle ID and version, active compatibility profile, recent event categories (key class such as letter, digit, backspace, modifier; never the key value), injection outcome codes, timing percentiles, tap disable/re-enable counts, crash and hang reports produced locally by the system.

PRD-R46 Content-free health events and timing histograms live in memory and in a small rotating log (PLT-R903: at most 5 files of 1 MB, 14 days, readable only by the user), so a crash or a tap timeout that happened before the user opened the report can still be explained. The typing trace (D26, PLT-R905) is the only artefact that contains typed characters: started by hand, visible countdown, stored for at most 24 hours, reviewed by the user before export, never uploaded automatically.

### 11.3 One-click bug report

PRD-R47 `Báo lỗi...` opens a sheet with:
1. `Lỗi xảy ra ở ứng dụng nào?` app picker preselected with the last frontmost app.
2. `Chuyện gì xảy ra?` choice chips: `Mất chữ`, `Lặp chữ`, `Sai dấu`, `Không gõ được tiếng Việt`, `Chậm / giật`, `Khác`.
3. `Bạn gõ gì và mong ra gì?` free text, with a hint: `Bạn tự gõ lại ví dụ ở đây. {{AppName}} không tự gửi những gì bạn đã gõ.`
4. A `Xem trước dữ liệu sẽ gửi` disclosure showing the exact redacted diagnostics text.
5. Buttons: `Mở GitHub` (opens a prefilled issue form URL with the summary in the body and copies the full diagnostics block to the clipboard, telling the user to paste it), `Gửi qua email` (opens a mail draft to the support address with the diagnostics as an attachment), `Lưu tệp...`.

PRD-R48 Clipboard use in the report flow is the only time the app writes to the user's clipboard on purpose, apart from the opt-in paste compatibility mode for a specific app, which saves and restores the clipboard around each paste (PLT-R461) and is explained when the user turns it on. The report sheet MUST say so before writing to the clipboard.

PRD-R49 The report flow MUST work without a GitHub account (email path) and MUST include a "test in the practice field" button that opens a local text field so users can check whether the problem is app-specific.

Acceptance: a non-technical tester files a usable report in under 2 minutes; a maintainer can reproduce at least 70% of beta reports from the report alone without asking for logs.

---

## 12. Update UX

PRD-R50 Updates use Sparkle 2 with the standard user driver, configured so that: automatic checks run daily (D19); stable updates download in the background and install on quit or restart (D20); the user can choose "Install now" from the update window; no update ever installs while the app is in the middle of a word.

PRD-R51 The update window MUST show release notes in the interface language, short (5 lines max visible, "more" link to the changelog), led by user-visible fixes listed by app name.

PRD-R52 After an update, settings, per-app memory, macros and permissions MUST be intact. The first launch after an update shows nothing unless a setting meaning changed (then one line in the menu status line for 24 hours, linking to release notes). Permission loss after an update is a release-blocking bug (QA-R).

PRD-R53 Users MAY switch channel (Stable/Beta) in About & Support. Switching from Beta back to Stable offers the next stable when it is newer; it does not downgrade automatically and says so.

PRD-R54 Critical updates (security, data loss) are marked as such and show the window immediately but remain dismissible.

PRD-R55 No Sparkle system profile submission (disabled, not offered).

---

## 13. Donation UX

PRD-R56 {{AppName}} is free. Donations are a tip jar, never a nag.

PRD-R57 Donation entry points, and only these: the `Ủng hộ {{AppName}}...` menu item; the donation block in About & Support; the website `/ung-ho` page; the GitHub repository Sponsor button, only if GitHub Sponsors is enabled later; one plain line at the bottom of release notes on the website (not in the in-app update window).

PRD-R58 Forbidden: popups, timers, counters, "you have typed N words" messages, badges, features locked behind donating, donation prompts in onboarding, during updates or after a crash or bug report.

PRD-R59 Donation block content: a short thank-you line (`{{AppName}} miễn phí và sẽ luôn miễn phí. Nếu thấy có ích, bạn có thể ủng hộ để Kal có thêm thời gian làm tiếp.`); a VietQR (Napas) QR code for Pa's bank account (LioBank, an OCB digital bank, NAPAS BIN 970448, account 688688678) with the bank name and the account number shown in text and the holder name shown nowhere (the VietQR payload carries no name; bank apps show the holder after lookup). No MoMo QR and no other payment link for now (decision of the product owner, 13/11/2026). QR images are bundled assets, not fetched.

PRD-R60 Polar.sh MUST NOT be used for donations (its acceptable-use policy prohibits donations and sponsorship); Polar is only an option if a paid product is ever sold. Buy Me a Coffee is not used (Vietnam is not a payout country).

PRD-R61 No public sponsor list for now (decision of the product owner, 13/11/2026); if one is added later, it lists only sponsors who opt in, on the website. No donor data is stored in the app.

---

## 14. Localisation and accessibility

### 14.1 Localisation

PRD-R62 The UI ships in Vietnamese (default, D18) and English. All strings live in a String Catalog; no hard-coded user-visible text. Vietnamese copy uses standard, neutral wording understood nationwide and avoids slang and regional idioms.

PRD-R63 Changing the interface language applies immediately without restart.

PRD-R64 System pane names in instructions MUST match the user's macOS language and version (Vietnamese system shows Vietnamese pane names). Maintain a small table per macOS version; VERIFY entries.

PRD-R65 Date, number and version formats follow the selected interface language.

### 14.2 Accessibility

PRD-R66 Every control has a VoiceOver label and hint; the menu bar icon announces its state (PRD-R10); the switch HUD posts an accessibility announcement ("Tiếng Việt" / "Tiếng Anh") instead of relying on the visual alone.

PRD-R67 Full keyboard navigation in Settings and onboarding; visible focus rings; no information conveyed by colour only; contrast meets WCAG AA in light, dark and Increase Contrast modes; Reduce Motion disables all animations.

PRD-R68 VERIFY with VoiceOver users how injected backspace-and-retype sequences are announced while typing Vietnamese; if VoiceOver reads every intermediate deletion, document the behaviour and track a 1.x improvement.

---

## 15. Migration from other input methods

PRD-R69 {{AppName}} MUST NOT read other apps' private containers or preference files silently. On macOS 27, reading other developers' app data triggers a system prompt, and it is also bad practice. Migration works from files the user exports, or from known locations only after an explicit `Nhập từ {{OtherApp}}` click.

| From | What can be imported | Source | Notes |
|---|---|---|---|
| XKey | Macros; typing method; tone style; toggle hotkey if expressible; excluded apps as "Bỏ qua" rules | XKey's settings export file and macro export file | VERIFY both formats from a real export generated with a current XKey build (observe the file, do not read XKey source). Unknown keys are ignored and listed in the import summary |
| OpenKey | Macros | OpenKey macro export file | VERIFY format from a real export |
| EVKey (macOS legacy or GPL rewrite) | Macros | Exported macro file | VERIFY format; legacy EVKey Mac may store macros only internally, in which case use the plain-text path |
| Gõ Nhanh | Macros, per-app settings if exportable | Exported file | VERIFY whether an export exists |
| PHTV | Macros | Exported file | VERIFY |
| Built-in macOS Vietnamese | Nothing to import; Text Replacements plist (PRD-R32) | User drag-out | Onboarding explains choosing ABC/U.S. instead of the built-in Vietnamese source |
| Any | Macros | Plain text TAB-separated or CSV | Universal fallback, documented on the website with a template |

PRD-R70 Importers MUST be tolerant: skip invalid rows with a reason, never abort the whole import for one bad row, and never overwrite existing user data without the duplicate choice (PRD-R32).

PRD-R71 The website has a migration page per source app with screenshots of how to export from that app and how to stop it from launching at login.

PRD-R72 Settings export format (own): versioned JSON, UTF-8, documented on the website, containing settings, per-app rules and memory, and macros, with a `schemaVersion` field. Import of a newer schema shows which fields were skipped.

---

## 16. Website ({{app-slug}}.kal.vn)

PRD-R73 Static site, Vietnamese at `/` and English at `/en/`. Required pages:

| Path (vi) | Purpose | Must contain |
|---|---|---|
| `/` | Landing | One-sentence value statement, 20-second screen recording of typing (Telex, English restore, per-app switch), download button with version and minimum macOS, `brew install --cask {{app-slug}}` line, three proof points (no telemetry, free, open-source engine), link to compatibility |
| `/tai-ve` | Download | Latest stable DMG and beta DMG, SHA-256, signature and notarization statement, system requirements, Homebrew instructions, older versions archive |
| `/tuong-thich` | Compatibility matrix | Generated from the shipped compatibility data: app, status, notes, last verified date and macOS version; filter by category; "report an app" link |
| `/nhat-ky-thay-doi` | Changelog | Per release: date, channel, user-visible changes grouped by app, known issues |
| `/rieng-tu` | Privacy | Plain-language list of everything the app stores and sends (update check only), what diagnostics contain and do not contain, website analytics policy |
| `/ho-tro` | Support | FAQ, troubleshooting by symptom (permission, Secure Input, conflicts, app-specific), how to report a bug, response targets (QA-R), migration guides |
| `/ung-ho` | Donate | Same content as the in-app block |
| `/appcast.xml` | Sparkle feed | One stable URL that never moves; beta builds are items with `sparkle:channel="beta"` in the same feed (PLT-R1101, QA-R28) |

PRD-R74 The website MUST NOT use trackers or cookies that require consent. Traffic numbers come from cookieless aggregate analytics (decision of the product owner, 13/11/2026): PostHog Cloud in cookieless mode (no cookies, no local storage, IP addresses not stored), so no consent banner is needed. The project key is a configuration value; while it is empty the site loads no analytics. `/rieng-tu` describes exactly what is collected.

PRD-R75 The appcast host MUST serve over HTTPS from a domain Pa controls, so the feed can outlive any hosting provider.

---

## 17. Success metrics without telemetry

PRD-R76 Success is measured only from data that exists without instrumenting users:

| Metric | Source | Target for 1.0 + 3 months |
|---|---|---|
| Downloads | GitHub release asset counts; Homebrew public install analytics | Trend up month over month |
| Active installs (approx.) | Daily count of appcast requests in server logs, aggregated, IP addresses not retained, disclosed on `/rieng-tu` | Trend; no per-user identifiers |
| Reopen rate | GitHub issues (QA-R) | Under 10% (XKey: 32%) |
| App-specific share of bugs | Issue labels | Falling release over release |
| Time to fix P0/P1 | Issue timestamps | P0 within 72 h, P1 within the next release |
| "Toggle setting X" resolutions | Issue labels `resolution:setting-workaround` | Under 5% of closed bugs; each one triggers a defaults review |
| Compatibility coverage | Matrix data | 100% of Tier 1 rows re-verified for every stable release candidate and at most 90 days old at release time (PLT-R531); Tier 2 within 90 days |
| Settings loss after update | Issue label `update-regression` | Zero |
| Qualitative | Voluntary feedback, forum mentions (voz, tinhte, Facebook groups) | Net positive sentiment; tracked manually monthly |

PRD-R77 No in-app survey, rating prompt or usage counter.

---

## 18. Open decisions for Pa

All answered on 13/11/2026 except the app licence; every answer and where it is implemented is listed in `docs/decisions/0005-pa-decisions-2026-11-13.md`.

1. Product name: decided; the display name and slug live only in `Config/Brand.xcconfig` and `scripts/brand.env`, and this spec keeps the placeholders.
2. App licence: not decided; files outside the engine keep `LicenseRef-App-Pending`.
3. Default tone placement: traditional, with the setting (D2).
4. Restore-last-word hotkey: Escape by default, with an on/off setting and automatic exclusions through compatibility rules (D8, PRD-R18, PLT-R353).
5. Website analytics: PostHog Cloud in cookieless mode (PRD-R74).
6. Donation: bank VietQR only, bank name and account number shown, holder name not shown, no public sponsor list for now (PRD-R59, PRD-R61).
7. Minimum macOS: macOS 12.0 with Intel support (PRD-R8, PLT-R106; `docs/decisions/0315-minimum-macos-12.md`).
8. Macro shortcuts: keep printable ASCII without spaces, no Vietnamese letters (PRD-R29).
