# 0312. User overrides in the diagnostics report are a typed projection

- Status: accepted, 2026-11-13
- Requirements: PLT-R541, PLT-R1202, PLT-R1203, PLT-R1204, PLT-R1205, PRD-R45, PLT-R901, QA-R59
- Context: PLT-R541 asks to include the reported app's user override "as rule JSON" in diagnostics reports so
  maintainers can promote it. The first contract carried it as raw `JSONValue` (and the effective parameters as
  `JSONValue` too). A raw rule can contain `match.web.urlPrefixes` (page addresses, from the guided test when
  the user ticks "include page address", or from an imported rule file), `match.titlePattern` and free text
  (`summary`). PLT-R1203 says the report MUST NOT contain URLs or window titles, so "the report type is
  structurally content-free" was no longer true. (Independent design review, finding 3.)

## Decision

- `DiagnosticsReport.RuleSection` holds `parameters: ReportedParameters` (typed integers, booleans, enums) and
  `userOverride: ReportedOverride?`. `ReportedOverride` copies id, strategy, parameters, fallback,
  `requireTextFocus`, `verifyReentry`, `engineContext` and the metadata match fields (bundle IDs, bundle group,
  engines, app categories, version ranges, AX roles, subroles, identifiers, DOM classes, ancestor roles,
  editable). It never copies `summary`, `provenance`, `match.web.urlPrefixes` or `match.titlePattern`; when the
  override has one of the last two, their field names (never values) appear in `omittedMatchFields`.
- `ResolvedDecision` no longer carries raw rule JSON; it carries `userOverride: Rule?`, and ShellCore's
  `ReportAssembler.reportedOverride(from:)` builds the projection. The report renders it as rule JSON in the
  preview (PLT-R1204), so a maintainer can paste it into `compat/rules.json` after adding provenance and, if
  needed, the URL scope from the reporter's own words.
- The guided test's rule suggestion (PLT-R1205 step 4) is a separate artefact: shown, copied or applied as an
  override on its own, with a host-level URL prefix only when the user ticked it. It is not embedded in the
  report or the issue block.

## Alternatives considered

- Keep only the host of a URL prefix when the user ticked "include page address" (review suggestion): rejected
  because a host is still part of a URL and PLT-R1203 is a MUST NOT without exceptions; a maintainer who needs
  the scope asks the reporter, who can paste the suggestion they saw.

## Verification

- Canary test (W1-G, W2-C): an override with a long canary URL prefix, a canary title pattern and a canary
  summary produces a report, JSON, plain text and issue block that contain none of the canaries, and an
  `omittedMatchFields` of `["web.urlPrefixes", "titlePattern"]`.
- Security review item (QA-R59) for any new field in `DiagnosticsReport`.
