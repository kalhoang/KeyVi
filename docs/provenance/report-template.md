# Provenance review report: <release or milestone>

Copy this file to `docs/provenance/reports/YYYY-MM-DD-<release>.md` and fill it in. Do not quote code from the compared projects. Describe locations and the nature of each similarity only. Process: [README.md](README.md).

## 1. Scope

| Field | Value |
|---|---|
| Release or milestone | |
| Type | full (first public / 1.0) / delta since the previous report / no-change statement / targeted |
| This repository, commit SHA reviewed | |
| Date of review | |
| Previous report (if delta) | |

## 2. Reviewer (dirty side)

| Field | Value |
|---|---|
| Name | |
| Why the reviewer is allowed to read the compared codebases | |
| Confirmation: has not written or reviewed engine or input-host code for this project | yes / no |
| Confirmation: no AI session that worked on this repository took part | yes / no |

## 3. Compared codebases

| Project | Version (tag or commit) | How obtained | Licence noted |
|---|---|---|---|
| OpenKey | | | |
| XKey | | | |
| Other (CLR-R1, CLR-R2) | | | |

## 4. Methods and tools

| Method | Tool and version | Parameters or thresholds |
|---|---|---|
| Identifier overlap | | |
| Data-structure and table comparison | | |
| Comment search | | |
| Test data and word-list comparison | | |
| Behavioural fingerprints | | |

## 5. Findings

One row per finding. Classes: `none`, `inevitable`, `suspect`, `match`.

| # | Category (identifier / layout / table order / comment / data / behaviour) | Location in this repository | Location in compared project (path and line range, no code) | Nature of similarity | Class | Reason if inevitable |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

If there are no findings, write "No similarities beyond inevitable vocabulary" and list the inevitable items above.

## 6. Remediation

| Finding # | Rewritten by (clean implementer) | Commit SHA after rewrite | Re-check result |
|---|---|---|---|
| | | | |

Rewrites were made from `spec/` only, without access to the compared code.

## 7. Provenance record checks

- [ ] CLR-R11: every source file has an SPDX header.
- [ ] CLR-R12: history intact since the first commit (first commit SHA: ____). No squash, no rewrite.
- [ ] CLR-R14: external contributions in this range carry the DCO sign-off and the PR attestation.
- [ ] CLR-R6, CLR-R7: `THIRD_PARTY_NOTICES.md` complete; no GPL or LGPL data.
- [ ] CLR-R8: agents used a new, empty memory project.
- [ ] CLR-R10: the clean-room notice is present in `CLAUDE.md` and `AGENTS.md`.

## 8. Conclusion

- Unresolved matches: **none** / **<count>** (if any, the release is blocked).
- Reviewer: <name>, <date>
- Maintainer acknowledgement: <name>, <date>
