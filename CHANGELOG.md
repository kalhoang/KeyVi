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
- The Settings window looks like macOS System Settings: a sidebar runs the full height of the window and lists the five panes with their icons (the arrow keys or Command+1 to 5 switch panes), the pane name sits in the title bar, and each pane shows its settings in rounded groups, with a short explanation under each title and the switch or menu on the right. In the Apps pane, app names get the room the other columns do not need, and Details and Report a Problem with This App are under the list for the selected app and, from macOS 13, in the app's context menu.

### Fixed

- Spotlight: words that Spotlight completed as you typed came out wrong ("tex" became "teẽ", "vieejt" became "vieêệt"), and when Spotlight was opened a second time, Escape could type the word back instead of clearing the search. KeyVi now notices Spotlight opening and closing at once, so its Spotlight settings apply every time and stop as soon as Spotlight closes, and the next words in your app use that app's settings again.
- Save dialogs and other sheets: typing a name right after Command+S (in TextEdit, for example) could split the first word ("dduongwf" gave "ddường"). The word now stays whole when the field already shows the letters you typed.
- Backspace no longer changes letters it does not delete: one w (or VNI 7) on uo kept the horn on ư only until the ơ was deleted, so thươ + Backspace showed thu instead of thư.
- In chat apps built on Electron (Slack, Messenger, Zalo and others), one Backspace could delete a whole word: the letters an edit retyped after a Backspace were sent on the Delete key, which the app read as more Backspaces. Edits now use a letter key.
- The permission screen of the first-run guide no longer keeps waiting after you turn on KeyVi in System Settings > Privacy & Security > Device Control and Data Access (Accessibility before macOS 27): it sees the switch within a second, without reopening the app, and it never moves on while a permission KeyVi needs is still missing.
- Chat apps that act on the key itself rather than on the typed character, such as some chat apps built on Electron and web chats in Google Chrome, no longer send a message before its last correction is typed: `thuowr` followed by Return now sends "thuở", not "th". KeyVi types the correction first, then Return, Tab or Space follows once, so Tab no longer moves the focus away in the middle of a correction.
- During setup, after you turn on Accessibility while Input Monitoring is still needed, the permission step no longer shows as done, briefly or for good, and waking the Mac or opening the menu at that moment no longer leaves KeyVi stuck retrying. It goes straight to asking for Input Monitoring.
- Words that are both Vietnamese and English, such as á, bên and cả, now stay Vietnamese after an English word in a Vietnamese sentence: "Khúc cài các app cần thiết trên win cũng tricky á." keeps "á" instead of turning it into "as", and "trên server bên kia" keeps "bên". English sentences still stay English ("I think this is as good as it gets").
- The "This app misbehaves" panel can now be used with the keyboard: Tab and Full Keyboard Access reach the symptom choices, the report preview and the final offers. During the guided test the keyboard focus stays in the field being tested.
