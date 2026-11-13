# Runbook: accessibility and localisation audit

Owner: the maintainer. Specification: PRD-R10, PRD-R12, PRD-R62 to PRD-R68, PLT-R211 (`spec/03-product.md`
sections 5 and 14, `spec/02-platform.md` section 2). Workstream: W2-F (`docs/architecture/workstreams.md`).

Purpose: one checklist per window and surface that says what the code and the tests already guarantee and what
Pa checks by hand with VoiceOver, Increase Contrast, Reduce Motion and full keyboard navigation before each alpha
build and before 1.0. It also holds the PRD-R68 observation protocol and the copy review record.

These checks are manual and run only by hand: they need the live app, VoiceOver and System Settings changes on Pa's Mac.

## 1. Automated part

Run in `Packages/AppCore`:

```sh
swift test --filter "CatalogAuditTests|SpecDraftCopyTests|LocaleFormattingTests|LocalizerTests"
swift test --filter "StatusAccessibilityTests|AccessibilitySourceAuditTests|ShellCatalogTests"
```

| Check | Test | Requirement |
|---|---|---|
| The catalog files are exactly the eleven `StringTable` cases | `CatalogAuditTests.catalogFilesAreExactlyTheStringTables` | PRD-R62, ADR 0310 |
| Every key has a translated vi and en value, same format arguments, no padding, no stray `%`, extraction state `manual` | `CatalogAuditTests.everyEntryIsCompleteTranslatedAndConsistent` | PRD-R62 |
| No brand literal (read from `Config/Brand.xcconfig`), no unfilled `{{...}}`, no em or en dash, no `...` as one character, no `sudo`, no `!` except the final onboarding screen, none of the listed slang or regional words in Vietnamese (whole words; words that are also standard, such as "vô" in "vô hiệu hóa", are left to the copy review) | `CatalogAuditTests.valuesFollowTheWritingRules` | CLAUDE.md, PRD-R40, PRD-R62, PLT-R741 |
| Every key the code refers to exists, no key is orphaned, no literal key lookups | `CatalogAuditTests` (remaining tests) | PRD-R62 |
| Every typed key is used by the app: written `EnumName.caseName`, or `.caseName` in a file that names the enum or a declaration typed with it (comments and string literals are ignored). Limit: a file that names the enum and also uses an unrelated `.caseName` (for example `role: .cancel` next to a `CommonText` lookup) still counts as a use | `CatalogAuditTests.everyTypedKeyIsUsedByTheApp` | PRD-R62 |
| No literal copy in any window: `Text("...")`, `Button("...")` and similar, `.help("...")`, alert titles, and a `Text(verbatim: "...")` literal with a word outside its interpolations | `CatalogAuditTests.uiSourcesHaveNoLiteralCopy` | PRD-R62 |
| Every secure-input hint in `compat/rules.json` has copy, and copy without a rule is listed | `CatalogAuditTests.secureInputHintsOfTheRulesHaveCopyAndCopyHasARule` | PLT-R397 |
| Every Vietnamese draft of `spec/03-product.md` is verbatim (and the English labels the spec gives) | `SpecDraftCopyTests` | PRD-R10, R11, R24, R25, R34 to R37, R40, R42, R43, R47, R59, section 4 |
| Counts are grouped per language, matrix days and app dates follow the interface language, versions keep their digits, every table switches language at run time | `LocaleFormattingTests`, `LocalizerTests` | PRD-R63, PRD-R65 |
| The status item's VoiceOver label exists in vi and en for every host state, mode, rule and capture combination; every pause reason is said in words | `StatusAccessibilityTests` | PRD-R10, PRD-R66, PLT-R211 |
| Every menu entry has a hint; the switch HUD announces "Tiếng Việt" / "Tiếng Anh"; it shows only for manual toggles | `StatusAccessibilityTests` | PRD-R12, PRD-R66 |
| Window titles are distinct in each language | `StatusAccessibilityTests.windowTitlesAreDistinctInEachLanguage` | PRD-R66 |
| Every SwiftUI control in every UI folder has a label and a hint; every AppKit alert button a hint | `AccessibilitySourceAuditTests` | PRD-R66 |
| Each animation call site checks Reduce Motion inside its own function or computed property (the deliberate exceptions are listed in the test with their requirement, see section 4); every window root and sheet disables implicit animations under Reduce Motion | `AccessibilitySourceAuditTests` | PRD-R12, PRD-R67 |
| No hard-coded hue; plain-style buttons draw their own focus ring; every titled window follows a language change | `AccessibilitySourceAuditTests` | PRD-R63, PRD-R67 |
| System pane names per macOS version and macOS language, English fallback, deep links | `SystemPaneTableTests` | PRD-R64, PLT-R704 |

