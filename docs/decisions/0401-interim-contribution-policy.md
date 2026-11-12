# 0401. Interim contribution policy until the app licence is decided

- Status: accepted (interim), 2026-11-13
- Spec: QA-R61, QA-R62, QA-R63, CLR-R14; spec/00-overview.md section 5 item 2 (app licence is open)

## Context

QA-R61 says sign-off depends on the app licence. If the app is permissive or GPL-3.0 with no relicensing plans, DCO is enough. If Pa wants to keep the option of relicensing or of a separately licensed edition, a CLA is needed instead, and `CONTRIBUTING.md` must say so before the first external PR is accepted. The decision is made before the repository becomes public, but external contributors could show up earlier than that decision.

## Decision

1. **Engine package** (`Packages/VietnameseEngine`, MPL-2.0): external pull requests are accepted with a Developer Certificate of Origin sign-off on every commit (`git commit -s`), enforced by a DCO check. The sign-off also covers the clean-room confirmation (CLR-R14).
2. **Everything else** (app, AppCore, TestHost, scripts, site, docs): external pull requests are **not accepted** until Pa decides the app licence and the sign-off method (DCO or CLA) and `CONTRIBUTING.md` section 3 is updated. Issues, compatibility reports and discussion are welcome from the start.
3. The clean-room attestation in the pull request template (QA-R62) applies to all pull requests, including those from the maintainer.
4. AI-assisted contributions follow the same rules (QA-R64).

## Consequences

- No contributor can be locked into terms that the app licence decision might later change.
- A contributor who wants to help with the app before the decision can still do so through issues and compatibility reports.
- When Pa decides, add an ADR (0402 or later) superseding item 2, update `CONTRIBUTING.md` and the CI check (DCO app-wide, or a CLA bot).
