# 0501. Diagnostics block format v1

- Status: accepted, 2026-11-13; amended 2026-11-13 after wave 1 (full v1 key reference, symptom mapping); amended
  2026-11-15 (keys added within v1 under rule 4: `focus.appSource`, `settings.learnCollisionChoices`,
  `settings.learnedCollisionEntries`, `settings.lookaheadRevision`; closing `#` lines for the reader); amended
  2026-11-19 (keys added within v1 under rule 4 for the typo correction of 1.1.0, ADR 0323: `settings.typoCorrection`,
  `settings.neverCorrectEntries`, `counters.corrections`, `counters.correctionUndos`)
- Requirements: QA-R43, QA-R44, PRD-R45, PRD-R47, PRD-R49, PLT-R381, PLT-R914, PLT-R1202, PLT-R1203, PLT-R1205

## Context

The in-app report (`Báo lỗi...`, PRD-R47) copies a diagnostics block that the user pastes into the GitHub
issue form. QA-R44 requires the block to be stable and machine-parseable, with a header line that carries
the format version, so a workflow can label issues automatically. The platform track writes the block, the
docs track writes the issue forms, this track parses it (`scripts/parse-diagnostics.py`,
`.github/workflows/diagnostics-labels.yml`). This record is the contract between them.

## Format

````text
```text
{{app-slug}}-diagnostics v1
report.bundleId: com.google.Chrome
report.appVersion: 156.0.8078.80
report.symptom: duplicated
report.symptomDetail: duplicatedLetters
report.practiceField: false
app.version: 0.1.0
app.build: 10001
app.channel: beta
macos.version: 27.1
macos.build: 26B12
hw.arch: arm64
hw.model: Mac15,3
ui.locale: vi-VN
input.method: telex
input.layout: com.apple.keylayout.ABC
input.sourceType: asciiLayout
input.enabledSources: com.apple.keylayout.ABC,com.apple.keylayout.US
permission.accessibility: granted
permission.inputMonitoring: unknown
permission.postEvent: granted
permission.health: ready
host.state: readyVietnamese
tap.state: enabled
tap.location: session
tap.timeouts24h: 0
tap.userInputDisables24h: 0
tap.lastReenableReason: none
secureInput.active: false
secureInput.holderBundleId:
secureInput.holderKind:
focus.bundleId: com.google.Chrome
focus.appVersion: 156.0.8078.80
focus.engine: chromium
focus.ax: available
focus.role: AXTextField
focus.subrole:
focus.identifier:
focus.domClasses:
focus.editable: true
focus.secure: false
focus.appSource: accessibility
rule.id: browser.chromium.addressBar
rule.specificity: 10
rule.strategy: backspaceReplace
rule.params: {"inlineCompletion":"axSelectionThenPlaceholder"}
rule.source: shipped
rule.override: false
rule.userOverride:
rule.userOverrideOmitted:
settings.toneStyle: traditional
settings.autoRestore: true
settings.standaloneW: true
settings.bracketKeys: false
settings.macros: true
settings.macroCount: 12
settings.macrosInEnglish: false
settings.rememberPerApp: true
settings.toggleHotkey: modifierTap:controlShift
settings.restoreHotkey: false
settings.learnCollisionChoices: true
settings.learnedCollisionEntries: 37
settings.lookaheadRevision: true
settings.typoCorrection: true
settings.neverCorrectEntries: 2
settings.interfaceLanguage: vi
settings.updateChannel: beta
settings.changed: typingMethod,macrosEnabled
appMode.bundleId: com.google.Chrome
appMode.rule: remember
appMode.remembered: vi
latency.t1.p50Us: 9
latency.t1.p99Us: 41
latency.t1.samples: 18233
latency.t2.p50Us: 410
latency.t2.p99Us: 1300
latency.t2.samples: 2210
latency.t3.p50Us:
latency.t3.p99Us:
latency.t3.samples: 0
latency.echo.p50Us: 230
latency.echo.p99Us: 820
latency.echo.samples: 2210
latency.t5.p50Us: 120
latency.t5.p99Us: 600
latency.t5.samples: 95
latency.t6.p50Us: 2100
latency.t6.p99Us: 9000
latency.t6.samples: 140
counters.flushes: 1
counters.tapTimeouts: 1
counters.fallbacks: 0
counters.echoLosses: 0
counters.watchdogTrips: 0
counters.lostWhilePostingBroken: 0
counters.corrections: 14
counters.correctionUndos: 1
conflicts: none
health.events: 1
health.event.01: 2026-11-13T09:12:00Z tapTimeout
```
````