The source checks are heuristics on purpose (they read the Swift files). A false alarm in code means the code should
be written the plain way the check expects, not that the check should be loosened. A false alarm in copy is
different: if a standard word trips the word list, the list is wrong and loses that word; the copy stays.

## 2. Before you start the manual checks

Use an alpha build installed from the DMG, Accessibility granted, interface language Vietnamese first, then
English. The settings below live in System Settings; turn each one back when done.

- VoiceOver: Command+F5. Keep the typing echo setting in VoiceOver Utility at its default for the first pass.
- Keyboard navigation: System Settings > Keyboard > Keyboard navigation (on). Without it macOS moves focus only
  between text fields and lists; buttons, checkboxes and pop-ups are reached only with it on.
- Increase Contrast and Reduce Transparency: System Settings > Accessibility > Display.
- Reduce Motion: System Settings > Accessibility > Display > Reduce motion.
- Light and dark appearance: System Settings > Appearance.

Record each result in the alpha checklist with the macOS version, the interface language and pass or fail.

## 3. Checklist per window and surface

Legend: **Code** is what the code and tests guarantee; **Pa** is what Pa verifies by hand.

### 3.1 Menu bar icon (PRD-R9, PRD-R10, PLT-R211)

- Code: one template glyph per state (`StatusGlyph`, placeholder artwork): V or E in a rounded square, a dot for
  an ignored app, a lock badge for Secure Input, a dimmed glyph when paused, a slash when not working, a record dot
  while a typing trace records. The VoiceOver label is the PRD-R10 label, or a reason-specific label where one
  glyph covers several states (starting, no text field, typing turned off, session inactive, guided test,
  fail-open other than a revoked permission). The hint is "Mở menu của <App>." The label follows a language change
  at once.
- Pa:
  1. With VoiceOver, move to the status item in each state you can produce (Vietnamese, English, an app set to
     "Bỏ qua ứng dụng này", Terminal with Secure Keyboard Entry on, a Japanese input source, Accessibility
     revoked). VoiceOver reads the matching PRD-R10 label.
  2. Change the state while the VoiceOver cursor rests on the icon (press Control+Shift). Note whether VoiceOver
     re-reads the new label by itself; if not, note it (the switch HUD announcement covers manual toggles).
  3. With Increase Contrast on, in light and dark menu bars, every glyph is distinguishable without colour; the
     dimmed glyph is still visible. Note it if the dimmed glyph is too faint (placeholder artwork).

### 3.2 Menu (PRD-R11, PRD-R13, PLT-R211)

- Code: items in PRD-R11 order with the drafted titles; every item has a VoiceOver hint; the status line item
  carries the sentence and the hint as its label and opens the fix; "Cài đặt..." has Command+, and Quit
  Command+Q; the menu is rebuilt on every open in the selected language.
- Pa:
  1. Open the menu with VoiceOver (VO+M twice reaches the menu extras, or click). Arrow through every item and
     submenu ("Với <App>"); each item reads its title, its checked state for radio items, and the hint.
  2. In a paused state (Secure Input held by Terminal), the status line reads the holder and the hint in plain
     words, and activating it performs the action.
  3. Change the interface language in Settings, reopen the menu: every item is in the new language.

### 3.3 Switch HUD (PRD-R12, PRD-R66)

- Code: a non-activating, click-through panel near the bottom centre shows V or E for 600 ms on a manual toggle
  only (D14), posts an accessibility announcement with high priority ("Tiếng Việt" / "Tiếng Anh", or
  "Vietnamese" / "English"), fades in only when Reduce Motion is off and fades off plainly (PRD-R12 allows a plain
  fade off). The panel has a solid outline under Increase Contrast.
