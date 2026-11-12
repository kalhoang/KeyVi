# 0400. Documentation decisions and placeholders to fill

- Status: accepted (working decisions until Pa decides otherwise), 2026-11-13
- Scope: project documentation and GitHub metadata (spec/04-quality-release.md sections 4 to 8, QA-R43 to QA-R67; spec/05-clean-room.md)
- Owner of this range: ADRs 0400 to 0499 belong to the documentation track.

## Context

The documentation set of QA-R66 had to be written while the product name, the app licence, the GitHub repository path, the mail addresses and the donation accounts are all undecided. The documents must be usable now and must not contain invented facts or real account data.

## Decisions

1. **Brand placeholders stay in prose.** Documents use the spec's two placeholders, `{{AppName}}` (display name) and `{{app-slug}}` (ASCII slug), and write the site host as `{{app-slug}}.kal.vn`. The literal temporary name is never written in docs. Authoritative values live in `Config/Brand.xcconfig` and `scripts/brand.env`. Reasoning: `scripts/rename-app.sh` keeps those two files in sync and does not have to touch prose, and the docs stay correct after any rename.

   When Pa decides to publish with a baked name (for example for the public README), bake the placeholders once, on a release branch, from the brand file:

   ```sh
   set -a; . scripts/brand.env; set +a
   git ls-files README.md README.vi.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md \
     THIRD_PARTY_NOTICES.md 'docs/runbooks/*' 'docs/support/*' 'docs/provenance/*' compat/SCRIPT.md \
     | xargs sed -i '' -e "s/{{AppName}}/$APP_DISPLAY_NAME/g" -e "s/{{app-slug}}/$APP_SLUG/g"
   ```

   This is the "one pass" replacement that spec/00-overview.md section 4 describes. It is one-way: keep the placeholder version on `main` if renames may happen again.
2. **Unknown repository path.** Files that need an absolute GitHub URL (issue form config, SECURITY.md) use `OWNER/REPO` and carry `VERIFY`. GitHub does not accept relative links in `config.yml`.
3. **Plain, neutral Vietnamese** (PRD-R62) addressed to "bạn" in README.vi.md and in support replies. Copy drafts of spec/03-product.md are reused verbatim (the privacy footnote, the donation line, the error copy). Documents for the maintainer (runbooks, ADRs) are English, the repository's working language.
4. **No claim beyond the spec.** The README states pre-alpha status and lists only features in PRD-R2. Install options are marked as not available yet.
5. **Interim contribution policy**: see [0401](0401-interim-contribution-policy.md).
6. **Support replies** cover the six topics of QA-R53 plus the lifecycle messages of QA-R46 and QA-R47. The first reply to any bug asks for the in-app report and the practice-field check, never logs or terminal commands (QA-R49).
7. **Labels** are the QA-R45 set plus `corpus-change` and `perf-baseline` (QA-R6, QA-R15), `security-review` (QA-R59), `dependencies` (QA-R24 Dependabot), and the automatic diagnostics labels of QA-R44 (`arch:*`, `method:*`, `macos:15|26|27`). The dynamic `app:<bundle>` labels are created by the diagnostics action and are not listed. New macOS majors need a new `macos:<n>` entry.
8. **Issue forms**: the symptom "chips" of QA-R43 are a multi-select dropdown (GitHub forms have no chip control). The diagnostics block is a plain textarea (no `render:` option) so that the pasted block keeps its own fence and header line for the parsing action.
9. **Compatibility script test text** was written for this project and checked keystroke by keystroke with the reference model in `spec/reference-model/` (Telex and VNI, traditional tone placement). It covers all six tones, `ươ`, `uy`, `oa`, `đ`, capital letters and punctuation boundaries.
10. **Provenance review rules** extend CLR-R13 slightly: the reviewer may not be any AI session that worked on this repository, and a report must exist for every public release (a delta review or a no-change statement is enough after the first public release and 1.0), following the acceptance wording of spec/05-clean-room.md section 5.
11. **Appcast pull uses a rebase merge**, never a squash, even under time pressure, so CLR-R12 holds.
12. **Runbook commands that depend on Sparkle's or Apple's tools** are written from public documentation and marked `VERIFY` where behaviour (rather than a plain flag) matters: key rotation, TCC handling on the runner, notarytool role, macOS 27 pane names.
13. **Sparkle's licence** text in `THIRD_PARTY_NOTICES.md` was fetched from the `2.x` branch `LICENSE` file of the Sparkle repository and is reproduced in full, including the external licences (bsdiff, sais-lite, ed25519, SUSignatureVerifier). Re-fetch it when the pinned version changes.
14. **Contributor Covenant 2.1** is used unchanged apart from the contact address, with its attribution kept (CC BY-SA 4.0).

## Placeholders (VERIFY) that Pa must fill

Search the repository with `grep -rn VERIFY` to find them all. Each row names the file and what is needed.

