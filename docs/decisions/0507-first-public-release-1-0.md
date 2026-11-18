# 0507. First public release: 1.0.0 without a public beta

- Status: accepted, 2026-11-17 (Pa, the product owner)
- Requirements: PRD-R4 (this record is the stage transition), QA-R29 (waived for 1.0.0 only), PRD-R0, PRD-R2,
  PRD-R8, PRD-R51, QA-R12, QA-R19, QA-R26, QA-R30, QA-R33, QA-R35, QA-R36, QA-R39, QA-R40, PLT-R1110, CLR-R13
- Runbook: [release](../runbooks/release.md), section 1 item 3 (`--skip-beta-soak`) and section 9 item 5

## Context

`spec/03-product.md` section 3.3 plans the way to 1.0 in stages: private alpha (0.1.x), closed beta (0.5.x), public
beta (0.9.x), then 1.0. PRD-R4 asks for a decision record with the exit-criteria evidence at each stage transition.
QA-R29 asks that a stable release has been on the beta channel for at least 72 hours, and `scripts/publish-release`
refuses a stable `X.Y.Z` unless `site/data/releases.json` lists an `X.Y.Z-beta.N` at least that old.

The state on 2026-11-17:

- Two private betas, `0.0.1-beta.1` (build 101) and `0.0.1-beta.2` (build 102), were built, signed, notarised and
  tested by Pa on 2026-11-14 ([0005](0005-pa-decisions-2026-11-13.md), "Manual test feedback, 14/11/2026", which
  records the findings and their fixes). They were handed over directly: neither is in an appcast, and
  `site/data/releases.json` does not exist yet.
- Pa used the Debug development builds, which carry the dev recorder ([0007](0007-dev-recorder.md)), every day from
  2026-11-14 to 2026-11-17. The last one, 20261116b, was built from commit `231ac7e9`.
- No app source has changed since `231ac7e9`. The later commits on `main` change the website, the documentation and
  the engine package's `site-demo-frames` executable, which the app does not link.
- Nothing is published on a public channel: no appcast item, no Homebrew cask, no GitHub Release.
- The macOS workflows (`CI`, `Integration`, `Nightly`, `Release`) are disabled by hand until macOS runners exist,
  as the state table of the [site deploy runbook](../runbooks/site-deploy.md) records (row "Actions"); the runner
  itself is still the open question of [0005](0005-pa-decisions-2026-11-13.md) S6 and Q12. None of the release
  gates that run in GitHub Actions can run.

## Decision

