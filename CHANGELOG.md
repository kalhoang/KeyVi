# Changelog

All notable changes to KeyVi are documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the app uses [Semantic Versioning](https://semver.org/) (QA-R26). The engine package is versioned separately and keeps its own changelog (QA-R27).

Writing rules (QA-R66, QA-R67): entries are in user-visible language and name the apps involved ("Fixed duplicated letters in the Chrome address bar", not "Fixed injection bug"). Each release gets Vietnamese and English release notes; this file is the English source of the website changelog page. A pull request that changes user-visible behaviour adds its entry under `Unreleased` in the same PR.

Release headings use the form `## [X.Y.Z] - YYYY-MM-DD` for stable releases and `## [X.Y.Z-beta.N] - YYYY-MM-DD` for betas. Entries are grouped under Added, Changed, Deprecated, Removed, Fixed and Security. Known issues go in a `### Known issues` group.

## [Unreleased]

### Added

- Project scaffold, written specification and clean-room rules. No installable build exists yet (pre-alpha).
- Project documentation: README (English and Vietnamese), contributing guide, security policy, code of conduct, third-party notices, maintainer runbooks, support replies, provenance review process, issue forms and pull request template.
- Compatibility script for testing an app in under 3 minutes (`compat/SCRIPT.md`).
- Cốc Cốc gets the browser hint when a password field turns on Secure Input: the menu suggests clicking outside the password field or switching tabs, as it does for Safari, Google Chrome, Microsoft Edge, Firefox, Arc and Brave.
- Pressing z (Telex) or 0 (VNI) a second time removes the letter marks too: daauszz gives dau.
- Words that are both English and Vietnamese, such as as/á or car/cả, are decided from the words around them. When the next word shows which language you are writing, KeyVi also fixes the word before it (tricky á hell becomes tricky as hell); press Escape right after to undo. Settings > Typing > Advanced options has a switch for it, and app rules turn it off in Terminal and code editors.
- KeyVi learns which reading you choose for those words, in every app, from your corrections and from the words you leave as typed. Settings > Typing has a switch for it and a list where you can review and forget learned words; the list stays on this Mac.
- Antigravity is handled like Visual Studio Code and its other forks: KeyVi types with its code editor settings there, and Escape keeps its editor meaning instead of restoring the last word.
- The Diagnostics window explains when an app keeps turning Secure Input on and off while you type, which can keep some keys from reaching KeyVi, and suggests how to find that app. The copied report carries the same explanation.

### Changed

- Learned words are now kept per app. A word KeyVi learns from your corrections (when you restore or keep the same word twice in one app) applies only in the app where you taught it. Words learned before this change stay global. Settings > Typing shows the app next to each learned word and can make an entry global.
- Escape restores the last word by default: press it right after a word to get back the keys you typed, and press it again to send Escape as usual, so it still closes dialogs. It is off automatically in terminals, code editors, games and remote desktop apps, and in launchers such as Spotlight, Raycast and Alfred, where Escape has its own job. You can turn it off or choose another key in Settings > Typing.
- Macro shortcuts that differ only by a trailing digit, for example `k` and `k1`, are now refused, because a digit ends a shortcut like punctuation does, so typing `k1` would always expand `k`. A pair saved by an earlier build still loads: the shorter shortcut keeps working, the longer one stops expanding and the Macros pane marks both. To unblock saving, delete or rename one of the pair.
- KeyVi is now distributed under GPL-3.0-or-later. The disk image includes the licence (`LICENSE.txt`) and the third-party notices (`THIRD_PARTY_NOTICES.txt`).
- The typing engine packages, the word-list pipeline and the reference model are now under the Mozilla Public License 2.0 instead of MIT; the app stays GPL-3.0-or-later.
- The Apps pane calls the compatibility mode chosen by a guided test "Set by the guided test" ("Theo kết quả thử tự động" in Vietnamese), the name the menu and the Diagnostics window use for that test, and VoiceOver reads the same name.
- On a Vietnamese macOS, the Secure Input hint for Terminal names the menu item as Terminal shows it, "Nhập dùng Bàn phím An Toàn", followed by its English name "Secure Keyboard Entry". The support page and the support replies use the same words.
- The permission screen of the first-run guide lists each permission KeyVi needs with its state as System Settings names it ("Đã bật" or "Cần bật"), and its button names and opens exactly the pane that is still missing. Input Monitoring is listed only if macOS needs it for typing, with a "Mở lại KeyVi" button for a switch that is on but not yet in effect.
- The "Thử gõ một chút" screen of the guide quotes each phrase to type, shows the keys to press for Telex or VNI, and names the switch shortcut from Settings and what it does. The last button of the guide reads "Bắt đầu" ("Start") instead of "Bắt đầu gõ".
- The Settings window looks like macOS System Settings: a sidebar runs the full height of the window and lists the panes with their icons (the arrow keys or Command+1 to 7 switch panes), the pane name sits in the title bar, and each pane shows its settings in rounded groups, with a short explanation under each title and the switch or menu on the right. In the Apps pane, app names get the room the other columns do not need, and Details and Report a Problem with This App are under the list for the selected app and, from macOS 13, in the app's context menu.
- Settings has seven panes: About & Support is now About (version, updates, the welcome guide and the donation block), Support (report a problem, diagnostics, help on the website and by email, settings export, import and reset, privacy) and Licences (the copyright line, the app's GPL licence, the typing engine's licence, now shown in the app, and the acknowledgements, which replace the old licences sheet). The menu's "Ủng hộ KeyVi..." opens About.
- The donation block shows the account details, each with a Copy button, a text to share through the macOS share menu or copy, and the VietQR code beside them.
- Vietnamese wording: the Typing pane is "Kiểu gõ" (was "Gõ phím"), macros are "Viết tắt" everywhere (pane, menu, editor, import and export, messages and VoiceOver), "Mở khi đăng nhập" reads "Khởi động cùng hệ thống", the copy says "file" instead of "tệp", and the diagnostics, settings transfer and privacy lines of Support are reworded.
- The About, Support and Licences panes, the README and the support replies write the name with its trademark sign, KeyVi™.
- Backspace on a letter that undid a tone or mark deletes just that letter; the tone or mark no longer comes back.

### Fixed

- Settings: "Tùy chọn nâng cao" (Advanced options) in General and Typing could not be opened. Clicking anywhere on its row now opens and closes it, in the Apps Details sheet too.
- Spotlight: words that Spotlight completed as you typed came out wrong ("tex" became "teẽ", "vieejt" became "vieêệt"), and when Spotlight was opened a second time, Escape could type the word back instead of clearing the search. KeyVi now notices Spotlight opening and closing at once, so its Spotlight settings apply every time and stop as soon as Spotlight closes, and the next words in your app use that app's settings again.
- Save dialogs and other sheets: typing a name right after Command+S (in TextEdit, for example) could split the first word ("dduongwf" gave "ddường"). The word now stays whole when the field already shows the letters you typed.
- Backspace no longer changes letters it does not delete: one w (or VNI 7) on uo kept the horn on ư only until the ơ was deleted, so thươ + Backspace showed thu instead of thư.
- In chat apps built on Electron (Slack, Messenger, Zalo and others), one Backspace could delete a whole word: the letters an edit retyped after a Backspace were sent on the Delete key, which the app read as more Backspaces. Edits now use a letter key.
- The permission screen of the first-run guide no longer keeps waiting after you turn on KeyVi in System Settings > Privacy & Security > Device Control and Data Access (Accessibility before macOS 27): it sees the switch within a second, without reopening the app, and it never moves on while a permission KeyVi needs is still missing.
- Chat apps that act on the key itself rather than on the typed character, such as some chat apps built on Electron and web chats in Google Chrome, no longer send a message before its last correction is typed: `thuowr` followed by Return now sends "thuở", not "th". KeyVi types the correction first, then Return, Tab or Space follows once, so Tab no longer moves the focus away in the middle of a correction.
- During setup, after you turn on Accessibility while Input Monitoring is still needed, the permission step no longer shows as done, briefly or for good, and waking the Mac or opening the menu at that moment no longer leaves KeyVi stuck retrying. It goes straight to asking for Input Monitoring.
- Words that are both Vietnamese and English, such as á, bên and cả, now stay Vietnamese after an English word in a Vietnamese sentence: "Khúc cài các app cần thiết trên win cũng tricky á." keeps "á" instead of turning it into "as", and "trên server bên kia" keeps "bên". English sentences still stay English ("I think this is as good as it gets").
- The "This app misbehaves" panel can now be used with the keyboard: Tab and Full Keyboard Access reach the symptom choices, the report preview and the final offers. During the guided test the keyboard focus stays in the field being tested.
- In some apps built on WebKit, a letter typed right after a word could go missing when a key was released at the same moment as a tone key; fixed.
- When another app turned Secure Input on and off in short bursts while you typed, a word could come out garbled ("hay sao" became "hayayao"), because KeyVi did not see the keys the bursts hid and later corrected the wrong letters. KeyVi now notices a key it did not see go down and starts the next word afresh, and the diagnostics report notes when something keeps turning Secure Input on and off while you type.
- Safari and other apps that answer accessibility slowly: right after a click into a field, the first letters of a word could lose their accents when KeyVi briefly could not tell which app was in front. The word now continues once KeyVi has checked the field.
- Retyping a word after deleting back into an English or invalid word that was restored now gives Vietnamese again.
- Apps that macOS Accessibility does not name as the app you are typing in (seen with an Electron code editor) now get their compatibility settings, their remembered Vietnamese or English mode, their per-app rule and their learned words: KeyVi uses the app in front. The diagnostics report says when the app was found this way.