Rules (normative for v1):

1. The block is a fenced code block (three or more backticks or tildes). Its first non-empty line is the
   header `<slug>-diagnostics v<N>`, where `<slug>` is `APP_SLUG` of the build that produced it (read from
   the bundle, never hard-coded) and `<N>` is the format version, here `1`. Parsers accept any slug of the
   shape `[a-z][a-z0-9-]*`, so reports from builds made before a rename still parse.
2. Every following line until the closing fence is `key: value`. Keys match
   `[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*`. Values are a single line, may be empty, and contain no backticks or
   tildes at the start of the line. Blank lines and lines starting with `#` are ignored. The first
   occurrence of a key wins. The app may close the block with `#` lines for the reader after the last key (the
   health notices of the last 24 hours in the interface language, PLT-R397B); they are not keys and count toward
   the 200 lines of rule 5.
3. Content rules from PRD-R45 and PLT-R1203 apply: no typed text, field values, window titles, URLs,
   clipboard data, macro bodies or home-folder paths. Bundle IDs, layout IDs, roles and rule IDs are
   metadata and allowed.
4. Within v1, keys may be added (parsers ignore unknown keys). Removing a key or changing the meaning or
   value set of a key requires `v2` and an update of this record and of the parser.
5. At most 200 lines; the in-app report keeps a fuller JSON form for attachments (PLT-R1202). The app keeps
   the newest health events that fit (`health.events` says how many are listed).
6. The app writes the keys in the order of the example, and every key of the reference below is present
   (with an empty value when unknown), except `probe.*` (only after the latency probe ran) and
   `health.event.NN` (one line per listed event). Booleans are `true` or `false`; lists are comma-separated.

Keys the labeler reads (QA-R44):

| Label | Key | Accepted values |
|---|---|---|
| `app:<bundle ID>` | `report.bundleId`, else `focus.bundleId` | reverse-DNS, label at most 50 characters |
| `macos:<major>` | `macos.version` | `<major>[.<minor>[.<patch>]]`, extra text after the number ignored |
| `arch:arm64` / `arch:x86_64` | `hw.arch` | `arm64`, `x86_64` |
| `method:telex` / `method:vni` | `input.method` | `telex`, `vni` (case-insensitive) |

### Key reference (v1)

The keys marked "stable" are the `DiagnosticsBlockKey` cases (`Packages/AppCore/Sources/Diagnostics/Report.swift`);
the others are written by `Packages/AppCore/Sources/Diagnostics/IssueBlockFields.swift`. Amended 2026-11-13 after
wave 1: the app emits every key below. `scripts/tests/test_docs_and_workflows.py` (`Adr0501Tests`) fails when
the app writes a key or a key family that this table does not name, when the example's key order differs from
the order the renderer writes (rule 6), and when an enumerated value set below differs from the Swift enum it
comes from (rule 4).