| # | Placeholder | Where | What Pa provides |
|---|---|---|---|
| 1 | GitHub repository path `OWNER/REPO` | `SECURITY.md`, `.github/ISSUE_TEMPLATE/config.yml` | The real `owner/repo`; enable Discussions and private vulnerability reporting |
| 2 | Security email `security@kal.vn` | `SECURITY.md` | Create or confirm the mailbox (QA-R56) |
| 3 | Conduct contact `conduct@kal.vn` | `CODE_OF_CONDUCT.md` | Create or confirm the mailbox (QA-R65) |
| 4 | Support email (address on the website) | Referenced by `docs/support/replies.md`, `README` links to the website | Create or confirm the mailbox (QA-R51); the site and app tracks use it too |
| 5 | GitHub Sponsors handle | `.github/FUNDING.yml` (commented until set) | Handle after Sponsors approval ([donation-setup](../runbooks/donation-setup.md)) |
| 6 | Maintainer handle | `.github/CODEOWNERS` (`@OWNER-HANDLE`) | The GitHub login that owns reviews |
| 7 | Homebrew tap owner | `README.md`, `README.vi.md`, `docs/runbooks/release.md` (`OWNER/tap`) | `kal-vn` or `kalera-labs` (spec/04 open question 5) |
| 8 | Donation account details | `docs/runbooks/donation-setup.md` (no data in the repo) | VietQR and MoMo QR images and account name text; whether bank name and number are shown; open decision 19 |
| 9 | Public sponsor list | `docs/runbooks/donation-setup.md` | Yes or no (PRD-R61) |
| 10 | Which Mac is the integration runner, and always-on or overnight | `docs/runbooks/self-hosted-runner.md` | Open decision 16 |
| 11 | CI signing vs local signing | `docs/runbooks/release.md`, `certificate-renewal.md`, `notarization-setup.md` | Open decision 14 |
| 12 | Script environment variable names (notary profile, publish inputs) | `docs/runbooks/release.md`, `notarization-setup.md` | Confirm after the CI track writes `scripts/*`; update the runbooks |
| 13 | Website banner mechanism, deploy command and CDN purge | `docs/runbooks/rollback.md`, `appcast-pull.md` | Confirm with the site track; write the exact commands |
| 14 | Sparkle behaviours: key rotation, key-change acceptance, `generate_keys` and `sign_update` options | `docs/runbooks/key-rotation.md` | Test with the pinned Sparkle version; record confirmed commands |
| 15 | iTerm2 automatic secure keyboard entry setting name and location | `docs/support/replies.md` (PLT-R398C) | Check the current iTerm2 release |
| 16 | Vietnamese names of System Settings panes per macOS version | `README.vi.md`, `docs/support/replies.md` | Check on a Vietnamese-language system for macOS 15, 26 and 27 (PRD-R64) |
| 17 | In-app labels used in replies (`Ổn định`, `Beta`, the practice-field button, `Đặt lại quyền`, `Kênh cập nhật`) | `docs/support/replies.md` | Compare with the String Catalog; some come from the spec, some are proposals |
| 18 | Known-limitation texts | `docs/support/replies.md`, `compat/SCRIPT.md` | Verify each limitation before publishing (PRD-R35) |
| 19 | Fuzz package licence | `CONTRIBUTING.md` | Confirm `Packages/VietnameseEngineFuzz/LICENSE` |
| 20 | Developer ID certificate expiry date | `docs/runbooks/certificate-renewal.md` | Read from the Apple Developer portal; add a calendar reminder |
| 21 | App Store Connect API key role | `docs/runbooks/notarization-setup.md` | Confirm the minimum role Apple currently requires for notarytool |
| 22 | GitHub-hosted macOS runners and TCC | `docs/runbooks/self-hosted-runner.md` section 7 | Test whether a hosted image can grant Accessibility (QA-R12) |
| 23 | Sparkle pinned version | `THIRD_PARTY_NOTICES.md` | Fill after `Package.resolved` exists |
| 24 | Data, asset and site entries | `THIRD_PARTY_NOTICES.md` sections 3 to 5 | Data, app and site tracks fill their parts (`data/NOTICES.md` is the data source) |
| 25 | `compat/matrix.json` field names | `compat/SCRIPT.md` section 5 | The schema in `compat/schema/` wins; adjust the example if names differ |
| 26 | App licence, DCO or CLA | `CONTRIBUTING.md` section 3 | Open decision 2; see 0401 |
| 27 | Rollback rehearsal log | `docs/runbooks/rollback.md` section 5 | Fill the table after the drill on the beta channel (QA-R39) |

## Consequences

- Renaming the product requires no documentation change until a baked README is wanted (decision 1).
- Every open item above blocks making the repository public, except items 10 and 11, which block only the first release.
- Each change of a decision here gets its own ADR that supersedes the relevant line.