- Pa:
  1. With VoiceOver on and TextEdit frontmost, press Control+Shift several times: VoiceOver says the mode each
     time, and the focus stays in TextEdit. If nothing is spoken while another app is frontmost, record it: the
     fallback is to post the announcement on the application element instead of the panel (owner W1-G/W2-F).
  2. Switch apps so the per-app memory changes the mode: no HUD and no announcement.
  3. Reduce Motion on: the HUD appears without a fade in. Increase Contrast on: the panel edge is clearly visible
     on a white and on a dark background.

### 3.4 Typing trace HUD and alerts (PLT-R905)

- Code: the countdown panel has a Stop button with label and hint; the confirmation alert's buttons and duration
  picker have hints; the failure alert's Close has a hint; the review window's controls are labelled.
- Pa: start a 60 s trace from Diagnostics with VoiceOver on. The alert reads the message, the picker and both
  buttons with hints. During recording, the status item label is "Đang ghi thao tác gõ"; the Stop button is
  reachable with the VoiceOver cursor and stops the recording.

### 3.5 Onboarding window (PRD-R40 to PRD-R42, PRD-R67)

- Code: eight screens with the drafted copy; screen titles are headers; every button, field, card and checkbox has
  a label and a hint; the primary button is the default button (Return); Back and Skip are reachable with
  keyboard navigation; the method cards show selection with a check symbol and a thicker border (not colour
  alone) and draw the system focus-ring colour when focused; the permission illustration loops only without
  Reduce Motion and stops at once when Reduce Motion is turned on; implicit animations stop under Reduce Motion;
  the window title is "Thiết lập <App>" and follows a language change; pane names in the instructions come from
  `SystemPanes.json` for the running macOS version and macOS language.
- Pa, on a fresh user account or after resetting onboarding:
  1. Keyboard only (keyboard navigation on): Tab through every screen; every control shows a visible focus ring,
     including the Telex and VNI cards; Space activates; Return triggers the primary button.
  2. VoiceOver: each screen title is announced as a heading; cards read "Kiểu gõ Telex, Đang chọn" (or the VNI
     equivalent) with the hint; the try-it checklist reads "Đã xong: ..." or "Chưa xong: ..." and updates as you
     type; the arrow on the last screen reads its description.
  3. Permission screen: with Reduce Motion on, the illustration is a still switch. Turn Reduce Motion on while the
     screen shows the loop: the loop stops.
  4. "Không thấy <App> trong danh sách?" sheet and its reset confirmation: every button reads its title and hint;
     Escape closes the sheet.
  5. On a Vietnamese-language macOS (15, 26 and 27 if available), the instruction names the panes exactly as
     System Settings shows them. Record the exact names; they are VERIFY entries of `App/Resources/SystemPanes.json`.
  6. Move-to-Applications alert (run the DMG copy): both buttons read their titles and hints.

### 3.6 Settings window: pane picker and five panes (PRD-R24 to PRD-R28, PRD-R67)

- Code: a segmented pane picker (label and hint); every toggle, picker, field, button and list has a label and a
  hint from the Settings, Apps, Macros or Support table; explanations under every setting; warnings and statuses
  carry a symbol; the Apps status column is a symbol plus text; the Apps table has a named actions column; the
  last-verified day in the app details follows the interface language; implicit animations and the Advanced
  disclosures stop animating under Reduce Motion; the title follows a language change.
- Pa:
  1. Keyboard only: Command+, opens the window; Tab reaches the pane picker, arrows change pane; in each pane, Tab
     reaches every control in reading order with a visible focus ring; the Apps and Macros tables take arrow keys,
     and the row buttons (Details, report, edit, duplicate, delete) are reachable after selecting a row.
  2. VoiceOver: each control reads label, value and hint; the Apps table reads the column headers including
     "Thao tác"; the status cell reads the status words; the macro row checkbox reads "Bật gõ tắt này: <shortcut>".
  3. Interface language: switch to English and back; every pane, the window title and open sheets switch at once,
     without reopening the window (PRD-R63).
  4. Increase Contrast, light and dark: notices, the selected segment, the hotkey recorder box while recording and
     all secondary text stay readable (WCAG AA is a visual judgement here; note any faint text).
  5. Reduce Motion: expand "Tùy chọn nâng cao": it opens without animation.

