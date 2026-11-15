# 0505. Repository lints and their exemptions

- Status: accepted, 2026-11-13
- Requirements: PLT-R501, PLT-R902, PLT-R407, PLT-R503 to PLT-R531, QA-R60, CLR-R11, QA-R24

`scripts/lint.sh` runs every check and reports all failures together. Each check is also a standalone
script with `--help`.

| Check | Script | Fails on | Exemptions |
|---|---|---|---|
| Formatting | `swift format lint --strict` with `.swift-format` | style violations (4-space indent, 120 columns) | none |
| Bundle-ID literals (PLT-R501) | `lint-bundle-ids.sh` | a Swift string literal shaped like `com.example.App` (known TLD prefix, reverse-DNS) | test paths (`Tests/`, `*Tests/`, `Fixtures/`, `Packages/AppCore/Sources/TestSupport/`); identifiers that are not bundle IDs listed in `scripts/lint-bundle-ids.allow` (keyboard layout IDs, input source IDs, pasteboard marker types, the AX notification name, the ADR 0501 diagnostics keys `app.version`, `app.build`, `app.channel`); a line with `lint:allow-bundle-id <reason>` |
| Log interpolation (PLT-R902) | `lint-log-interpolation.sh` | `\(` inside a string passed to `os_log`, `os_signpost`, `NSLog`, `<x>log<y>.<level>(...)`, and `print`/`debugPrint`/`dump` in product code | test paths; `print` in CLI executables (`lexicon-builder`, benchmark, fuzz drivers, `CompatHarness`); inside `Packages/AppCore/Sources/Diagnostics/` only, a line with `lint:allow-log-interpolation <reason>` (the typed logger's own bridge) |
| Forward delete (PLT-R407) | `check-no-forward-delete.py` | any rule value or key naming forward delete, keycode 117 in a key-code parameter, a delete direction other than backspace | provenance and summary text may describe the symptom; `action.params.inlineCompletion: "forwardDelete"` in a rule scoped to apps or fields (PLT-R423, PLT-R424, amended 15/11/2026) |
| Rules (PLT-R503 to PLT-R531) | `check-rules.py` | schema errors (first `compat/schema/*rules*.json`), missing provenance or scenario, duplicate ids, identical match signatures, invalid `titlePattern`, placeholder or `forwardDelete` in defaults, global or title-only rules (PLT-R422, PLT-R424), paste without opt-in, manual scenario without a matrix row, `reviewBy` more than 12 months ahead; `--release`: `reviewBy` more than 30 days overdue | missing rules file passes (nothing ships yet) unless `--require` |
| Matrix (QA-R17) | `check-matrix.py` | `compat/matrix.json` not valid against `compat/schema/matrix.schema.json` (the source of truth for the in-app Apps page, the website and `compat/SCRIPT.md` section 5), or two entries with the same `bundleId` | missing file passes unless `--require` |
| SPDX (CLR-R11) | `check-spdx.sh` | source file without `SPDX-License-Identifier` in its first 5 lines, or the wrong licence: `MPL-2.0` under `Packages/VietnameseEngine/`, `Packages/VietnameseEngineFuzz/`, `data/` and `spec/reference-model/`, `GPL-3.0-or-later` elsewhere (ADR 0006; the identifier was a pending placeholder until 4974ba2, and the engine parts were `MIT` until the amendment of 15/11/2026) | `spec/` except `spec/reference-model/`, generated output, JSON and Markdown |
| URL hosts (QA-R60) | `check-url-hosts.sh` | a `scheme://host` or `mailto:` host in the built app outside `scripts/url-hosts.allow` plus the hosts derived from `scripts/brand.env`: the site host, the host of `APP_REPOSITORY_URL` (`github.com` while empty) and the domain of `APP_SUPPORT_EMAIL` (when set) | XML namespace and DTD hosts listed in the allowlist (VERIFY against the first Release build) |
| Brand files (CLAUDE.md) | `check-brand-sync.py` | a key of `Config/Brand.xcconfig` missing from `scripts/brand.env` or the other way round, or a different value (`$()` in the xcconfig is ignored) | none |
| Markdown links (QA-R66) | `check-docs.py links` | a relative link in `docs/`, `README*.md` or `CONTRIBUTING.md` whose file or directory does not exist, or whose `#fragment` is not a heading (GitHub slug rules, duplicates numbered `-1`, `-2`) or an explicit `<a id>` of the target Markdown file | absolute URLs, `mailto:`, links containing `{{` (templates), fenced code and inline code |
| Brand literals in docs (ADR 0400 decision 1) | `check-docs.py brand` | the display name, the slug as a whole word, a bundle ID or the site host from `scripts/brand.env` in `docs/`, `README*.md` or `CONTRIBUTING.md`; the docs use `{{AppName}}` and `{{app-slug}}` | `docs/decisions/` (historical records, also skipped by `rename-app.sh`) |
| Shell scripts | `shellcheck -x` | warnings in `scripts/` | none |

Notes:

- The JSON Schema validator is a standard-library subset (`scripts/lib/jsonschema_lite.py`), because CI
  scripts run with `python3 -I` and no third-party packages. Schemas in `compat/schema/` should stay within
  the keywords it lists.
- The URL host check works on strings in the binary; Swift stores literals of 15 bytes or less inline in
  code, so a very short URL could escape it. Network code review (QA-R59) remains the primary control.
- Adding an allowlist entry needs a reason in the same commit; adding a URL host also needs a decision
  record and a `/rieng-tu` update (QA-R60).