1. **Pa's decision of 2026-11-17, verbatim:** "Bản v1.0.0 production trên web. App đã tạm ổn, không còn beta nữa."
   (English: "Version 1.0.0 goes to production on the website. The app is in good enough shape now; no more
   betas.") The first public release is **1.0.0**, build **1000099** (`scripts/build-number.sh 1.0.0`), on the stable
   channel, dated 2026-11-18 (built the day after the decision, once the escape fix of rule L4 was merged),
   published on the website (download page and appcast) and in Pa's Homebrew tap, the repository
   `kalhoang/homebrew-tap` (`brew install --cask kalhoang/tap/{{app-slug}}`). Signing, notarisation,
   the EdDSA signature, the GitHub Release, the tap and the site deployment run on Pa's Mac as the release runbook
   describes (sections 4 and 7).

2. **Stage transition: from private testing straight to 1.0.** The project goes from pre-alpha with private betas
   (`0.0.1-beta.N`) to 1.0. The private alpha, closed beta and public beta of section 3.3 are not held as stages of
   their own: the private betas and Pa's daily use of the development builds stand in for the private alpha, and
   there is no closed or public beta. The entry and exit criteria of every skipped stage, and the entry criterion of
   1.0, are listed under "Stage criteria evidence" with their evidence. A criterion that is not met is accepted by Pa's decision (marked "waived"); the
   list makes that acceptance explicit instead of implied.

3. **QA-R29 is waived for 1.0.0 only.** Publication uses
   `scripts/publish-release 1.0.0 --skip-beta-soak docs/decisions/0507-first-public-release-1-0.md`. The option skips
   only the 72-hour check; the release-notes check (PRD-R51), the signature and key checks and the rest of the run are
   unchanged, and phased rollout stays on (QA-R35; it changes nothing for 1.0.0, which no installed public copy
   updates to, and keeps later releases configured the same way). The script accepts a record only if one prose
   paragraph of it (code excluded) cites QA-R29 and names the version, so this record cannot waive the rule for any later version. Every later stable
   release ships first as `X.Y.Z-beta.N` on the beta channel for at least 72 hours; another waiver needs a new
   decision by Pa.

4. **Release gates without the macOS workflows.** The gates of the release runbook section 2 that run in GitHub
   Actions are replaced, for 1.0.0, by the local equivalents in the table "Release gates" below. Where no local
   equivalent exists or it was not run, the gate is waived by Pa's decision and named as such.

5. **Provenance review (CLR-R13).** 1.0.0 is both the first public release and 1.0, so CLR-R13 asks for a full
   similarity review before it. The review is done by the dirty side and recorded as a separate report in
   [`docs/provenance/`](../provenance/), following its README; this record does not restate it. It is not waived:
   1.0.0 is not published while that report is missing or has an unresolved match (release runbook section 2).

6. **Homebrew minimum macOS.** The cask template still declared `depends_on macos: ">= :sequoia"`, left from the
   macOS 15 floor that [0315](0315-minimum-macos-12.md) replaced. It now declares `">= :monterey"`, the same floor as
   the deployment target (PRD-R8, PLT-R106); PLT-R1110 and the release runbook section 7 follow.

## Stage criteria evidence

"Local gate" is the integrator's verification of the `main` checkout (`tools/verify-all.sh` in the folder that holds
the worktrees, outside the repository), run on 2026-11-17 at 19:19 to 19:27 (UTC+7) on `main` at `4ebe3bd9`: AppCore
`swift test`, `xcodegen generate`, Debug builds of `App`, `TestHost` and `SpikeIMK`, the `UpdaterTests`,
`scripts/lint.sh`, the contracts check, the engine `swift test`, the `site-demo-frames` check,
`scripts/tests/run.sh`, `node site/test.mjs`, `node deploy/site/test.mjs` and `scripts/check-spdx.sh`, all
passing. The engine's ENG-R873 prose check for Telex records one known difference as a known issue ("IX types ĩ",
[0202](0202-data-integration-measurements.md)).

| Stage | Criterion | Status | Evidence |
|---|---|---|---|
| Private alpha, entry | Engine corpus green | met | Local gate: engine `swift test` passes on `4ebe3bd9`, with the ENG-R873 known issue above |
| Private alpha, entry | Fuzz clean | waived | No fuzz run is recorded: `scripts/fuzz.sh` needs Linux (libFuzzer), and the Linux jobs of `ci.yml` and `nightly.yml` are disabled with the rest of those workflows |
| Private alpha, entry | Onboarding usable | met | Pa went through onboarding with the private betas and the development builds on 2026-11-14; the findings of that day were fixed (0005, "Manual test feedback, 14/11/2026") |
| Private alpha, exit | 2 weeks of daily use by Pa with zero lost-text incidents | waived | Four days of daily use (2026-11-14 to 2026-11-17), not two weeks. The problems Pa reported in that time were fixed before 1.0.0; their entries are in the history of `CHANGELOG.md` before this release |
| Private alpha, exit | All Tier 1 apps pass the compatibility script | waived | `compat/matrix.json`: all 32 Tier 1 entries (and all 95 entries) are `notVerified` |
| Private alpha, exit | No crash reports | met, as far as reported | No crash appears in Pa's reports of 2026-11-14 to 2026-11-17. There is no crash-reporting service by design (principle 4), so Pa's reports are the only source |
| Closed beta, entry | Bug report flow works end to end; Apps page shows real profiles | partly met | Report a Problem builds the diagnostics block and opens the GitHub issue form (AppCore `DiagnosticsTests` and `ShellCoreTests/BugReport` pass in the local gate), but no report from outside the project has gone through it yet. The Apps pane reads the shipped `compat/rules.json` (23 rules, `scripts/check-rules.py --release`: 0 errors) |
| Closed beta, exit | Reopen rate under 15% | waived | No closed beta was held, so there is no reopen data; the public issue tracker has no issue (`gh issue list`, 2026-11-17) |
| Closed beta, exit | No P0 open | met | The P0 tests (PRD-R0) are part of the engine and AppCore suites of the local gate, which pass; no issue is open |
| Closed beta, exit | Median time to fix P1 under 7 days | waived | No beta testers, so no measurement; Pa's own reports of 2026-11-14 were fixed within days |
| Closed beta, exit | Migration import tested from XKey and OpenKey exports | waived | The importers have unit tests, but no test with real export files of those two apps is recorded (their formats are VERIFY items of `spec/03-product.md` section 15) |
| Public beta, entry | Notarized, signed updates proven across 3 consecutive releases without settings loss | waived | Two notarised private betas, handed over directly; no update through Sparkle between three releases is recorded |
| Public beta, exit | 4 weeks without a P0 | waived | The first private beta is three days old |
| Public beta, exit | Compatibility matrix covers Tier 1 and Tier 2 with verified dates | waived | All entries are `notVerified` (`scripts/compat-stale-report.py --release` lists all 95 as never verified) |
| Public beta, exit | Provenance review done (CLR-R13) | not waived | Separate report in [`docs/provenance/`](../provenance/) (decision 5) |
| 1.0, entry | All PRD-R and QA-R MUST items met | waived where open | Not audited item by item for this record. Known open MUST items: QA-R12 (integration suite green on the newest macOS, see below), QA-R19 (Tier 1 rows verified within 90 days), QA-R29 (decision 3), QA-R30 step 1 (the `ci.yml` and `integration.yml` gate), QA-R39 (rollback rehearsed on the beta channel). The upgrade test of QA-R40 has no previous stable to start from |