### 3.7 Settings sheets and alerts

Hotkey recorder (General and Typing), macro editor, macro import preview, settings import summary, export, reset
confirmation, app details, licences, macro delete alert, paste-mode alert.

- Code: every control has a label and a hint; each sheet has a default and a cancel keyboard shortcut where an
  action is safe to default (reset and delete never default to the destructive button); the recorder takes focus
  while recording and stops swallowing keys when the window loses key status; the recorder state is text plus a
  border, not colour alone; implicit animations stop under Reduce Motion.
- Pa:
  1. Recorder: with VoiceOver, activate "Đổi phím..."; VoiceOver focus lands on "Hủy"; press a combo; the new combo
     is read back from the recorder text. Record a macOS combo (Command+Space): the warning is read with its
     symbol hidden and the help link reachable.
  2. Macro editor: fields read their labels and hints; a validation problem is read as text when you move to it.
  3. Each alert: VoiceOver reads the buttons with their hints. Note it if SwiftUI alert buttons lose their hints
     (the hints are set on the SwiftUI buttons; macOS may only read the titles).

### 3.8 Diagnostics window, bug report and helpers (PRD-R47 to PRD-R49, PLT-R1201)

- Code: the state line is a header; the report text is focusable, selectable and labelled; every action has a
  label and a hint; the bug report's symptom chips show selection with a check symbol and the selected trait;
  status lines update in place; windows disable animations under Reduce Motion and follow a language change.
- Pa:
  1. Keyboard only: open Diagnostics from About & Support; Tab reaches the report text and every button; Return
     copies the report (default button).
  2. Bug report: VoiceOver reads the app picker, each chip with its selected state, the description field and its
     hint, the preview disclosure and each button.
  3. "Ứng dụng này gõ sai..." panel (PLT-R1205 step 6): it takes keyboard focus when it opens and in its final
     step, so Tab and Full Keyboard Access reach the symptom chips, the preview disclosure and the offers; during
     the guided test (the empty-field confirmation, the progress and the "Do you see 'đá â'?" question) it cannot
     become key and the problem field keeps the focus. Check with Full Keyboard Access and with VoiceOver that each
     step's controls are reached and read.
  4. Latency test and practice field windows: the field labels and hints are read; the probe results are read as
     text.

### 3.9 Composition alerts and the update-failed alert

Safe mode (four choices), move failed, conflict warning, update failed.

- Code: AppKit alerts; each button has a hint (`setAccessibilityHelp`); the update-failed buttons also have
  labels; Return activates the first button, Escape the Close button of the update alert.
- Pa: trigger what you can on a test account (the conflict warning with another input method running; the
  update-failed alert only if a test build with an unreachable feed is at hand). VoiceOver reads the message and
  each button with its hint.

### 3.10 Sparkle's own update window (third party)

- Sparkle's standard user driver draws the update window. Its strings follow the app bundle's localisation as
  chosen by macOS at launch, not the in-app interface language, and a language change applies only after a
  relaunch. Pa: note which language the update window uses with the interface language set opposite to the macOS
  language. The release notes themselves are in the interface language (PRD-R51, owner W2-D).

## 4. Animation call sites (PRD-R12, PRD-R67)

| Call site | Without Reduce Motion | With Reduce Motion |
|---|---|---|
| `Shell/HUDPanels.swift` `present` | 0.15 s fade in | appears at once |
| `Shell/HUDPanels.swift` `dismiss` | 0.15 s fade off | 0.15 s plain fade off (PRD-R12; the only allowlisted unguarded site) |
| `Onboarding/OnboardingViews.swift` permission illustration | 0.9 s loop | still "on" switch (the switch reads Reduce Motion itself); rebuilt when the setting changes |
| `Settings/SettingsComponents.swift` Advanced disclosure | system disclosure animation | no animation (transaction) |
| `Settings/AppsPaneView.swift` app details Advanced disclosure | system disclosure animation | no animation (transaction) |
| Settings, onboarding and Diagnostics window roots and every sheet | implicit SwiftUI animations | disabled (`respectsReduceMotion()`) |
| Sheets, alerts, menus, window opening, toggles, determinate progress bars | drawn by macOS | macOS applies its own Reduce Motion behaviour; Pa confirms sheets |

