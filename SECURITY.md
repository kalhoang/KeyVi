# Security policy

KeyVi™ handles keystrokes, so security reports are taken seriously. This policy follows QA-R56 to QA-R58 of the specification ([spec/04-quality-release.md](spec/04-quality-release.md) section 6).

## Supported versions

| Version | Supported |
|---|---|
| Latest stable release | Yes |
| Latest beta release | Yes |
| Older releases | No. Update to the latest stable or beta |

1.0.0, of 17 November 2026, is the first public release. The private test builds made before it are not supported.

## Reporting a vulnerability

Please report privately. Do not open a public issue, a Discussion or a pull request for a vulnerability.

1. **GitHub private vulnerability reporting (preferred).** Use the "Report a vulnerability" button on the repository's Security tab, or go to `https://github.com/kalhoang/KeyVi/security/advisories/new`.
2. **Email.** `keyvi@kal.vn` (the project mailbox, confirmed by the maintainer on 2026-11-13; put "Security" in the subject). Encrypt only if the maintainer has published a key; otherwise send a short description and ask for a secure channel.

Please include:

- What the problem is and which component it affects (app, engine, updater, website, release scripts).
- The version or commit, macOS version and architecture.
- Steps to reproduce, or a proof of concept.
- What an attacker gains (for example: typed content exposed, a malicious update accepted).
- Whether and when you plan to disclose publicly.

Do not include real typed text, passwords or personal data in your report. Use canary strings such as `zqxkanary`.

## What to expect

| Step | Target |
|---|---|
| Acknowledgement of your report | Within 72 hours |
| Severity triage | Within 7 days |
| Fix for high or critical severity | Within 30 days |
| Fix for other severities | Within 90 days |

These are targets for a one-person project, stated honestly. If a deadline slips you will hear why.

Process:

1. The maintainer confirms the report and agrees a severity with you.
2. A fix is developed in a private advisory branch, with a test that reproduces the problem.
3. Disclosure is coordinated with you. You are credited in the advisory unless you decline.
4. A GitHub Security Advisory is published, with a CVE through GitHub when warranted.
5. The fix ships as a critical update (Sparkle `sparkle:criticalUpdate`) when it concerns security or data loss. If a released build is actively harmful, the appcast item is pulled first ([docs/runbooks/appcast-pull.md](docs/runbooks/appcast-pull.md)).

## Scope

In scope:

- Anything that could expose typed content: logging, diagnostics, bug-report bundles, typing traces, crash reports, IPC.
- Update chain integrity: the appcast feed, EdDSA signatures, download and installation.
- Code signing, notarization, entitlements and permission handling.
- Parsing of imported files (settings import, macro import).
- Website and appcast hosting, and the release scripts and CI workflows in this repository.

Out of scope:

- Issues that require an already compromised user account with the same privileges.
- Social engineering of the maintainer or users.
- Denial of service against the website.
- Bugs that only affect typing correctness or compatibility with an app: please use the issue forms for those.
- Findings in third-party software (report them upstream; tell us if our configuration makes them exploitable).

## Design facts that help you test

- The app is not sandboxed (an event tap needs Accessibility), runs with the hardened runtime and has no entitlements.
- The only network traffic is the update check. No telemetry, no remote configuration.
- No listening sockets, no XPC listeners, no AppleScript dictionary. A URL scheme may only open the Settings window.
- The Sparkle EdDSA private key is never stored in CI. Update signing happens on the maintainer's Mac.

Please do not test against other people's machines and do not access data that is not yours.
