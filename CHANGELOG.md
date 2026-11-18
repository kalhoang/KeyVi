# Changelog

All notable changes to KeyVi are documented in this file. Version 1.0.0 is the first public release; the private test builds before it are not listed.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the app uses [Semantic Versioning](https://semver.org/) (QA-R26). The engine package is versioned separately and keeps its own changelog (QA-R27).

Writing rules (QA-R66, QA-R67): entries are in user-visible language and name the apps involved ("Fixed duplicated letters in the Chrome address bar", not "Fixed injection bug"). Each release gets Vietnamese and English release notes; this file is the English source of the website changelog page, and [CHANGELOG.vi.md](CHANGELOG.vi.md), with the same version headings and its group headings in Vietnamese, is the Vietnamese one. A pull request that changes user-visible behaviour adds its entry under `Unreleased` in the same PR.

Release headings use the form `## [X.Y.Z] - YYYY-MM-DD` for stable releases and `## [X.Y.Z-beta.N] - YYYY-MM-DD` for betas. Entries are grouped under Added, Changed, Deprecated, Removed, Fixed and Security. Known issues go in a `### Known issues` group. The details stay here: when a release is cut, its `Unreleased` entries move under its heading as they are. The update window shows short release notes instead, at most five visible lines per language (list items and paragraphs; group headings do not count, PRD-R51), which `scripts/publish-release` checks before it publishes anything. A section of five lines or fewer is published as it stands, without groups if it has no more to say (1.0.0 is one); for a longer section, the release notes are two short files that sum it up, passed with `--notes-en` and `--notes-vi`, and the update window links to the full section here.

## [Unreleased]

### Fixed

- The first word typed right after an app moves the focus to another field by itself no longer loses its marks or gets a wrong one ("tieengs" instead of "tiếng").
- The first word typed right after an app opens its own search panel no longer loses its marks ("vieejt" instead of "việt") when the panel takes the focus a moment after the first key.
- KeyVi now keeps watching an app that refused its focus notifications for a few seconds after it launched, so moves between that app's fields are no longer missed until you switch apps.
- In apps that answer slowly, such as Safari and Google Chrome, a word typed after a short pause, or right after Command+S opens a save dialog, splits in two or loses its marks less often ("nguyeẽn" instead of "nguyễn", "đuơngf" instead of "đường").

## [1.0.1-beta.1] - 2026-11-18

### Changed

- When the last key of a word removes its marks (z in Telex, 0 in VNI), the plain letters you see now stay when you finish the word, for example "duong", instead of turning back into the keys you typed.
- The English phrases "day off", "sale off" and "a mess" now keep the word you typed instead of becoming "day of", "sale of" and "a mes".

### Fixed

- In Terminal, iTerm2 and code editors, commands such as chown, awk and ps -ef now stay as you typed them instead of turning into Vietnamese words (chơn, ăk, è); inside a Vietnamese sentence they still type Vietnamese.

## [1.0.0] - 2026-11-18

- First public release of KeyVi: write Vietnamese (Telex or VNI) and English in the same sentence without switching. English words such as "file" and "server" stay as you typed them, whichever key ends the word, and words that can be either, such as as or á, follow the words around them.
- Escape right after a word gives back the keys you typed, and a second Escape works as usual. KeyVi leaves Escape alone in terminals, code editors, games, remote desktop apps and launchers such as Spotlight, Raycast and Alfred.
- KeyVi learns from your corrections in each app: a word you correct the same way twice in one app is typed that way there from then on. Settings > Typing lists the learned words with their app, so you can review them, make one apply everywhere or forget it.
- Each app remembers its own Vietnamese or English mode and can have its own rule. Macros expand your shortcuts into longer text, and the word lists "Keep as typed" and "Keep as Vietnamese" fix how the words you add to them come out.
- Ready-made settings for common apps, among them Safari, Google Chrome, Slack, Zalo, Microsoft Office, Spotlight, Terminal, iTerm2 and Visual Studio Code. Nothing you type leaves your Mac: the only automatic network traffic is the update check.