## 5. Colour, contrast and focus

- No hue is hard-coded in the App target (checked by a test). State is shown with symbols, words, border weight
  and system semantic colours (`accentColor`, `secondary`, `separator`, `keyboardFocusIndicatorColor`), which macOS
  adjusts for Increase Contrast and dark mode.
- The only places where colour accompanies state: the method card border (also a symbol and border width), the
  hotkey recorder box while recording (also the text "Nhấn tổ hợp phím mới, rồi thả ra."), the illustration's
  switch (decorative, labelled).
- Contrast: secondary text uses the system secondary label colour on system backgrounds; WCAG AA for these is met
  by macOS in its standard and Increase Contrast modes. The placeholder status glyph and the dimmed paused glyph
  (alpha 0.4) need a designer's check before 1.0.
- Focus rings: standard controls draw the system focus ring when keyboard navigation is on; the only plain-style
  buttons (the onboarding method cards) draw the focus-ring colour themselves.

## 6. Localisation (PRD-R62 to PRD-R65)

- Runtime switch: one `InterfaceLanguageModel` feeds every window; SwiftUI content re-renders, window titles
  follow through `WindowTitles.follow` or `observeLanguage()`, the status item label follows, the menu is rebuilt
  on open, HUDs and alerts read the language when shown. Not covered: Sparkle's window (section 3.10) and system
  panels (open and save panels, System Settings), which use the macOS language.
- Formats: dates through `Localizer.formatDate`, matrix days through `Localizer.formatDay(iso:)`, counts through
  `Localizer.format` (grouped per language: "1.500" / "1,500"), the trace countdown as `m:ss`, versions kept as
  written ("Phiên bản 1.2.0 (45)").
- System pane names: `App/Resources/SystemPanes.json`, one entry for macOS 15 and 26, one for 27 and later, names
  in vi and en, English fallback for other macOS languages. Every entry is VERIFY on a real system (section 3.5
  step 5).

## 7. Copy review record (W2-F)

Drafted strings are verbatim (`SpecDraftCopyTests`). Non-draft strings were reviewed for neutral standard
Vietnamese addressed to "bạn", no slang or regional idioms, and no exclamation mark except the final onboarding
screen; English for faithfulness.

Changed:

| Key | Before | After |
|---|---|---|
| `macros.enabled.title` | "Bật gõ tắt" / "Use macros" | "Gõ tắt (macro)" / "Macros" (D9 label) |
| `settings.name.macrosInEnglishMode` (en) | "Macros in English mode" | "Expand macros in English mode" (D10 label) |
| `settings.name.firstSeenAppMode` (en) | "Mode for apps seen for the first time" | "Mode for an app seen for the first time" (D13 label) |
| `macros.export.failed`, `settings.export.failed` | "... Bạn thử chọn thư mục khác." / "Try another folder." | "... Hãy chọn thư mục khác." / "Choose another folder." |
| `settings.general.openAtLogin.failed` (vi) | "Bạn thử lại, ..." | "Hãy thử lại, ..." |
| `settings.notice.writeFailed` (vi) | "Bạn kiểm tra dung lượng ổ đĩa rồi thử lại." | "Hãy kiểm tra dung lượng ổ đĩa rồi thử lại." |
| `settings.general.layoutBinding.empty` (vi) | "... chữ Latin ..." | "... chữ Latinh ..." |
| `settings.general.switchIndicator.explanation` | "... giữa màn hình ..." / "... on screen ..." | "... ở phía dưới màn hình ..." / "... near the bottom of the screen ..." |
| `bugReport.description.hint` (en) | "Type an example here yourself. %@ never sends what you typed." | "Type the example again here yourself. %@ does not send what you typed on its own." |
| `safeMode.later.hint` (en) | "... from Report a Problem in the menu." | "... from Report a problem in the menu." (as the menu shows it) |
| `onboarding.window.title` (vi) | "Cài đặt %@" (same as the Settings window) | "Thiết lập %@" |

