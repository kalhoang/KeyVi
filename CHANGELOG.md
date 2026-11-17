# Changelog

All notable changes to KeyVi are documented in this file. Version 1.0.0 is the first public release; the private test builds before it are not listed.

The format follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) and the app uses [Semantic Versioning](https://semver.org/) (QA-R26). The engine package is versioned separately and keeps its own changelog (QA-R27).

Writing rules (QA-R66, QA-R67): entries are in user-visible language and name the apps involved ("Fixed duplicated letters in the Chrome address bar", not "Fixed injection bug"). Each release gets Vietnamese and English release notes; this file is the English source of the website changelog page, and [CHANGELOG.vi.md](CHANGELOG.vi.md), with the same headings, is the Vietnamese one. A pull request that changes user-visible behaviour adds its entry under `Unreleased` in the same PR.

Release headings use the form `## [X.Y.Z] - YYYY-MM-DD` for stable releases and `## [X.Y.Z-beta.N] - YYYY-MM-DD` for betas. Entries are grouped under Added, Changed, Deprecated, Removed, Fixed and Security. Known issues go in a `### Known issues` group. The details stay here: when a release is cut, its `Unreleased` entries move under its heading as they are. The update window shows short release notes instead, at most five visible lines per language (list items and paragraphs; group headings do not count, PRD-R51), which `scripts/publish-release` checks before it publishes anything. A section of five lines or fewer is published as it stands, without groups if it has no more to say (1.0.0 is one); for a longer section, the release notes are two short files that sum it up, passed with `--notes-en` and `--notes-vi`, and the update window links to the full section here.

## [Unreleased]

## [1.0.0] - 2026-11-18

- First public release of KeyVi: write Vietnamese (Telex or VNI) and English in the same sentence without switching. English words such as "file" and "server" stay as you typed them, whichever key ends the word, and words that can be either, such as as or á, follow the words around them.
- Escape right after a word gives back the keys you typed, and a second Escape works as usual. KeyVi leaves Escape alone in terminals, code editors, games, remote desktop apps and launchers such as Spotlight, Raycast and Alfred.
- KeyVi learns from your corrections in each app: a word you correct the same way twice in one app is typed that way there from then on. Settings > Typing lists the learned words with their app, so you can review them, make one apply everywhere or forget it.
- Each app remembers its own Vietnamese or English mode and can have its own rule. Macros expand your shortcuts into longer text, and the word lists "Keep as typed" and "Keep as Vietnamese" fix how the words you add to them come out.
- Ready-made settings for common apps, among them Safari, Google Chrome, Slack, Zalo, Microsoft Office, Spotlight, Terminal, iTerm2 and Visual Studio Code. Nothing you type leaves your Mac: the only automatic network traffic is the update check.
