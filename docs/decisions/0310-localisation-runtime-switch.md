# 0310. Localisation with a runtime language switch

- Status: accepted, 2026-11-13
- Requirements: PRD-R62-R65, PLT-R704, PRD-R10, PRD-R40, PRD-R43
- Context: The UI ships in Vietnamese (default) and English, selectable in Settings independently of the
  macOS language, applied immediately without restart (PRD-R63). Several workstreams add strings in parallel.
  System pane names must follow the macOS language and version (PRD-R64), not the UI language. The product
  name is a format argument, never part of the copy.

## Decision

- String Catalogs, one per feature area (`Common`, `Menu`, `Status`, `Onboarding`, `Settings`, `Macros`,
  `Apps`, `Diagnostics`, `Support`, `Updates`) in `App/Resources/Localization/`, source language `vi`, semantic
  keys (`onboarding.welcome.title`). Each table has exactly one owning workstream.
- Lookup never uses the process's preferred languages. `Localizer` (ShellCore) opens the selected language's
  `.lproj` sub-bundle (`vi.lproj` / `en.lproj`, which Xcode compiles from the catalogs; verified in the
  skeleton build) and resolves keys there; formats go through `String(format:locale:arguments:)` so
  `.stringsdict` plural variations apply. Missing keys fall back to Vietnamese, then to the key, and a test
  fails on any missing key.
- `InterfaceLanguageModel` (`@MainActor @Observable`) holds the current `Localizer`; SwiftUI views render
  resolved `String`s (`Text(verbatim:)`) and re-render when it changes; AppKit menus are rebuilt on open; the
  status item's accessibility label and open windows refresh on change.
- Dates and numbers use `FormatStyle` with the selected `Locale` (PRD-R65).
- System pane names and deep links come from `SystemPanes.json` keyed by macOS version and system language
  (PLT-R704, PRD-R64). Deep links live in data so no reverse-DNS literal appears in code.
- Copy follows 03-product.md verbatim where a draft exists (PRD-R62); English is an equivalent translation.

## Consequences

- SwiftUI's implicit `LocalizedStringKey` lookup is not used for product copy (it follows the process
  language). A lint in the localisation workstream flags `Text("...")` literals in `App/Sources`.
