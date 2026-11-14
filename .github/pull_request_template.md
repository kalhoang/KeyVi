## Summary

<!-- What changes and why, in a few sentences. -->

Closes #<!-- issue number; every PR references an issue except typo fixes (QA-R63) -->

## Type

- [ ] fix
- [ ] feat
- [ ] refactor
- [ ] docs
- [ ] test
- [ ] chore, perf or ci

## Clean-room attestation (QA-R62, CLR-R14)

- [ ] I did not read or copy code from other Vietnamese input methods while writing this change (see spec/05-clean-room.md).

If you used an AI assistant, tick this too:

- [ ] AI assistance was used. I am responsible for provenance (CLR-R4) and nothing came from another input method's code.

## Sign-off and licence (QA-R61, ADR 0006)

- [ ] Every commit has `Signed-off-by:` with the commit author's name and e-mail (`git commit -s`), certifying the Developer Certificate of Origin 1.1 (https://developercertificate.org).
- [ ] I license this change under the licence of the files it touches (MPL-2.0 in the engine packages, `data/` and `spec/reference-model/`, GPL-3.0-or-later elsewhere) and also to the project under the MIT licence (CONTRIBUTING.md section 3). No CLA is needed.

## Tests

- [ ] For a bug fix: a failing test was written first and references the issue number (QA-R3). Or this PR explains why it cannot be tested and adds a compatibility script step instead.
- [ ] New or changed behaviour has tests (Swift Testing). Coverage did not drop by more than 1 point (QA-R2).
- [ ] A new per-app profile has an integration test in `TestHost/` (QA-R21).
- [ ] Corpus expected values changed? This PR has the `corpus-change` label and the reason is below (QA-R6).
- [ ] Performance baseline changed? This PR has the `perf-baseline` label and the reason is below (QA-R15).
- [ ] `scripts/lint.sh` passes; code builds; relevant test commands from CONTRIBUTING.md section 4 pass locally.

Reason for `corpus-change` or `perf-baseline` (if applicable):

## Rules (QA-R63)

- [ ] Commits use English Conventional Commits (`type: description`).
- [ ] No new dependency (or a decision record in `docs/decisions/` and an entry in `THIRD_PARTY_NOTICES.md` are included).
- [ ] No new setting (or a written justification against PRD principle 5 is included below).
- [ ] No hard-coded product name, slug, bundle ID or site host in code; documentation follows CONTRIBUTING.md section 6 (brand placeholders in `docs/`, literal values in the front-door files).
- [ ] Every new source file has an SPDX header (`MPL-2.0` in the engine packages, `data/` and `spec/reference-model/`, `GPL-3.0-or-later` elsewhere) (CLR-R11).

## Documentation and changelog (QA-R67)

- [ ] User-visible behaviour changed: the relevant user document is updated in this PR.
- [ ] `CHANGELOG.md` has an entry under `Unreleased`, in user-visible language, naming the apps involved.
- [ ] Process changed: the matching file in `docs/runbooks/` or `docs/support/` is updated.
- [ ] Not applicable (internal change, no user-visible effect).

## Security review checklist (QA-R59)

Complete this section when the PR touches event handling, diagnostics, import parsers, updater configuration or release scripts. Otherwise write "Not applicable" and leave the boxes unticked.

- [ ] No typed content is logged, printed or persisted (PLT-R901, ENG-R1220); the typed logging API is used.
- [ ] No new network endpoint (a new one needs a decision record and an update to the privacy page in this PR, QA-R60).
- [ ] All external input is validated (imported files, URLs, pasteboard); size limits and schema checks are in place (PLT-R912).
- [ ] No new entitlements; hardened runtime unchanged (PLT-R908).
- [ ] No new IPC surface (sockets, XPC, distributed notifications, AppleScript); the URL scheme still only opens Settings (PLT-R909).
- [ ] The Sparkle EdDSA key and other secrets are not referenced from CI or scripts that run in CI.
- [ ] Tap callback stays free of I/O, Accessibility calls, blocking locks and sleeps (PLT-R304, PLT-R305).

Security notes for the reviewer:

## Notes for the reviewer

<!-- Anything that needs attention, screenshots of UI changes, apps you tested in. -->
