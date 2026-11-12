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