## Release gates

The gates of the release runbook section 2 for 1.0.0, with the local equivalent used while the macOS workflows are
disabled.

| Gate (release runbook section 2) | Local equivalent | Status |
|---|---|---|
| `ci.yml` green on the commit | Local gate on `main` at `4ebe3bd9` (lint, Debug builds, engine and AppCore tests, UpdaterTests, script tests). Coverage report, property tests, the 60 s fuzz and the benchmark compare did not run | partly met; the rest waived |
| `integration.yml` green on the newest macOS (QA-R12, QA-R23) | The suite in the tart VM on macOS 27.2 ([integration suite runbook](../runbooks/integration-suite.md) section 10). Best recorded result: 35 of 40 scenarios on 2026-11-13 (section 10.4). The fixes and scenarios of sections 10.5 to 10.8 have no VM run yet ("none yet" rows) | waived |
| `nightly.yml` green within 24 hours | Dependency audit run locally on 2026-11-17: `scripts/dependency-audit.py` passes (Sparkle 2.10.1 ok). The sanitizer fuzz needs Linux and did not run | partly met; fuzz waived |
| P0 tests pass (PRD-R0) | Local gate: engine and AppCore suites pass | met |
| Tier 1 compatibility script done, rows at most 90 days old (QA-R19) | None: `compat/matrix.json` has no verified row | waived |
| Upgrade test (section 5) | Not applicable to the first public release (there is no previous stable). If Pa's installed private beta reads the production appcast, its update to 1.0.0 through Sparkle is the first real update to watch (runbook section 8) | not applicable |
| Network egress test (spec/02-platform.md section 13.7) | Not run ([integration suite runbook](../runbooks/integration-suite.md) section 5) | waived |
| No compatibility rule past `reviewBy` by more than 30 days | `scripts/check-rules.py --release` on 2026-11-17: 23 rules, 0 errors, 0 warnings; every `reviewBy` is in 2027 | met |
| Provenance review (CLR-R13) | Separate report in [`docs/provenance/`](../provenance/) | not waived (decision 5) |
| `THIRD_PARTY_NOTICES.md` complete (CLR-R6, CLR-R7) | The notices tests of `scripts/tests/run.sh` pass (Sparkle pin, bundled data, app artwork). Three lines are still marked placeholder: the DMG background (none exists yet), the website's fonts and the illustrations or screen recordings of the website and onboarding | partly met; the placeholder lines are open (site track and Pa) |
| Changelog and release notes in Vietnamese and English (PRD-R51) | `CHANGELOG.md` and `CHANGELOG.vi.md`, section `[1.0.0] - 2026-11-17`, five visible lines each; `scripts/publish-release` checks them before signing | met |
| No open P0 issue, no unresolved `update-regression` issue | `gh issue list` on 2026-11-17: no open issue | met |