| Key | Value | Notes |
|---|---|---|
| `report.bundleId` | bundle ID | stable; the app chosen in the report sheet (PRD-R47 step 1) |
| `report.appVersion` | version string | stable; only when the reported app is the focused app |
| `report.symptom` | `missing`, `duplicated`, `wrongTone`, `cannotType`, `lag`, `other` | stable; the PRD-R47 chips, see the symptom mapping below |
| `report.symptomDetail` | `lostLetters`, `duplicatedLetters`, `lettersOutOfOrder`, `wrongTone`, `cannotTypeVietnamese`, `nothingTyped`, `lag`, `other` | the exact `DiagnosticsReport.Symptom` (PLT-R1205 list) |
| `report.practiceField` | boolean | the problem also happens in the practice field (PRD-R49); empty when not tried |
| `app.version`, `app.build`, `app.channel` | version, build number, `stable` or `beta` | stable |
| `macos.version`, `macos.build` | for example `27.1`, `26B12` | stable |
| `hw.arch`, `hw.model` | `arm64` or `x86_64`; model identifier | stable |
| `ui.locale` | BCP 47 tag of the macOS primary language | PLT-R1202 "UI locale" |
| `input.method` | `telex`, `vni` | stable |
| `input.layout` | input source ID of the keyboard layout | stable |
| `input.sourceType` | `asciiLayout`, `nonLatinLayout`, `inputMethod`, `builtInVietnamese`, `unknown` | |
| `input.enabledSources` | list of input source IDs | |
| `permission.accessibility`, `permission.inputMonitoring`, `permission.postEvent` | `granted`, `denied`, `unknown` | `inputMonitoring` is the listen-event permission |
| `permission.health` | `ready`, `noPermission`, `stale`, `secureInput`, `paused` | |
| `host.state` | `noPermission`, `starting`, `readyVietnamese`, `readyEnglish`, `paused.<reason>`, `failOpen.<reason>` | stable |
| `tap.state` | `enabled`, `disabled` | |
| `tap.location` | `session` | always the session tap (PLT-R301) |
| `tap.timeouts24h`, `tap.userInputDisables24h` | integer | last 24 hours |
| `tap.lastReenableReason` | a health event kind, or `none` | |
| `secureInput.active` | boolean | stable |
| `secureInput.holderBundleId` | bundle ID | likely holder (PLT-R396) |
| `secureInput.holderKind` | `application`, `loginWindow`, `exitedProcess`, `process` | |
| `focus.bundleId`, `focus.appVersion` | bundle ID, version string | stable |
| `focus.engine` | `electron`, `chromium`, `cef`, `gecko`, `jvm`, `qt`, `catalyst`, `ios`, `webkitBrowser`, `native` | stable |
| `focus.ax` | `available`, `unavailable`, `timedOut` | |
| `focus.role`, `focus.subrole`, `focus.identifier` | AX strings | metadata, never field values |
| `focus.domClasses` | list of DOM class names | |
| `focus.editable` | boolean | empty when AX did not say |
| `focus.secure` | boolean | |
| `focus.appSource` | `accessibility`, `frontmostApplication` | where the focused app's identity came from; `frontmostApplication` when Accessibility named no focused application and NSWorkspace's frontmost app was used (PLT-R381 amendment of 2026-11-15, PLT-R1202); empty without a focused app. Added 2026-11-15; until then a closing `# focus.appSource:` line carried it |
| `rule.id` | rule ID | stable; empty when the defaults applied |
| `rule.specificity` | integer | matcher score (02-platform.md 5.5) |
| `rule.strategy` | injection strategy | stable |
| `rule.params` | compact JSON of the resolved parameters | only parameters that are set |
| `rule.source` | `shipped`, `user`, `default` | |
| `rule.override` | boolean | a user override decided |
| `rule.userOverride` | compact JSON of the reported override | without summary, URL prefixes or title patterns ([0312](0312-report-override-projection.md)) |
| `rule.userOverrideOmitted` | list of `web.urlPrefixes`, `titlePattern` | match fields left out of `rule.userOverride` |
| `settings.toneStyle` | `traditional`, `modern` | |
| `settings.autoRestore`, `settings.standaloneW`, `settings.bracketKeys`, `settings.macros`, `settings.macrosInEnglish`, `settings.rememberPerApp`, `settings.restoreHotkey` | boolean | `restoreHotkey` says whether a binding is set, never which |
| `settings.macroCount` | integer | count only (PRD-R33) |
| `settings.learnCollisionChoices`, `settings.lookaheadRevision` | boolean | D28 (learn which reading of a word that is both English and Vietnamese the user chooses, PLT-R914) and D29 (fix the previous word, PLT-R357). Added 2026-11-15 |
| `settings.learnedCollisionEntries` | integer | entries of the learned collision memory, a count only, never a word (PLT-R901, PLT-R914); empty while the memory is not loaded. Added 2026-11-15 |
| `settings.typoCorrection` | boolean | D30 (correct one clearly mistyped English word at its commit, PRD-R80, 1.1.0). Added 2026-11-19 |
| `settings.neverCorrectEntries` | integer | entries of the never-correct list, a count only, never a word (PRD-R45, PRD-R81); empty when the report was built without it. Added 2026-11-19 |
| `settings.toggleHotkey` | `modifierTap:<chord>`, `keyCombo:<modifiers>:<keyCode>`, `key:<keyCode>` | no characters |
| `settings.interfaceLanguage` | `vi`, `en` | |
| `settings.updateChannel` | `stable`, `beta` | |
| `settings.changed` | list of setting names the user changed (PRD-R6) | names only, no values |
| `appMode.bundleId`, `appMode.rule`, `appMode.remembered` | bundle ID; `remember`, `alwaysEnglish`, `alwaysVietnamese`, `ignore`; `vi`, `en` | per-app memory of the reported app |
| `latency.<metric>.p50Us`, `latency.<metric>.p99Us` | whole microseconds, rounded up to the histogram bucket bound | `<metric>` is `t1`, `t2`, `t3`, `echo`, `t5`, `t6` (02-platform.md 8.1); empty without samples |
| `latency.<metric>.samples` | integer | |
| `counters.<name>` | integer | `<name>` is `flushes`, `tapTimeouts`, `fallbacks`, `echoLosses`, `watchdogTrips`, `lostWhilePostingBroken` |
| `counters.corrections`, `counters.correctionUndos` | integer | words the typo correction changed and corrections the restore key took back since launch (ENG-R1115, ENG-R1117), counts only, never a word (ENG-R1121); empty when the report was built without them. Added 2026-11-19 ([0323](0323-never-correct-list.md)) |
| `probe.ranAt` | ISO 8601 time | only after the latency probe ran (PLT-R810) |
| `probe.<profile>.t2.p50Us`, `probe.<profile>.t2.p99Us`, `probe.<profile>.t4.p50Us`, `probe.<profile>.t4.p99Us`, `probe.<profile>.samples` | integer | `<profile>` is `normal`, `fast`, `burst` |
| `conflicts` | `none`, or a list of bundle IDs | detected conflicting input apps |
| `health.events` | integer | number of `health.event.NN` lines that follow |
| `health.event.NN` | `<ISO 8601 time> <kind> [key=value ...]` | `NN` from `01`; metadata only (PLT-R1206) |

