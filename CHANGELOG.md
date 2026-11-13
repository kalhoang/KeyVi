# Changelog

All notable changes to {{AppName}} are documented in this file.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the app uses [Semantic Versioning](https://semver.org/) (QA-R26). The engine package is versioned separately and keeps its own changelog (QA-R27).

Writing rules (QA-R66, QA-R67): entries are in user-visible language and name the apps involved ("Fixed duplicated letters in the Chrome address bar", not "Fixed injection bug"). Each release gets Vietnamese and English release notes; this file is the English source of the website changelog page. A pull request that changes user-visible behaviour adds its entry under `Unreleased` in the same PR.

Release headings use the form `## [X.Y.Z] - YYYY-MM-DD` for stable releases and `## [X.Y.Z-beta.N] - YYYY-MM-DD` for betas. Entries are grouped under Added, Changed, Deprecated, Removed, Fixed and Security. Known issues go in a `### Known issues` group.

## [Unreleased]

### Added

- Project scaffold, written specification and clean-room rules. No installable build exists yet (pre-alpha).
- Project documentation: README (English and Vietnamese), contributing guide, security policy, code of conduct, third-party notices, maintainer runbooks, support replies, provenance review process, issue forms and pull request template.
- Compatibility script for testing an app in under 3 minutes (`compat/SCRIPT.md`).

### Changed

- Learned words are now kept per app. A word {{AppName}} learns from your corrections (when you restore or keep the same word twice in one app) applies only in the app where you taught it. Words learned before this change stay global. Settings > Typing shows the app next to each learned word and can make an entry global.
- Escape restores the last word by default: press it right after a word to get back the keys you typed, and press it again to send Escape as usual, so it still closes dialogs. It is off automatically in terminals, code editors, games and remote desktop apps, where Escape has its own job. You can turn it off or choose another key in Settings > Typing.
- Macro shortcuts that differ only by a trailing digit, for example `k` and `k1`, are now refused, because a digit ends a shortcut like punctuation does, so typing `k1` would always expand `k`. A pair saved by an earlier build still loads: the shorter shortcut keeps working, the longer one stops expanding and the Macros pane marks both. To unblock saving, delete or rename one of the pair.
- {{AppName}} is now distributed under GPL-3.0-or-later; the typing engine stays MPL-2.0. The disk image includes the licence (`LICENSE.txt`) and the third-party notices (`THIRD_PARTY_NOTICES.txt`).

### Fixed

- The "This app misbehaves" panel can now be used with the keyboard: Tab and Full Keyboard Access reach the symptom choices, the report preview and the final offers. During the guided test the keyboard focus stays in the field being tested.