Added (accessibility only): `icon.paused.userDisabled`, `icon.paused.sessionInactive` and
`icon.paused.diagnosticsTest` labels; `apps.column.actions.accessibilityLabel`; `common.cancel.accessibilityHint`,
`common.close.accessibilityHint`; label and hint of `onboarding.control.confirmResetPermission` and
`cancelResetPermission`. Removed: the unused skeleton keys, the duplicate `menu.quit` in `Localizable`,
`icon.paused.other.accessibilityLabel`, and `settings.typing.practice.label` (never shown; the practice field is
named by `settings.control.practiceField.accessibilityLabel`, which has the same text).

Kept after review (named in the task): `status.safeMode`, `status.action.safeModeChoices`,
`diagnostics.state.paused.diagnosticsTest`, `safeMode.later.hint` (vi), and the onboarding and Settings strings
written without a draft (permission waiting, stale and Input Monitoring notices, the permission help sheet, the
try-it checklist lines, the move offer, every setting explanation, notices, import and export summaries).

Open for Pa:

- English capitalisation is mixed: menu items use sentence case ("Report a problem...", matching the website's
  support pages), Settings buttons use title case ("Restore Defaults..."). Apple's guidelines use title case for
  both; changing the menu also means changing the website text.
- `secureInputHint.browser.passwordField` has copy but no rule in `compat/rules.json` uses it yet.
- Ellipses are written as three periods, as in the spec drafts ("Báo lỗi..."); macOS itself uses the single
  ellipsis character. Kept as drafted.

## 8. PRD-R68: how VoiceOver announces injected corrections

The engine corrects a word by sending Backspace events and the new text (or by selecting and replacing, pasting, or
setting the value through Accessibility, depending on the app's compatibility rule). VoiceOver may read each
deletion and each inserted character. This must be observed with real VoiceOver users before 1.0; no automated check can
observe it.

Protocol, per app (TextEdit, Notes, Safari text field, Chrome address bar, Messenger or Zalo, Terminal):

1. Record the macOS version, VoiceOver's typing echo setting (VoiceOver Utility > Verbosity), the speech rate,
   the app and its version, and the strategy the Diagnostics window shows for the focused field.
2. Type, at a normal pace, in Telex: `Vieejt Nam`, `dduowngf`, `hoaf`, `text` (English restore), and one macro
   (`vn` then Space). Repeat in VNI: `Vie65t Nam`.
3. For each word, write down what VoiceOver says, in order: the characters as typed, any "deleted" or deleted
   characters, the inserted characters, and the word read at Space.
4. Repeat with the typing echo set to characters, to words, and to characters and words.
5. Baseline: repeat step 2 with the macOS built-in Vietnamese input source (Telex), which uses marked text, and
   record what VoiceOver says.
6. Note whether the final word is read correctly at Space, whether intermediate deletions are read, and whether
   the speech lags behind typing.

Outcome: if VoiceOver reads every intermediate deletion, record it in the release notes' known limitations and
open a 1.x issue. Candidate improvements to evaluate then: the IMKit marked-text mode on the roadmap (section
3.3), a per-app strategy that replaces the word in one step (`selectReplace` or `axReplace`) for VoiceOver users,
and a single announcement of the final word.

## 9. Findings for other owners

Filed in the W2-F report as cross-track requests; listed here so the manual pass knows about them. Fixed in
wave 5 and removed from this list: the typing trace confirmation now states the chosen duration
(`TypingTraceConfirmationTests`), and the misbehaves panel takes keyboard focus outside the guided test
(`MisbehavesFocusTests`, section 3.8 step 3).

The browser rows for `secureInputHints` in `compat/rules.json` were added under Q40 (decision 0005): Safari,
Google Chrome, Microsoft Edge, Firefox, Arc and Brave.

- Cốc Cốc's `secureInputHints` row waits for its bundle identifier with its exact case (Q40, owner Pa).