### Symptom mapping

`report.symptom` keeps the value set of the PRD-R47 chips, so labels and saved searches stay valid within v1
(rule 4). PLT-R1205 asks for two symptoms that have no chip: they map to the closest chip, and
`report.symptomDetail` always carries the exact value. Triage that needs the distinction reads
`report.symptomDetail`; `scripts/parse-diagnostics.py` needs no change.

| `report.symptomDetail` | `report.symptom` |
|---|---|
| `lostLetters` | `missing` |
| `duplicatedLetters` | `duplicated` |
| `wrongTone` | `wrongTone` |
| `cannotTypeVietnamese` | `cannotType` |
| `nothingTyped` | `cannotType` |
| `lag` | `lag` |
| `lettersOutOfOrder` | `other` |
| `other` | `other` |

## Issue forms

Amended 2026-11-13: the field has **no** `render:` option. This replaces the earlier `render: text`, which
disagreed with the documentation track's choice (ADR 0400 item 8).

The bug and compatibility forms (QA-R43) declare the diagnostics field (`id: diagnostics`) as a plain
`textarea` without `render:`. The app copies a block that is already fenced (rule 1), and `render: text`
would wrap that paste in a second fence, so the copied fence lines would end up as text inside the code
block. Without `render:`, GitHub keeps the pasted Markdown as is: the block arrives with its own fence and
its `<slug>-diagnostics v1` header. The parser does not depend on the fence: it finds the first header line
anywhere in the issue body, so a paste of the inner lines only (no fence) still parses, and the closing
fence or the end of the body ends the block. Both forms tell the reporter that the block starts with the
header line `<slug>-diagnostics v1`. `scripts/tests/test_scripts.py` fails if either form gains a `render:`
key on that field or stops naming the header. Amended 2026-11-13: the forms are front-door files (ADR 0400
decision 1 amendment), so they write the header with the literal slug of `scripts/brand.env`, which
`scripts/rename-app.sh` rewrites on a rename.

## Consequences

- The labeler only adds labels and never removes them; maintainers can correct labels by hand.
- A label that does not exist yet is created with a neutral color before it is added.