The release-workflow gates of [0503](0503-release-pipeline.md) decision 5 that are not in the table also have local
equivalents: `scripts/check-unimplemented.sh` reports no `unimplemented()` call left in product code (2026-11-17),
and the Tier 1 freshness gate for stable releases fails (`scripts/compat-stale-report.py --release` exits 1), which
is the QA-R19 waiver above.

## Consequences

- 1.0.0 is the first public build, so its EdDSA public key and feed URL are fixed from now on (QA-R33).
- The roadmap of section 3.3 is not rewritten: the stage table stays as the plan for the next releases, and the next
  stable release follows the beta rule of QA-R29.
- The waived criteria are open work, not closed: the Tier 1 compatibility script, the integration suite on the
  newest macOS, a Linux fuzz run, the egress test and a rollback rehearsal on the beta channel are the first things
  to do after 1.0.0, in that order of risk.
- GitHub private vulnerability reporting, the preferred channel of `SECURITY.md`, was still disabled on 2026-11-17
  (`gh api repos/kalhoang/{{AppName}}/private-vulnerability-reporting`); the release runbook section 0 lists enabling it.
- Without a public beta, a regression reaches every user who installs 1.0.0. The appcast pull (within 1 hour of a
  confirmed P0, [appcast pull](../runbooks/appcast-pull.md)) and the [rollback](../runbooks/rollback.md) runbook are
  the mitigation.

## Amendment, 2026-11-18: what shipped, and what the record said was missing

Recorded the day after 1.0.0 was published, so that the record matches the facts
([0009](0009-pa-decisions-2026-11-18.md)).

- **What was built.** The tag `v1.0.0` points at `9d63a360` (2026-11-18, "chore(release): date 1.0.0 on 2026-11-18"),
  not at `4ebe3bd9`, the commit of the local gate and of the provenance record review. Between the two, the engine
  changed under `Packages/VietnameseEngine/Sources/VietnameseEngine/Commit/` (the escape rule of L4,
  `EscapeRule.swift`, decided by the product owner on 17/11/2026) and `Composition/Composition.swift`, plus
  `data/NOTICES.md`. The GitHub Release `v1.0.0` was published on 2026-11-17 at 22:13 UTC (2026-11-18 in UTC+7),
  and `site/data/releases.json` dates 1.0.0 on 2026-11-18.
- **CLR-R13 (decision 5).** Decision 5 said 1.0.0 would not be published while the similarity report was missing.
  1.0.0 was published on the record review alone
  ([`2026-11-17-1.0.0.md`](../provenance/reports/2026-11-17-1.0.0.md)), whose note N1 says the comparison against
  other codebases had not been done. On 2026-11-18 the product owner commissioned that comparison: a reviewer the
  product owner appoints performs it under the new
  [similarity review runbook](../runbooks/similarity-review.md), first on `9d63a360` (the shipped 1.0.0), then on
  each release delta. Until its report exists, 1.0.0 stands on the record review, and the 1.0.1 delta report
  covers `4ebe3bd9..9d63a360` as well as the changes after it.
- **Repository settings.** The consequence "private vulnerability reporting was still disabled" no longer holds:
  private vulnerability reporting is enabled and GitHub Discussions is on (both checked with `gh api` on
  2026-11-18; release runbook section 0).
- **`--skip-attestation`.** A release signed on Pa's Mac carries no GitHub artifact attestation, because the
  attestation of QA-R30 step 7 is produced only by steps that run in GitHub Actions and QA-R31 keeps signing on
  Pa's Mac ([0005](0005-pa-decisions-2026-11-13.md) Q9, which closed open decision 14 of
  [0001](0001-defaults-for-open-decisions.md)). Publishing such a release with `--skip-attestation` is therefore
  the designed path, not a waiver like `--skip-beta-soak`; the release runbook section 4 says the same.
- **Third-party notices.** The three placeholder lines of the release-gate row "`THIRD_PARTY_NOTICES.md` complete"
  were resolved before the tag: `THIRD_PARTY_NOTICES.md` section 4 "Other assets" now states that there is no DMG
  background, no bundled font and no illustration or screen recording (note N2 of the provenance report).
- **QA-R29 for the next release.** 1.0.1 ships first as a beta and then as stable after 72 hours counted from the
  beta's publication, with no minimum number of beta users ([0009](0009-pa-decisions-2026-11-18.md) item 1); this
  record's waiver still covers 1.0.0 only.
